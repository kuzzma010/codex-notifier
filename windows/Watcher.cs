using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Collections.Concurrent;

public sealed class Notice {
    public string Thread, Turn, Title;
    public DateTime Deadline;
}

public sealed class SessionWatcher : IDisposable {
    sealed class Cursor { public long Offset; }
    readonly Dictionary<string, Cursor> cursors = new Dictionary<string, Cursor>();
    readonly HashSet<string> completed = new HashSet<string>();
    readonly Queue<string> completionOrder = new Queue<string>();
    readonly ConcurrentDictionary<string,byte> dirty = new ConcurrentDictionary<string,byte>();
    FileSystemWatcher fileWatcher;
    volatile bool rescan;
    readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 33554432 };
    readonly DateTime started = DateTime.UtcNow;
    readonly string root;
    public Action<string,string,string> OnEvent;
    public Action<string> OnError;
    public SessionWatcher(string directory) { root = directory; }
    public void Baseline() {
        if (!Directory.Exists(root)) return;
        fileWatcher=new FileSystemWatcher(root,"rollout-*.jsonl") {IncludeSubdirectories=true,NotifyFilter=NotifyFilters.LastWrite|NotifyFilters.Size|NotifyFilters.FileName,InternalBufferSize=16384};
        fileWatcher.Changed+=delegate(object sender,FileSystemEventArgs e) {dirty[e.FullPath]=0;};
        fileWatcher.Created+=delegate(object sender,FileSystemEventArgs e) {dirty[e.FullPath]=0;};
        fileWatcher.Renamed+=delegate(object sender,RenamedEventArgs e) {dirty[e.FullPath]=0;};
        fileWatcher.Deleted+=delegate(object sender,FileSystemEventArgs e) {dirty[e.FullPath]=0;};
        fileWatcher.Error+=delegate {rescan=true;};
        foreach(string file in Directory.EnumerateFiles(root,"rollout-*.jsonl",SearchOption.AllDirectories)) {
            try {cursors[file]=new Cursor {Offset=new FileInfo(file).Length};}catch(IOException){}
        }
        fileWatcher.EnableRaisingEvents=true;
        // One reconciliation closes the gap between taking offsets and enabling events.
        rescan=true;
    }
    public void Poll() {
        if(fileWatcher==null) {Baseline();return;}
        if(rescan) {rescan=false;foreach(string file in Directory.EnumerateFiles(root,"rollout-*.jsonl",SearchOption.AllDirectories))dirty[file]=0;}
        foreach(string file in dirty.Keys) {
            byte ignored;if(!dirty.TryRemove(file,out ignored))continue;
            if(!File.Exists(file)) {cursors.Remove(file);continue;}
            Cursor c;if(!cursors.TryGetValue(file,out c)) {c=new Cursor();cursors[file]=c;}
            try {Read(file,c);}catch(IOException){dirty[file]=0;}catch(UnauthorizedAccessException){}
        }
    }
    public void Dispose() {if(fileWatcher!=null){fileWatcher.Dispose();fileWatcher=null;}}
    void Read(string file, Cursor c) {
        using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            if (f.Length == c.Offset) return;
            if (f.Length < c.Offset) c.Offset = 0;
            f.Seek(c.Offset, SeekOrigin.Begin);
            // Decode complete byte lines only, so a split UTF-8 character is not corrupted.
            using (MemoryStream line = new MemoryStream()) {
                long safe = c.Offset;
                int b;
                while ((b = f.ReadByte()) != -1) {
                    if (b == 10) {
                        string value = Encoding.UTF8.GetString(line.ToArray());
                        ProcessLine(file, value); line.SetLength(0); safe = f.Position;
                    } else { if(line.Length<1048576)line.WriteByte((byte)b); }
                }
                c.Offset = safe;
            }
        }
    }
    public void ProcessLine(string file, string line) {
        // Event type is in the short JSON header. Never deserialize tool payloads,
        // assistant text or token accounting just to discover they are irrelevant.
        int payload=line.IndexOf("\"payload\"",StringComparison.Ordinal);
        if(payload<0 || payload>256)return;
        string header=line.Substring(0,payload);
        if(header.IndexOf("\"event_msg\"",StringComparison.Ordinal)<0)return;
        int eventType=line.IndexOf("\"type\"",payload,StringComparison.Ordinal);
        if(eventType<0 || eventType>payload+40)return;
        int colon=line.IndexOf(':',eventType),quote=colon<0?-1:line.IndexOf('"',colon+1),end=quote<0?-1:line.IndexOf('"',quote+1);
        if(end<0)return;
        string eventName=line.Substring(quote+1,end-quote-1);
        if(eventName!="task_complete" && eventName!="task_started" && eventName!="turn_aborted")return;
        try {
            var row = json.Deserialize<Dictionary<string,object>>(line);
            if (Value(row,"type") != "event_msg") return;
            DateTime time;
            if (!DateTime.TryParse(Value(row,"timestamp"), null, System.Globalization.DateTimeStyles.RoundtripKind, out time) || time.ToUniversalTime() < started) return;
            var p = row["payload"] as Dictionary<string,object>;
            if (p == null) return;
            string kind = Value(p,"type"), turn = Value(p,"turn_id");
            if (kind != "task_complete" && kind != "task_started" && kind != "turn_aborted") return;
            string name = Path.GetFileNameWithoutExtension(file);
            if (name.Length < 36) return;
            string thread = name.Substring(name.Length - 36);
            Guid id;
            if (!Guid.TryParse(thread, out id)) return;
            if (kind != "task_started") {
                string key=thread+":"+turn+":"+kind;if(!completed.Add(key))return;
                completionOrder.Enqueue(key);if(completionOrder.Count>2048)completed.Remove(completionOrder.Dequeue());
            }
            if (OnEvent != null) OnEvent(kind, thread, turn);
        } catch (Exception e) { if (OnError != null) OnError(e.GetType().Name); }
    }
    static string Value(Dictionary<string,object> d, string k) { object v; return d.TryGetValue(k,out v) && v != null ? v.ToString() : ""; }
}
