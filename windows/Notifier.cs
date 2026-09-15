using System;
using System.IO;
using System.Drawing;
using System.Windows.Forms;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32;
using System.Web.Script.Serialization;

static class Native {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool attach);
    public static bool Raise() {
        foreach (string name in new [] {"ChatGPT", "Codex"}) foreach (Process p in Process.GetProcessesByName(name)) {
            using (p) {
                IntPtr h = p.MainWindowHandle;
                if (h == IntPtr.Zero) continue;
                // Match installed OpenAI application, not a similarly named CLI.
                try { if (p.MainModule.FileName.IndexOf("OpenAI", StringComparison.OrdinalIgnoreCase) < 0) continue; } catch { continue; }
                return FocusWindow(h);
            }
        }
        return false;
    }
    public static bool FocusWindow(IntPtr h) {
        // SW_RESTORE also unmaximizes an already visible window. Only restore
        // minimized windows; preserve fullscreen/maximized geometry otherwise.
        if (IsIconic(h)) ShowWindowAsync(h, 9);
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint current = GetCurrentThreadId();
        bool attached = foreground != current && AttachThreadInput(current, foreground, true);
        try { SetForegroundWindow(h); } finally { if (attached) AttachThreadInput(current, foreground, false); }
        return GetForegroundWindow() == h;
    }
}

sealed class Notifier : ApplicationContext {
    readonly NotifyIcon tray;
    readonly System.Windows.Forms.Timer timer;
    readonly SessionWatcher watcher;
    readonly List<Notice> queue = new List<Notice>();
    readonly string home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    readonly string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexNotifier");
    readonly ToolStripMenuItem pause;
    Popup popup;
    AppSettings settings;
    SettingsDialog settingsDialog;
    bool paused, escalated;
    DateTime lastPoll = DateTime.MinValue;
    DateTime retryRaise = DateTime.MaxValue;
    string lastThread;
    sealed class PendingReply {public string Thread,Text,Stage="waiting-draft";public uint Input;public DateTime Started,Deadline;public bool Sent;}
    PendingReply replyState;
    PendingReply pendingReply {get{return replyState;}set{replyState=value;if(value==null)QuickReply.StopInputWatch();}}
    public Notifier(bool demo) {
        Directory.CreateDirectory(logDir);
        settings=AppSettings.Load(AppSettings.SettingsPath);
        settings.Startup=AppSettings.StartupEnabled();
        tray = new NotifyIcon { Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath), Text="Codex Notifier — включён", Visible=true };
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Настройки…", null, delegate { ShowSettings(); });
        menu.Items.Add("Показать уведомление", null, delegate { if (popup != null) popup.Show(); });
        menu.Items.Add("Проверить уведомление", null, delegate { Add("", "demo-"+DateTime.UtcNow.Ticks, "Проверка уведомления — откроется окно Codex"); });
        pause = new ToolStripMenuItem("Пауза", null, delegate { paused=!paused; pause.Checked=paused; tray.Text=paused ? "Codex Notifier — пауза" : "Codex Notifier — включён"; if(paused) Clear(); }); menu.Items.Add(pause);
        menu.Items.Add("Выход", null, delegate { ExitThread(); }); tray.ContextMenuStrip=menu;
        tray.DoubleClick += delegate { ShowSettings(); };
        watcher = new SessionWatcher(Path.Combine(home,"sessions"));
        watcher.OnError = delegate(string error) { Log("parse-error " + error); };
        watcher.OnEvent = delegate(string kind,string thread,string turn) {
            if(kind=="task_started") {if(pendingReply!=null && pendingReply.Thread==thread) {pendingReply=null;Log("quick-reply-task-started");} Cancel(thread); return; }
            if(!paused) Add(thread,turn,Title(thread)+(kind=="turn_aborted" ? " — выполнение остановлено" : ""));
        };
        watcher.Baseline();
        timer = new System.Windows.Forms.Timer { Interval=2000 }; timer.Tick += Tick; timer.Start();
        Log("started");
        if(!settings.SetupComplete) ShowSettings();
        else if(demo) Add("", "demo", "Проверка уведомления — откроется окно Codex");
    }
    void ShowSettings() {
        if(settingsDialog!=null) {settingsDialog.Show();return;}
        if(popup!=null)ClosePopup();
        retryRaise=DateTime.MaxValue;
        settingsDialog=new SettingsDialog(settings,delegate(AppSettings next) {
            bool wasStartup=AppSettings.StartupEnabled();
            try { AppSettings.SetStartup(next.Startup); next.Save(AppSettings.SettingsPath); }
            catch { AppSettings.SetStartup(wasStartup); throw; }
            settings=next; Log("settings-saved");
        });
        settingsDialog.Window.Closed+=delegate {settingsDialog=null;if(queue.Count>0 && !paused)ShowNext();};
        settingsDialog.Show();
    }
    void Log(string s) { try {string path=Path.Combine(logDir,"events.log");if(File.Exists(path) && new FileInfo(path).Length>1048576) {File.Copy(path,path+".previous",true);File.WriteAllText(path,"");} File.AppendAllText(path, DateTime.Now.ToString("s")+" "+s+Environment.NewLine); } catch {} }
    string Title(string id) {
        try {
            string result="Задача " + id.Substring(0,8);
            var j = new JavaScriptSerializer();
            using(var f=new FileStream(Path.Combine(home,"session_index.jsonl"),FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) using(var r=new StreamReader(f)) {
                string line; while((line=r.ReadLine())!=null) { var d=j.Deserialize<Dictionary<string,object>>(line); if(d.ContainsKey("id") && d["id"].ToString()==id && d.ContainsKey("thread_name")) result=d["thread_name"].ToString(); }
            }
            return result;
        } catch { return "Ответ в Codex готов"; }
    }
    void Add(string thread,string turn,string title) { if(queue.Count>=200){queue.RemoveAt(1);Log("notification-queue-limit");} queue.Add(new Notice {Thread=thread,Turn=turn,Title=title}); Log("notification-queued"); if(queue.Count==1 && settingsDialog==null) ShowNext(); }
    void ShowNext() {
        if(queue.Count==0 || settingsDialog!=null) return;
        queue[0].Deadline=DateTime.UtcNow.AddSeconds(settings.DelaySeconds); escalated=false;
        popup=new Popup(queue[0].Title,OpenCurrent,Acknowledge,settings,BeginQuickReply); popup.UpdateSeconds(settings.DelaySeconds); popup.Show();
        timer.Interval=250;
        if(settings.Sound)System.Media.SystemSounds.Exclamation.Play(); Log("notification-shown");
    }
    void ClosePopup() { pendingReply=null;if(popup!=null) { popup.Dispose(); popup=null; } if(timer!=null)timer.Interval=2000; }
    void BeginQuickReply(string text) {
        if(queue.Count==0 || popup==null || pendingReply!=null)return;
        escalated=true;retryRaise=DateTime.MaxValue;
        popup.StopCountdown();
        string thread=queue[0].Thread;
        if(thread.Length==0) {popup.SetReplyStatus("Тестовый ответ: «"+text+"». Сообщение не отправлено.",false);return;}
        try {
            string draft=QuickReply.Draft(thread);
            if(!String.IsNullOrWhiteSpace(draft)) {Open(thread);popup.SetReplyStatus("В чате уже есть черновик. Проверь его перед отправкой.",false);return;}
            pendingReply=new PendingReply {Thread=thread,Text=text,Input=settings.ReplyMode=="send"?QuickReply.BeginInputWatch():0,Started=DateTime.UtcNow,Deadline=DateTime.UtcNow.AddSeconds(10)};
            Log("quick-reply-begin mode="+settings.ReplyMode);
            popup.SetReplyStatus(settings.ReplyMode=="send"?"Открываю задачу и готовлю отправку…":"Открываю задачу и вставляю текст…",true);
            Process.Start(new ProcessStartInfo(QuickReply.Link(thread,text)){UseShellExecute=true});
        } catch(Exception e) {pendingReply=null;popup.SetReplyStatus("Не удалось подготовить ответ. Открой чат вручную.",false);Log("quick-reply-error "+e.GetType().Name);}
    }
    static IntPtr ForegroundCodex() {
        IntPtr h=Native.GetForegroundWindow();
        foreach(string name in new[]{"ChatGPT","Codex"})foreach(Process process in Process.GetProcessesByName(name))using(process) {
            try {if(process.MainWindowHandle==h && process.MainModule.FileName.IndexOf("OpenAI",StringComparison.OrdinalIgnoreCase)>=0)return h;}catch{}
        }
        return IntPtr.Zero;
    }
    void PollQuickReply() {
        var pending=pendingReply;if(pending==null || popup==null)return;
        if(DateTime.UtcNow>pending.Deadline) {
            pendingReply=null;popup.SetReplyStatus(pending.Sent?"Не удалось подтвердить отправку. Проверь чат, прежде чем повторять.":"Автоотправка не выполнена. Проверь текст и отправь вручную.",pending.Sent);Log("quick-reply-timeout stage="+pending.Stage);return;
        }
        if(pending.Sent)return;
        if(settings.ReplyMode=="send" && QuickReply.InputStamp()!=pending.Input) {
            pendingReply=null;Log("quick-reply-cancelled user-input");popup.SetReplyStatus("Отправка отменена из-за нового ввода. Проверь текст в чате.",false);return;
        }
        if(settings.ReplyMode=="draft") {
            string editorReason;IntPtr editorWindow=ForegroundCodex();
            if(editorWindow!=IntPtr.Zero && QuickReply.ComposerMatches(editorWindow,pending.Text,out editorReason)) {pendingReply=null;Log("quick-reply-drafted");Acknowledge();return;}
            string draft;
            try {draft=QuickReply.Draft(pending.Thread);}catch(IOException){ReplyStage(pending,"draft-file-busy");return;}
            if(draft!=pending.Text){ReplyStage(pending,String.IsNullOrEmpty(draft)?"draft-empty":"draft-different");return;}
            pendingReply=null;Log("quick-reply-drafted");Acknowledge();return;
        }
        if((DateTime.UtcNow-pending.Started).TotalSeconds<1)return;
        IntPtr hwnd=ForegroundCodex();
        if(hwnd==IntPtr.Zero){ReplyStage(pending,"codex-not-foreground");return;}
        string reason;
        if(QuickReply.SubmitToFocusedComposer(hwnd,pending.Input,pending.Text,out reason)) {QuickReply.StopInputWatch();pending.Sent=true;pending.Deadline=DateTime.UtcNow.AddSeconds(10);popup.SetReplyStatus("Ожидаю подтверждения отправки…",true);Log("quick-reply-submit-requested");}
        ReplyStage(pending,reason);
    }
    void ReplyStage(PendingReply pending,string stage) {if(pending.Stage==stage)return;pending.Stage=stage;Log("quick-reply-stage "+stage);}
    void Acknowledge() { ClosePopup(); if(queue.Count>0) queue.RemoveAt(0); Log("acknowledged"); ShowNext(); }
    void Clear() { ClosePopup(); queue.Clear(); retryRaise=DateTime.MaxValue; }
    void Cancel(string thread) {
        bool first=queue.Count>0 && queue[0].Thread==thread;
        queue.RemoveAll(n=>n.Thread==thread);
        if(first) { ClosePopup(); ShowNext(); }
    }
    void OpenCurrent() { if(queue.Count==0)return; if(Open(queue[0].Thread))Acknowledge();else if(popup!=null)popup.SetReplyStatus("Не удалось открыть чат. Уведомление сохранено.",false); }
    bool Open(string thread) {
        try { if(thread.Length>0) Process.Start(new ProcessStartInfo("codex://threads/"+thread) {UseShellExecute=true}); }
        catch(Exception e) { Log("deep-link-error "+e.GetType().Name);return false; }
        lastThread=thread;
        bool raised=Native.Raise(); Log("raise requested; foreground="+raised);
        retryRaise=DateTime.UtcNow.AddSeconds(2);
        return true;
    }
    void Tick(object sender,EventArgs e) {
        try {
            if(DateTime.UtcNow>=retryRaise) { retryRaise=DateTime.MaxValue; Log("raise retry; foreground="+Native.Raise()); }
            if((DateTime.UtcNow-lastPoll).TotalSeconds>=2) { lastPoll=DateTime.UtcNow; watcher.Poll(); }
            PollQuickReply();
            if(queue.Count==0 || popup==null)return;
            int left=(int)Math.Ceiling((queue[0].Deadline-DateTime.UtcNow).TotalSeconds);
            popup.UpdateSeconds(Math.Max(0,left));
            if(settings.AutoOpen && left<=0 && !escalated) { escalated=true; Open(queue[0].Thread); Log("escalated-after-"+settings.DelaySeconds+"s"); }
        } catch(Exception error) { Log("error "+error.GetType().Name); }
    }
    protected override void ExitThreadCore() { timer.Stop(); watcher.Dispose();paused=true; Clear(); if(settingsDialog!=null)settingsDialog.Window.Close(); tray.Visible=false;var icon=tray.Icon; tray.Dispose();if(icon!=null)icon.Dispose(); Log("stopped"); base.ExitThreadCore(); }
}

static class Program {
    [STAThread] static void Main(string[] args) {
        if(Array.IndexOf(args,"--self-test")>=0) { SelfTest.Run(); return; }
        bool owned; using(Mutex mutex=new Mutex(true,"Local\\CodexNotifier-v1",out owned)) {
            if(!owned)return;
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Notifier(Array.IndexOf(args,"--demo")>=0));
        }
    }
}

