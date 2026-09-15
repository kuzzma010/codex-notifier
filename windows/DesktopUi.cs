using System;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Interop;
using System.Windows.Threading;
using System.Runtime.InteropServices;

static class DesktopUi {
    public static object Load(string name) { using(Stream s=Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) { if(s==null)throw new IOException("Missing UI resource: "+name); return XamlReader.Load(s); } }
    public static T Get<T>(Window w,string name) where T:class { return w.FindName(name) as T; }
    public static void Initialize(Window w,AppSettings settings) {
        using(Stream icon=Assembly.GetExecutingAssembly().GetManifestResourceStream("App.ico")) {
            if(icon!=null)w.Icon=System.Windows.Media.Imaging.BitmapFrame.Create(icon,System.Windows.Media.Imaging.BitmapCreateOptions.None,System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
        }
        // These are small, static windows; avoid loading a large GPU driver stack.
        RenderOptions.ProcessRenderMode=RenderMode.SoftwareOnly;
        w.Resources.MergedDictionaries.Add((ResourceDictionary)Load("UiTheme.xaml"));
        ApplyTheme(w,settings);
        System.Windows.Forms.Integration.ElementHost.EnableModelessKeyboardInterop(w);
    }
    static SolidColorBrush Brush(string hex) { return (SolidColorBrush)new BrushConverter().ConvertFromString(hex); }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h,int attr,ref int value,int size);
    public static void ApplyTheme(Window w,AppSettings settings) {
        bool dark=settings.IsDark();
        string[,] colors=dark?new string[,] {
            {"Surface","#191E21"},{"Ink","#EEF4F0"},{"Muted","#AAB9B0"},{"Line","#35433B"},{"Soft","#242E29"},{"Accent","#C7E5D7"},{"OnAccent","#19382A"},{"Glass","#EA192127"},{"GlassLine","#5578877F"},{"PreviewBackground","#334A4D"}
        }:new string[,] {
            {"Surface","#F5F7F5"},{"Ink","#20332B"},{"Muted","#58685F"},{"Line","#D5DFD8"},{"Soft","#E8EEEA"},{"Accent","#295F49"},{"OnAccent","#FFFFFF"},{"Glass","#EDF5FAF7"},{"GlassLine","#CCFFFFFF"},{"PreviewBackground","#CCDCD5"}
        };
        for(int i=0;i<colors.GetLength(0);i++) w.Resources[colors[i,0]]=Brush(colors[i,1]);
        IntPtr hwnd=new WindowInteropHelper(w).Handle;
        if(hwnd!=IntPtr.Zero) { try { int value=dark?1:0; DwmSetWindowAttribute(hwnd,20,ref value,4); } catch(DllNotFoundException) {} }
    }
}

sealed class Popup : IDisposable {
    readonly Window window;
    readonly AppSettings settings;
    bool expanded;
    bool dark;
    bool disposing;
    bool countdownStopped;
    int lastSeconds=Int32.MinValue;
    DateTime nextThemeCheck=DateTime.MinValue;
    public Popup(string title,Action open,Action ack,AppSettings options,Action<string> reply=null) {
        settings=options.Copy(); dark=settings.IsDark();
        window=(Window)DesktopUi.Load("Notice.xaml"); DesktopUi.Initialize(window,settings);
        DesktopUi.Get<TextBlock>(window,"TaskTitle").Text=title;
        DesktopUi.Get<TextBlock>(window,"TaskTitle").ToolTip=title;
        DesktopUi.Get<Button>(window,"MiniOpen").Click+=delegate { open(); };
        DesktopUi.Get<Button>(window,"OpenChat").Click+=delegate { open(); };
        DesktopUi.Get<Button>(window,"Seen").Click+=delegate { ack(); };
        DesktopUi.Get<Button>(window,"CloseNotice").Click+=delegate { ack(); };
        DesktopUi.Get<TextBlock>(window,"ReplyHint").Text=settings.ReplyMode=="send"?"Быстрый ответ · отправить сразу":"Быстрый ответ · вставить для проверки";
        string[] replyButtons={"ReplyYes","ReplyNext","ReplyDo"};
        for(int i=0;i<replyButtons.Length;i++) {string text=QuickReply.Texts[i];var button=DesktopUi.Get<Button>(window,replyButtons[i]);button.Click+=delegate {if(reply!=null)reply(text);else SetReplyStatus("Тест: "+text,false);};}
        DesktopUi.Get<Button>(window,"Expand").Click+=delegate { SetExpanded(true); DesktopUi.Get<Button>(window,"Collapse").Focus(); };
        DesktopUi.Get<Button>(window,"Collapse").Click+=delegate { SetExpanded(false); DesktopUi.Get<Button>(window,"Expand").Focus(); };
        window.PreviewKeyDown+=delegate(object sender,System.Windows.Input.KeyEventArgs e) { if(e.Key==System.Windows.Input.Key.Escape) { e.Handled=true; ack(); } };
        window.Closing+=delegate(object sender,System.ComponentModel.CancelEventArgs e) { if(!disposing) {e.Cancel=true;window.Dispatcher.BeginInvoke(new Action(ack));} };
        window.SizeChanged+=delegate { Position(); };
        SetExpanded(settings.Size=="large");
        UpdateSeconds(settings.DelaySeconds);
    }
    public Window Window { get { return window; } }
    public bool Expanded { get { return expanded; } }
    public void SetExpanded(bool value) {
        expanded=value;
        DesktopUi.Get<Grid>(window,"Mini").Visibility=value?Visibility.Collapsed:Visibility.Visible;
        DesktopUi.Get<Grid>(window,"Detail").Visibility=value?Visibility.Visible:Visibility.Collapsed;
        DesktopUi.Get<Border>(window,"Shell").Padding=new Thickness(value?18:6);
        DesktopUi.Get<Border>(window,"Shell").CornerRadius=new CornerRadius(value?22:16);
        window.Width=value?320:168;
        window.SizeToContent=value?SizeToContent.Height:SizeToContent.Manual;
        window.Height=value?Double.NaN:64;
        Position();
    }
    void Position() { Rect r=SystemParameters.WorkArea;double height=window.ActualHeight>0?window.ActualHeight:64; window.Left=r.Right-window.Width-14; window.Top=r.Bottom-height-14; }
    public void Show() { window.Show(); }
    public void SetReplyStatus(string text,bool busy) {
        var status=DesktopUi.Get<TextBlock>(window,"ReplyStatus");status.Text=text;status.Visibility=String.IsNullOrEmpty(text)?Visibility.Collapsed:Visibility.Visible;
        SetExpanded(true);
        foreach(string name in new[]{"ReplyYes","ReplyNext","ReplyDo"})DesktopUi.Get<Button>(window,name).IsEnabled=!busy;
        Position();
    }
    public void UpdateSeconds(int n) {
        if(DateTime.UtcNow>=nextThemeCheck) {nextThemeCheck=DateTime.UtcNow.AddSeconds(2);bool nextDark=settings.IsDark();if(dark!=nextDark) {dark=nextDark;DesktopUi.ApplyTheme(window,settings);} }
        if(countdownStopped)return;
        if(lastSeconds==n)return;lastSeconds=n;
        string text=!settings.AutoOpen?"Открытие по нажатию":n>0?"До открытия чата: "+n+" сек.":"Codex открыт · нажми «Увидел»";
        DesktopUi.Get<TextBlock>(window,"Countdown").Text=text;
        DesktopUi.Get<Border>(window,"Track").Visibility=settings.AutoOpen?Visibility.Visible:Visibility.Collapsed;
        DesktopUi.Get<Border>(window,"Progress").Width=270*Math.Max(0,Math.Min(1,(double)n/settings.DelaySeconds));
    }
    public void StopCountdown() {countdownStopped=true;DesktopUi.Get<TextBlock>(window,"Countdown").Text="Автоматическое открытие отменено";DesktopUi.Get<Border>(window,"Track").Visibility=Visibility.Collapsed;}
    public void Dispose() { disposing=true; window.Close(); }
}

sealed class SettingsDialog {
    readonly Window window;
    readonly AppSettings draft;
    readonly Action<AppSettings> save;
    readonly DispatcherTimer themeTimer;
    readonly DispatcherTimer previewTimer;
    Popup testPopup;
    DateTime previewDeadline;
    bool previewExpanded;
    bool dark;
    public Window Window { get { return window; } }
    T Get<T>(string name) where T:class { return DesktopUi.Get<T>(window,name); }
    public SettingsDialog(AppSettings current,Action<AppSettings> onSave) {
        draft=current.Copy(); draft.Startup=AppSettings.StartupEnabled(); save=onSave; dark=draft.IsDark();
        window=(Window)DesktopUi.Load("Settings.xaml"); DesktopUi.Initialize(window,draft);
        if(current.SetupComplete) { Get<TextBlock>("Eyebrow").Text="CODEX NOTIFIER  /  НАСТРОЙКИ"; Get<Button>("SaveSettings").Content="Сохранить"; }
        Get<ComboBox>("ThemeChoice").SelectedIndex=draft.Theme=="light"?1:draft.Theme=="dark"?2:0;
        Get<ComboBox>("DelayChoice").SelectedIndex=draft.DelaySeconds==15?0:draft.DelaySeconds==60?2:1;
        Get<ComboBox>("ReplyChoice").SelectedIndex=draft.ReplyMode=="send"?1:0;
        Get<CheckBox>("SoundChoice").IsChecked=draft.Sound; Get<CheckBox>("AutoChoice").IsChecked=draft.AutoOpen; Get<CheckBox>("StartupChoice").IsChecked=draft.Startup;
        previewExpanded=draft.Size=="large";
        Get<Button>("SmallSize").Click+=delegate { draft.Size="small"; previewExpanded=false; Refresh(); };
        Get<Button>("LargeSize").Click+=delegate { draft.Size="large"; previewExpanded=true; Refresh(); };
        Get<ComboBox>("ThemeChoice").SelectionChanged+=delegate { draft.Theme=new[]{"auto","light","dark"}[Get<ComboBox>("ThemeChoice").SelectedIndex]; dark=draft.IsDark(); DesktopUi.ApplyTheme(window,draft); Refresh(); };
        Get<ComboBox>("DelayChoice").SelectionChanged+=delegate { draft.DelaySeconds=new[]{15,30,60}[Get<ComboBox>("DelayChoice").SelectedIndex]; Refresh(); };
        Get<ComboBox>("ReplyChoice").SelectionChanged+=delegate {draft.ReplyMode=Get<ComboBox>("ReplyChoice").SelectedIndex==1?"send":"draft";};
        Get<CheckBox>("SoundChoice").Click+=delegate { draft.Sound=Get<CheckBox>("SoundChoice").IsChecked==true; };
        Get<CheckBox>("AutoChoice").Click+=delegate { draft.AutoOpen=Get<CheckBox>("AutoChoice").IsChecked==true; Refresh(); };
        Get<CheckBox>("StartupChoice").Click+=delegate { draft.Startup=Get<CheckBox>("StartupChoice").IsChecked==true; };
        Get<Button>("PreviewExpand").Click+=delegate { previewExpanded=true; Refresh(); };
        Get<Button>("PreviewCollapse").Click+=delegate { previewExpanded=false; Refresh(); };
        foreach(string name in new[]{"PreviewOpen","PreviewMiniOpen"}) Get<Button>(name).Click+=delegate { Get<TextBlock>("PreviewStatus").Text="Чат открыт · демонстрация"; };
        Get<Button>("PreviewAck").Click+=delegate { Get<TextBlock>("PreviewStatus").Text="Уведомление скрыто · открытие отменено"; };
        string[] previewReplies={"PreviewYes","PreviewNext","PreviewDo"};for(int i=0;i<previewReplies.Length;i++) {string text=QuickReply.Texts[i];Get<Button>(previewReplies[i]).Click+=delegate {Get<TextBlock>("PreviewStatus").Text=(draft.ReplyMode=="send"?"Отправить: ":"Вставить: ")+text+" · демонстрация";};}
        Get<Button>("TestNotice").Click+=delegate { Test(); };
        Get<Button>("SaveSettings").Click+=delegate {
            try { draft.SetupComplete=true; save(draft.Copy()); window.Close(); }
            catch(Exception e) { MessageBox.Show(window,"Не удалось сохранить настройки.\n"+e.Message,"Codex Notifier",MessageBoxButton.OK,MessageBoxImage.Error); }
        };
        themeTimer=new DispatcherTimer {Interval=TimeSpan.FromSeconds(2)};
        themeTimer.Tick+=delegate { if(dark!=draft.IsDark()) {dark=draft.IsDark();DesktopUi.ApplyTheme(window,draft);Refresh();} }; themeTimer.Start();
        previewTimer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(250)};
        previewTimer.Tick+=delegate {
            if(testPopup==null)return;
            int left=Math.Max(0,(int)Math.Ceiling((previewDeadline-DateTime.UtcNow).TotalSeconds));
            testPopup.UpdateSeconds(left);
            if(left==0) { StopTest(); Get<TextBlock>("PreviewStatus").Text="Тест завершён. При обычном уведомлении откроется Codex."; }
        };
        window.Closed+=delegate { themeTimer.Stop(); StopTest(); };
        Refresh();
    }
    void Refresh() {
        Get<Button>("SmallSize").Style=(Style)window.FindResource(draft.Size=="small"?(object)"Primary":typeof(Button));
        Get<Button>("LargeSize").Style=(Style)window.FindResource(draft.Size=="large"?(object)"Primary":typeof(Button));
        Get<Grid>("PreviewMini").Visibility=previewExpanded?Visibility.Collapsed:Visibility.Visible;
        Get<StackPanel>("PreviewLarge").Visibility=previewExpanded?Visibility.Visible:Visibility.Collapsed;
        Get<Border>("PreviewShell").Padding=new Thickness(previewExpanded?12:6);
        Get<ComboBox>("DelayChoice").IsEnabled=draft.AutoOpen;
        Get<TextBlock>("PreviewCountdown").Text=draft.AutoOpen?"До открытия чата: "+draft.DelaySeconds+" сек.":"Открытие по нажатию";
        Get<Border>("PreviewProgress").Visibility=draft.AutoOpen?Visibility.Visible:Visibility.Collapsed;
    }
    void StopTest() { previewTimer.Stop(); if(testPopup!=null) { testPopup.Dispose(); testPopup=null; } }
    void Test() {
        StopTest();
        testPopup=new Popup("Проверка уведомления",delegate {StopTest();Get<TextBlock>("PreviewStatus").Text="Чат открыт · демонстрация";},delegate {StopTest();Get<TextBlock>("PreviewStatus").Text="Уведомление скрыто · открытие отменено";},draft);
        testPopup.Show(); if(draft.Sound)System.Media.SystemSounds.Exclamation.Play();
        Get<TextBlock>("PreviewStatus").Text="Тестовое уведомление показано возле часов.";
        if(draft.AutoOpen) {previewDeadline=DateTime.UtcNow.AddSeconds(draft.DelaySeconds);previewTimer.Start();}
    }
    public void Show() {window.Show();window.Activate();}
}
