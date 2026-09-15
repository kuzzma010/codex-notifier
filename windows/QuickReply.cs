using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Runtime.InteropServices;

static class QuickReply {
    public static readonly string[] Texts={"Да","Дальше","Делай"};
    static string StatePath { get {return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".codex",".codex-global-state.json");} }
    public static string Link(string thread,string text) {
        Guid id;if(!Guid.TryParse(thread,out id))throw new ArgumentException("Не удалось определить задачу.");
        if(Array.IndexOf(Texts,text)<0)throw new ArgumentException("Неизвестный быстрый ответ.");
        return "codex://threads/"+id+"?prompt="+Uri.EscapeDataString(text);
    }
    public static string Draft(string thread) {return DraftFromJson(File.ReadAllText(StatePath),thread);}
    public static string DraftFromJson(string json,string thread) {
        var state=new JavaScriptSerializer {MaxJsonLength=33554432}.Deserialize<Dictionary<string,object>>(json);
        object atomValue;if(!state.TryGetValue("electron-persisted-atom-state",out atomValue))return "";
        var atoms=atomValue as Dictionary<string,object>;if(atoms==null)return "";
        object value;if(!atoms.TryGetValue("composer-prompt-drafts-v2",out value))return "";
        var drafts=value as Dictionary<string,object>;if(drafts==null)return "";
        string direct="local:"+thread,alias=null;
        if(atoms.TryGetValue("thread-client-id-v1:"+Uri.EscapeDataString(direct),out value))alias=value as string;
        // A retained client identity can remain the composer draft key after task creation.
        foreach(string key in new[]{alias,direct,thread})if(key!=null && drafts.TryGetValue(key,out value) && value is string && ((string)value).Length>0)return (string)value;
        return "";
    }
    [StructLayout(LayoutKind.Sequential)] struct LastInput {public uint Size,Time;}
    [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)] struct GuiInfo {public uint Size,Flags;public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret;public Rect CaretRect;}
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput info);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint id,ref GuiInfo info);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint message,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    public static uint InputStamp() {var i=new LastInput {Size=(uint)Marshal.SizeOf(typeof(LastInput))};if(!GetLastInputInfo(ref i))throw new InvalidOperationException("Не удалось проверить активность ввода.");return i.Time;}
    public static bool SubmitToFocusedComposer(IntPtr expected,uint stamp) {
        if(expected==IntPtr.Zero || Native.GetForegroundWindow()!=expected || InputStamp()!=stamp)return false;
        foreach(int key in new[]{0x10,0x11,0x12,0x5B,0x5C})if((GetAsyncKeyState(key)&0x8000)!=0)return false;
        var info=new GuiInfo {Size=(uint)Marshal.SizeOf(typeof(GuiInfo))};
        if(!GetGUIThreadInfo(Native.GetWindowThreadProcessId(expected,IntPtr.Zero),ref info) || info.Active!=expected || info.Focus==IntPtr.Zero)return false;
        var name=new StringBuilder(256);GetClassName(info.Focus,name,name.Capacity);
        if(name.ToString()!="Chrome_RenderWidgetHostHWND")return false;
        if(Native.GetForegroundWindow()!=expected || InputStamp()!=stamp)return false;
        // Target Chromium's focused content window, never a global keyboard shortcut.
        if(!PostMessage(info.Focus,0x0100,new IntPtr(13),new IntPtr(0x001C0001)))return false;
        PostMessage(info.Focus,0x0101,new IntPtr(13),new IntPtr(unchecked((int)0xC01C0001)));
        return true;
    }
}
