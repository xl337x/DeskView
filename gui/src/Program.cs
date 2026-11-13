// DeskView.exe
//   DeskView.exe                 start (opens the window; the setup assistant the first time)
//   DeskView.exe --tray          start in the tray only (used at sign-in)
//   DeskView.exe --show 2        tell the running DeskView: show the other computer on monitor 2 (or "2=1", "off")
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace DeskView
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
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
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (o, e) => { Log.Write("error: " + e.Exception); MessageBox.Show("DeskView hit a problem: " + e.Exception.Message, "DeskView"); };
                AppDomain.CurrentDomain.UnhandledException += (o, e) => Log.Write("fatal: " + e.ExceptionObject);

                StopScriptVersion();
                var settings = AppSettings.Load();
                Migration.FromScriptVersion(settings);
                var engine = new Engine(settings);
                if (show != null) File.WriteAllText(Path.Combine(AppSettings.Dir, "command.txt"), show);
                Application.Run(new TrayApp(engine, !tray));
            }
        }

        /// <summary>The PowerShell DeskView uses the same ports: stop it while the app runs.</summary>
        static void StopScriptVersion()
        {
            try
            {
                using (var q = new System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
                    foreach (System.Management.ManagementObject p in q.Get())
                    {
                        var cmd = (p["CommandLine"] as string) ?? "";
                        if (cmd.Contains("DeskView.ps1")) { try { Process.GetProcessById(Convert.ToInt32(p["ProcessId"])).Kill(); } catch { } }
                    }
                // Its startup entry stays: if this app is ever blocked or removed, the script version takes over again
                // (it steps aside by itself whenever DeskView.exe is running).
            }
            catch { }
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
                    if (d.TryGetValue("PairCode", out var pc)) s.PairCode = pc as string ?? "";
                    if (d.TryGetValue("Peer", out var peer)) s.Peer = peer as string ?? "";
                    if (d.TryGetValue("Profile", out var pr)) s.Profile = pr as string ?? "Auto";
                    if (d.TryGetValue("Picture", out var pi)) s.Picture = pi as string ?? "Fit";
                    if (d.TryGetValue("Encoder", out var en)) s.Encoder = en as string ?? "";
                    if (d.TryGetValue("Interactive", out var ia) && ia is bool b) s.Interactive = b;
                    if (d.TryGetValue("Screens", out var sc) && sc is System.Collections.Generic.Dictionary<string, object> map)
                        foreach (var kv in map) s.Screens[kv.Key] = Convert.ToInt32(kv.Value);
                }
                var ini = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Deskflow\Deskflow.conf");
                if (File.Exists(ini))
                {
                    var text = File.ReadAllText(ini);
                    string Val(string key) { var m = System.Text.RegularExpressions.Regex.Match(text, "(?m)^" + key + "=(.*)$"); return m.Success ? m.Groups[1].Value.Trim() : null; }
                    var mode = Val("coreMode");
                    s.Role = mode == "2" ? Role.Server : mode == "1" ? Role.Client : Role.None;
                    s.ComputerName = Val("computerName") ?? s.ComputerName;
                    s.ServerAddress = Val("remoteHost") ?? "";
                    if (int.TryParse(Val("port"), out int port)) s.Port = port;
                    s.TlsEnabled = Val("tlsEnabled") != "false";
                    if (s.Role == Role.Server)
                        s.RemoteName = System.Text.RegularExpressions.Regex.Matches(text, @"(?m)^\[computer_(.+)\]\s*$").Cast<System.Text.RegularExpressions.Match>()
                            .Select(m => m.Groups[1].Value).FirstOrDefault(n => n != s.ComputerName) ?? "";
                }
                if (s.Role != Role.None && AppSettings.IsValidPairCode(s.PairCode)) s.SetupDone = true;
                s.Save();
                Log.Write($"settings carried over: role {s.Role}, name {s.ComputerName}, other {s.RemoteName}");
            }
            catch (Exception e) { Log.Write("migration: " + e.Message); }
        }
    }
}
