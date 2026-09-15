using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Threading;

static class SelfTest {
    static void Check(bool value,string name) { if(!value)throw new Exception(name); }
    static void Poll(SessionWatcher watcher) {Thread.Sleep(60);watcher.Poll();}
    static string Row(string kind,string turn,DateTime time) {
        return "{\"timestamp\":\""+time.ToString("o")+"\",\"type\":\"event_msg\",\"payload\":{\"type\":\""+kind+"\",\"turn_id\":\""+turn+"\"}}\n";
    }
    public static void Run() {
        string root=Path.Combine(Path.GetTempPath(),"CodexNotifier-test-"+Guid.NewGuid());
        Directory.CreateDirectory(root);
        SessionWatcher w=null;
        try {
            string file=Path.Combine(root,"rollout-2026-09-15T00-00-00-11111111-2222-4333-8444-555555555555.jsonl");
            File.WriteAllText(file,Row("task_complete","old",DateTime.UtcNow.AddHours(-1)),new UTF8Encoding(false));
            var seen=new List<string>();
            w=new SessionWatcher(root); w.OnEvent=(kind,id,turn)=>seen.Add(kind+":"+turn);
            w.Baseline(); Poll(w); Check(seen.Count==0,"startup must not replay history");
            DateTime now=DateTime.UtcNow.AddSeconds(2);
            File.AppendAllText(file,Row("task_complete","one",now),new UTF8Encoding(false));
            Poll(w); Check(seen.Count==1,"completion detected");
            Poll(w); Check(seen.Count==1,"unchanged file does not replay");
            File.AppendAllText(file,Row("task_complete","one",now));
            Poll(w); Check(seen.Count==1,"duplicate completion ignored");
            string partial=Row("task_complete","two",now);
            File.AppendAllText(file,partial.Substring(0,partial.Length-2));
            Poll(w); Check(seen.Count==1,"partial JSON waits");
            File.AppendAllText(file,partial.Substring(partial.Length-2));
            Poll(w); Check(seen.Count==2,"partial JSON completed");
            File.AppendAllText(file,Row("task_started","three",now));
            Poll(w); Check(seen[2]=="task_started:three","new turn cancels pending notification via callback");
            w.ProcessLine(file,Row("task_complete","ancient",DateTime.UtcNow.AddDays(-1)));
            Check(seen.Count==3,"old timestamp ignored");
            w.ProcessLine(file,"invalid JSON"); Check(seen.Count==3,"malformed row ignored");
            File.WriteAllText(file,Row("turn_aborted","stop",now),new UTF8Encoding(false));
            Poll(w); Check(seen.Count==4,"truncated file recovers and abort detected");
            string newFile=Path.Combine(root,"rollout-2026-09-15T00-00-01-11111111-2222-4333-8444-555555555555.jsonl");
            File.WriteAllText(newFile,Row("task_complete","new-file",now),new UTF8Encoding(false));Poll(w);Check(seen.Count==5,"new file discovered by filesystem notification");
            int errors=0;w.OnError=error=>errors++;
            w.ProcessLine(file,"{\"timestamp\":\""+now.ToString("o")+"\",\"type\":\"response_item\",\"payload\":BROKEN "+new string('x',1000000));
            Check(errors==0,"irrelevant large payload is not deserialized");
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"test-result.txt"),"PASS: 11 event-reader checks\r\n");
        } catch(Exception e) { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"test-result.txt"),"FAIL: "+e); Environment.ExitCode=1; }
        finally {if(w!=null)w.Dispose(); Directory.Delete(root,true); }
    }
}
