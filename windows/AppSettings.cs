using System;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

public sealed class AppSettings {
    public string Theme { get; set; }
    public string Size { get; set; }
    public bool Sound { get; set; }
    public bool AutoOpen { get; set; }
    public int DelaySeconds { get; set; }
    public bool Startup { get; set; }
    public bool SetupComplete { get; set; }
    public string ReplyMode { get; set; }
    public AppSettings() { Theme="auto"; Size="small"; Sound=true; AutoOpen=true; DelaySeconds=30; ReplyMode="draft"; }
    public AppSettings Copy() { return (AppSettings)MemberwiseClone(); }
    public void Normalize() {
        if(Theme!="light" && Theme!="dark") Theme="auto";
        if(Size!="large") Size="small";
        if(ReplyMode!="send") ReplyMode="draft";
        if(DelaySeconds!=15 && DelaySeconds!=30 && DelaySeconds!=60) DelaySeconds=30;
    }
    public static string SettingsPath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CodexNotifier","settings.json"); } }
    public static AppSettings Load(string path) {
        try { var settings=new JavaScriptSerializer().Deserialize<AppSettings>(File.ReadAllText(path)); if(settings==null)return new AppSettings(); settings.Normalize(); return settings; }
        catch(IOException) { return new AppSettings(); } catch(ArgumentException) { return new AppSettings(); } catch(InvalidOperationException) { return new AppSettings(); }
    }
    public void Save(string path) {
        Normalize(); Directory.CreateDirectory(Path.GetDirectoryName(path));
        string pending=path+".tmp";
        File.WriteAllText(pending,new JavaScriptSerializer().Serialize(this),new UTF8Encoding(false));
        if(File.Exists(path)) File.Replace(pending,path,null); else File.Move(pending,path);
    }
    public static bool StartupEnabled() { using(var k=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) return k!=null && k.GetValue("CodexNotifier")!=null; }
    public static void SetStartup(bool enabled) {
        using(var k=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
            if(enabled) k.SetValue("CodexNotifier","\""+System.Windows.Forms.Application.ExecutablePath+"\"");
            else k.DeleteValue("CodexNotifier",false);
        }
    }
    public bool IsDark() {
        if(Theme!="auto") return Theme=="dark";
        try { using(var k=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) return k!=null && Convert.ToInt32(k.GetValue("AppsUseLightTheme",1))==0; }
        catch { return false; }
    }
}
