using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

static class UiRegression {
    static int count;
    static void Check(bool ok,string name) { if(!ok)throw new Exception(name); count++; }
    static void Click(Window window,string name) { DesktopUi.Get<Button>(window,name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); }
    static void Pump() { System.Windows.Forms.Application.DoEvents(); }
    static void Capture(Window window,string path) {
        window.UpdateLayout(); FrameworkElement content=(FrameworkElement)window.Content;
        var bitmap=new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth),(int)Math.Ceiling(content.ActualHeight),96,96,PixelFormats.Pbgra32);
        var drawing=new DrawingVisual();using(var context=drawing.RenderOpen()) {var rect=new Rect(0,0,content.ActualWidth,content.ActualHeight);context.DrawRectangle((Brush)window.Resources["Surface"],null,rect);context.DrawRectangle(new VisualBrush(content),null,rect);} bitmap.Render(drawing);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var stream=File.Create(path))encoder.Save(stream);
    }
    [STAThread] static void Main(string[] args) {
        string dir=Path.Combine(Path.GetTempPath(),"CodexNotifier-settings-test-"+Guid.NewGuid()); Directory.CreateDirectory(dir);
        string result=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"ui-test-result.txt");
        try {
            string path=Path.Combine(dir,"settings.json");
            var defaults=AppSettings.Load(path);Check(!defaults.SetupComplete && defaults.Size=="small" && defaults.Theme=="auto","first run defaults");
            var changed=new AppSettings {Theme="dark",Size="large",DelaySeconds=60,Sound=false,AutoOpen=false,SetupComplete=true};changed.Save(path);
            var loaded=AppSettings.Load(path);Check(loaded.Theme=="dark" && loaded.Size=="large" && loaded.DelaySeconds==60 && !loaded.Sound && !loaded.AutoOpen && loaded.SetupComplete,"settings roundtrip");
            loaded.Theme="light";loaded.Save(path);Check(AppSettings.Load(path).Theme=="light","atomic overwrite");
            File.WriteAllText(path,"broken");Check(!AppSettings.Load(path).SetupComplete,"corrupt settings fallback");
            changed.Theme="invalid";changed.Size="invalid";changed.DelaySeconds=-2;changed.Normalize();Check(changed.Theme=="auto" && changed.Size=="small" && changed.DelaySeconds==30,"invalid settings normalized");
            changed.ReplyMode="send";changed.Save(path);Check(AppSettings.Load(path).ReplyMode=="send","reply mode persisted");
            string tid="11111111-2222-4333-8444-555555555555";
            Check(QuickReply.Link(tid,"Да")=="codex://threads/"+tid+"?prompt=%D0%94%D0%B0","reply targets exact task with encoded text");
            Check(QuickReply.DraftFromJson("{\"electron-persisted-atom-state\":{\"composer-prompt-drafts-v2\":{\"local:"+tid+"\":\"Да\"}}}",tid)=="Да","read target draft");
            Check(QuickReply.DraftFromJson("{\"electron-persisted-atom-state\":{\"thread-client-id-v1:local%3A"+tid+"\":\"client-new-thread:abc\",\"composer-prompt-drafts-v2\":{\"client-new-thread:abc\":\"Дальше\"}}}",tid)=="Дальше","read aliased draft");
            bool rejected=false;try{QuickReply.Link("invalid","Да");}catch(ArgumentException){rejected=true;}Check(rejected,"reject invalid target");
            using(var popup=new Popup("Проверка длинного названия задачи",delegate {},delegate {},new AppSettings {Theme="light"})) {
                popup.Show();Pump();Check(!popup.Expanded && popup.Window.Width==168,"compact popup default");
                Click(popup.Window,"Expand");Pump();Check(popup.Expanded && popup.Window.Width==320,"ellipsis expands popup");
                Check(DesktopUi.Get<Button>(popup.Window,"ReplyYes").Content.ToString()=="Да" && DesktopUi.Get<Button>(popup.Window,"ReplyNext").Content.ToString()=="Дальше" && DesktopUi.Get<Button>(popup.Window,"ReplyDo").Content.ToString()=="Делай","three quick replies shown");
                Click(popup.Window,"ReplyYes");Check(DesktopUi.Get<TextBlock>(popup.Window,"ReplyStatus").Text.Contains("Да"),"test reply does not send chat message");
                popup.UpdateSeconds(15);Check(DesktopUi.Get<TextBlock>(popup.Window,"Countdown").Text.Contains("15"),"countdown update");
                Click(popup.Window,"Collapse");Check(!popup.Expanded,"collapse popup");
            }
            using(var popup=new Popup("По нажатию",delegate {},delegate {},new AppSettings {AutoOpen=false,Size="large",Theme="dark"})) {
                Check(DesktopUi.Get<Border>(popup.Window,"Track").Visibility==Visibility.Collapsed,"manual-only hides countdown track");
                Check(DesktopUi.Get<TextBlock>(popup.Window,"Countdown").Text=="Открытие по нажатию","manual-only copy");
            }
            AppSettings saved=null;var dialog=new SettingsDialog(new AppSettings {Theme="light"},s=>saved=s);dialog.Show();Pump();
            Capture(dialog.Window,Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"settings-light.png"));
            Click(dialog.Window,"LargeSize");Check(DesktopUi.Get<StackPanel>(dialog.Window,"PreviewLarge").Visibility==Visibility.Visible,"size preview updates");
            DesktopUi.Get<ComboBox>(dialog.Window,"ThemeChoice").SelectedIndex=2;Pump();
            Check(((SolidColorBrush)dialog.Window.Resources["Surface"]).Color==Color.FromRgb(25,30,33),"dark theme applied");
            Capture(dialog.Window,Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"settings-dark.png"));
            DesktopUi.Get<ComboBox>(dialog.Window,"DelayChoice").SelectedIndex=0;
            DesktopUi.Get<ComboBox>(dialog.Window,"ReplyChoice").SelectedIndex=1;
            Click(dialog.Window,"SaveSettings");Check(saved!=null && saved.SetupComplete && saved.Size=="large" && saved.Theme=="dark" && saved.DelaySeconds==15 && saved.ReplyMode=="send","save reads selected controls");
            File.WriteAllText(result,"PASS: "+count+" settings and UI checks");
            if(Array.IndexOf(args,"--measure")>=0) {
                dialog=null;saved=null;
                var process=System.Diagnostics.Process.GetCurrentProcess();double cpu=process.TotalProcessorTime.TotalSeconds;var watch=System.Diagnostics.Stopwatch.StartNew();
                using(var context=new System.Windows.Forms.ApplicationContext())using(var timer=new System.Windows.Forms.Timer {Interval=10000}) {
                    timer.Tick+=delegate {process.Refresh();File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"ui-memory.txt"),"After closing UI: working set MB="+Math.Round(process.WorkingSet64/1048576.0,1)+", private MB="+Math.Round(process.PrivateMemorySize64/1048576.0,1)+", one-core CPU percent="+Math.Round(100*(process.TotalProcessorTime.TotalSeconds-cpu)/watch.Elapsed.TotalSeconds,3));timer.Stop();context.ExitThread();};timer.Start();System.Windows.Forms.Application.Run(context);
                }
            }
        } catch(Exception e) { File.WriteAllText(result,"FAIL: "+e);Environment.ExitCode=1; }
        finally { Directory.Delete(dir,true); }
    }
}
