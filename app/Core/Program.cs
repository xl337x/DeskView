// DeskView's entry point, called by DeskView.ps1 after it compiled the app in memory:
//   --tray          start in the tray only (used at sign-in)
//   --show 2        tell the running DeskView: show the other computer on monitor 2 (or "2=1", "off")
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace DeskView
{
    public static class Program
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        /// <summary>The app folder (DeskView.ps1 sets DESKVIEW_APPDIR before calling Main).</summary>
        public static string AppDir
        {
            get { var d = Environment.GetEnvironmentVariable("DESKVIEW_APPDIR"); return string.IsNullOrEmpty(d) ? AppDomain.CurrentDomain.BaseDirectory : d; }
        }

        [STAThread]
        public static void Main(string[] args)
        {
            string show = null; bool tray = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--tray") tray = true;
                else if (args[i] == "--show" && i + 1 < args.Length) show = args[++i];
            }

            using (var mutex = new Mutex(false, @"Local\DeskViewApp"))
            {
                if (!mutex.WaitOne(0))
                {
                    // already running: pass the command on, or bring its window up
                    Directory.CreateDirectory(AppSettings.Dir);
                    File.WriteAllText(Path.Combine(AppSettings.Dir, "command.txt"), show ?? "");
                    return;
                }
                // 1:1 pixels on scaled monitors (the old .exe had this in its manifest; powershell.exe has none)
                try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
                Application.EnableVisualStyles();
                try { Application.SetCompatibleTextRenderingDefault(false); } catch (InvalidOperationException) { }   // PowerShell may have made a window already
                Application.ThreadException += (o, e) => { Log.Write("error: " + e.Exception); MessageBox.Show("DeskView hit a problem: " + e.Exception.Message, "DeskView"); };
                AppDomain.CurrentDomain.UnhandledException += (o, e) => Log.Write("fatal: " + e.ExceptionObject);

                var settings = AppSettings.Load();
                Migration.FromScriptVersion(settings);
                Migration.FromSetup(settings);
                var engine = new Engine(settings);
                if (show != null) File.WriteAllText(Path.Combine(AppSettings.Dir, "command.txt"), show);
                Application.Run(new TrayApp(engine, !tray));
            }
        }
    }

    /// <summary>Carry over settings from the PowerShell DeskView and the engine, so nothing has to be set up again.</summary>
    static class Migration
    {
        public static void FromScriptVersion(AppSettings s)
        {
            if (File.Exists(AppSettings.FilePath)) return;
            try
            {
                var old = Path.Combine(AppSettings.Dir, "settings.json");
                if (File.Exists(old))
                {
                    dynamic o = new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(File.ReadAllText(old));
                    var d = (System.Collections.Generic.Dictionary<string, object>)o;
                    object pc, peer, pr, pi, en, ia, sc;
                    if (d.TryGetValue("PairCode", out pc)) s.PairCode = pc as string ?? "";
                    if (d.TryGetValue("Peer", out peer)) s.Peer = peer as string ?? "";
                    if (d.TryGetValue("Profile", out pr)) s.Profile = pr as string ?? "Auto";
                    if (d.TryGetValue("Picture", out pi)) s.Picture = pi as string ?? "Fit";
                    if (d.TryGetValue("Encoder", out en)) s.Encoder = en as string ?? "";
                    if (d.TryGetValue("Interactive", out ia) && ia is bool) s.Interactive = (bool)ia;
                    System.Collections.Generic.Dictionary<string, object> map = null;
                    if (d.TryGetValue("Screens", out sc) && (map = sc as System.Collections.Generic.Dictionary<string, object>) != null)
                        foreach (var kv in map) s.Screens[kv.Key] = Convert.ToInt32(kv.Value);
                    object eng, side, rn;
                    if (d.TryGetValue("InputEngine", out eng) && eng is string) s.InputEngine = (string)eng;
                    if (d.TryGetValue("RemoteName", out rn) && rn is string && ((string)rn).Length > 0) s.RemoteName = (string)rn;
                    if (d.TryGetValue("Side", out side) && side is string)
                    {
                        Side sd;
                        if (Enum.TryParse((string)side, true, out sd)) s.RemoteSide = sd;
                    }
                }
                var ini = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Deskflow\Deskflow.conf");
                if (File.Exists(ini))
                {
                    var text = File.ReadAllText(ini);
                    Func<string, string> Val = key => { var m = System.Text.RegularExpressions.Regex.Match(text, "(?m)^" + key + "=(.*)$"); return m.Success ? m.Groups[1].Value.Trim() : null; };
                    var mode = Val("coreMode");
                    s.Role = mode == "2" ? Role.Server : mode == "1" ? Role.Client : Role.None;
                    s.ComputerName = Val("computerName") ?? s.ComputerName;
                    s.ServerAddress = Val("remoteHost") ?? "";
                    int port;
                    if (int.TryParse(Val("port"), out port)) s.Port = port;
                    s.TlsEnabled = Val("tlsEnabled") != "false";
                    if (s.Role == Role.Server)
                        s.RemoteName = System.Text.RegularExpressions.Regex.Matches(text, @"(?m)^\[computer_(.+)\]\s*$").Cast<System.Text.RegularExpressions.Match>()
                            .Select(m => m.Groups[1].Value).FirstOrDefault(n => n != s.ComputerName) ?? "";
                }
                if (s.Role != Role.None && AppSettings.IsValidPairCode(s.PairCode)) s.SetupDone = true;
                s.Save();
                Log.Write(string.Format("settings carried over: role {0}, name {1}, other {2}", s.Role, s.ComputerName, s.RemoteName));
            }
            catch (Exception e) { Log.Write("migration: " + e.Message); }
        }

        /// <summary>Setup (DeskView-Setup.ps1) leaves the role and pairing code in setup.json: apply them once.</summary>
        public static void FromSetup(AppSettings s)
        {
            var f = Path.Combine(AppSettings.Dir, "setup.json");
            if (!File.Exists(f)) return;
            try
            {
                var d = (System.Collections.Generic.Dictionary<string, object>)new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(File.ReadAllText(f));
                object role, code, server;
                if (d.TryGetValue("Role", out role) && role is string)
                {
                    var r = ((string)role).ToLowerInvariant();
                    if (r == "server") s.Role = Role.Server; else if (r == "client") s.Role = Role.Client;
                }
                if (d.TryGetValue("PairCode", out code) && code is string && AppSettings.IsValidPairCode((string)code)) s.PairCode = ((string)code).Trim().ToUpperInvariant();
                if (d.TryGetValue("ServerAddress", out server) && server is string && ((string)server).Length > 0) s.ServerAddress = (string)server;
                if (s.Role != Role.None && AppSettings.IsValidPairCode(s.PairCode)) s.SetupDone = true;
                s.Save();
                File.Delete(f);
                Log.Write(string.Format("setup applied: role {0}", s.Role));
            }
            catch (Exception e) { Log.Write("setup.json: " + e.Message); }
        }
    }
}
