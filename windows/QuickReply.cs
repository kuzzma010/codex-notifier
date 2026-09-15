using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Runtime.InteropServices;
using System.Windows.Automation;

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
        if(state==null)throw new InvalidDataException("Invalid state");
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
    // These hooks exist only while preparing a user-requested quick reply.
    // No key values, pointer coordinates, or input text are read or retained.
    delegate IntPtr InputProc(int code,IntPtr message,IntPtr data);
    static readonly InputProc inputProc=ObserveInput;
    static IntPtr keyboardHook,mouseHook;
    static uint inputSequence;
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int kind,InputProc callback,IntPtr module,uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    public static bool CancelsReply(int message) {
        return message==0x0100 || message==0x0104 || message==0x0201 || message==0x0204 || message==0x0207 || message==0x020B || message==0x020A || message==0x020E;
    }
    static IntPtr ObserveInput(int code,IntPtr message,IntPtr data) {
        if(code>=0 && CancelsReply(message.ToInt32()))unchecked {inputSequence++;}
        return CallNextHookEx(IntPtr.Zero,code,message,data);
    }
    public static void StopInputWatch() {
        if(keyboardHook!=IntPtr.Zero)UnhookWindowsHookEx(keyboardHook);
        if(mouseHook!=IntPtr.Zero)UnhookWindowsHookEx(mouseHook);
        keyboardHook=mouseHook=IntPtr.Zero;
    }
    public static uint BeginInputWatch() {
        StopInputWatch();inputSequence=0;
        keyboardHook=SetWindowsHookEx(13,inputProc,GetModuleHandle(null),0);
        mouseHook=SetWindowsHookEx(14,inputProc,GetModuleHandle(null),0);
        if(keyboardHook==IntPtr.Zero || mouseHook==IntPtr.Zero) {StopInputWatch();throw new InvalidOperationException("Не удалось проверить активность ввода.");}
        return inputSequence;
    }
    [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)] struct GuiInfo {public uint Size,Flags;public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret;public Rect CaretRect;}
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint id,ref GuiInfo info);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint message,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    public static uint InputStamp() {return inputSequence;}
    public static bool ComposerMatches(IntPtr expected,string text,out string reason) {
        reason="composer-unavailable";
        try {
            var focused=AutomationElement.FocusedElement;
            if(focused==null)return false;
            var window=AutomationElement.FromHandle(expected);
            if(focused.Current.ProcessId!=window.Current.ProcessId || !focused.Current.HasKeyboardFocus)return false;
            var ancestor=focused;bool inWindow=false;
            for(int depth=0;ancestor!=null && depth<64;depth++) {
                if(Automation.Compare(ancestor,window)){inWindow=true;break;}
                ancestor=TreeWalker.RawViewWalker.GetParent(ancestor);
            }
            if(!inWindow){reason="editor-in-another-window";return false;}
            if(focused.Current.ControlType!=ControlType.Edit && focused.Current.ControlType!=ControlType.Document) {reason="focus-not-editor";return false;}
            object pattern;string value=null;
            if(focused.TryGetCurrentPattern(ValuePattern.Pattern,out pattern)) {
                var vp=(ValuePattern)pattern;if(vp.Current.IsReadOnly){reason="editor-read-only";return false;}value=vp.Current.Value;
            }
            else if(focused.TryGetCurrentPattern(TextPattern.Pattern,out pattern))value=((TextPattern)pattern).DocumentRange.GetText(256);
            reason=value==null?"editor-text-unavailable":"editor-text-different";
            if(value==null || value.TrimEnd('\r','\n')!=text)return false;
            reason="editor-confirmed";return true;
        } catch {return false;}
    }
    public static bool SubmitToFocusedComposer(IntPtr expected,uint stamp,string text,out string reason) {
        reason="foreground-changed";
        if(expected==IntPtr.Zero || Native.GetForegroundWindow()!=expected)return false;
        reason="user-input";if(InputStamp()!=stamp)return false;
        reason="modifier-held";
        foreach(int key in new[]{0x10,0x11,0x12,0x5B,0x5C})if((GetAsyncKeyState(key)&0x8000)!=0)return false;
        var info=new GuiInfo {Size=(uint)Marshal.SizeOf(typeof(GuiInfo))};
        reason="gui-focus-unavailable";
        if(!GetGUIThreadInfo(Native.GetWindowThreadProcessId(expected,IntPtr.Zero),ref info) || info.Active!=expected || info.Focus==IntPtr.Zero)return false;
        var name=new StringBuilder(256);GetClassName(info.Focus,name,name.Capacity);
        reason="focus-class-"+name.ToString();
        if(name.ToString()!="Chrome_RenderWidgetHostHWND" && name.ToString()!="Chrome_WidgetWin_1")return false;
        if(!ComposerMatches(expected,text,out reason))return false;
        reason="focus-or-input-changed";
        if(Native.GetForegroundWindow()!=expected || InputStamp()!=stamp)return false;
        // Target Chromium's focused content window, never a global keyboard shortcut.
        reason="post-message-failed";
        if(!PostMessage(info.Focus,0x0100,new IntPtr(13),new IntPtr(0x001C0001)))return false;
        PostMessage(info.Focus,0x0101,new IntPtr(13),new IntPtr(unchecked((int)0xC01C0001)));
        reason="submitted";
        return true;
    }
}
