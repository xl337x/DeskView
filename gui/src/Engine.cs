// DeskView's brain: keeps the keyboard/mouse engine, the video streams, the portals and the remote-control channel
// in line with the settings, four times a second, on the UI thread (like a game loop, but cheap).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace DeskView
{
    public class Engine
    {
        public readonly AppSettings S;
        public readonly Media Media;
        readonly DeskViewAgent agent = new DeskViewAgent();
        readonly DeskViewForwarder forwarder = new DeskViewForwarder();
        readonly Timer timer = new Timer { Interval = 250 };
        string layoutSig = "", lastPortal = null;
        readonly Dictionary<string, DeskViewDropZone> zones = new Dictionary<string, DeskViewDropZone>();
        readonly List<DeskViewTransfer> transfers = new List<DeskViewTransfer>();
        DateTime lastReceivedNotice = DateTime.MinValue;
        DateTime lastSlow = DateTime.MinValue;
        public string LastOn = "";

        public event Action Changed;                  // something the UI shows changed
        public event Action<string, bool> Notice;     // message, isWarning

        public Engine(AppSettings settings)
        {
            S = settings;
            Media = new Media(S);
            Media.Notice += (m, w) => Notice?.Invoke(m, w);
        }

        // ------------------------------------------------------------------------------------------------- state
        public bool Connected => !string.IsNullOrEmpty(CurrentPeer());
        public bool EngineRunning => CoreControl.Running;
        public string AgentClient => agent.Client;
        public bool ForwarderConnected => forwarder.Connected;
        public string ForwarderStatus => forwarder.Status;

        /// <summary>The other computer's address, from the live keyboard/mouse connection.</summary>
        public string CurrentPeer()
        {
            try
            {
                foreach (var c in IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpConnections())
                {
                    if (c.State != TcpState.Established) continue;
                    if (S.Role == Role.Server && c.LocalEndPoint.Port == S.Port) return c.RemoteEndPoint.Address.ToString();
                    if (S.Role == Role.Client && c.RemoteEndPoint.Port == S.Port) return c.RemoteEndPoint.Address.ToString();
                }
            }
            catch { }
            return null;
        }

        string Peer()
        {
            var p = CurrentPeer();
            if (!string.IsNullOrEmpty(p) && p != S.Peer) { S.Peer = p; S.Save(); }
            if (!string.IsNullOrEmpty(S.Peer)) agent.AllowedIps = new[] { S.Peer, "::ffff:" + S.Peer };
            return S.Peer;
        }

        // ------------------------------------------------------------------------------------------------- start/stop
        public void Start()
        {
            DeskViewPortal.UsePhysicalPixels();
            agent.Port = S.ControlPort; agent.Code = S.PairCode;
            var all = Screen.AllScreens;
            agent.VL = all.Min(s => s.Bounds.Left); agent.VR = all.Max(s => s.Bounds.Right);
            agent.AvoidLeftEdge = agent.AvoidRightEdge = S.Role == Role.Server;   // The engine's links sit on the outer edges
            SetAgentScreen("1");
            try { agent.Start(); } catch { Notice?.Invoke($"Control port {S.ControlPort} is in use - control from the other computer is off.", true); }
            forwarder.Port = S.ControlPort; forwarder.Code = S.PairCode;
            if (S.Role == Role.Client) forwarder.Peer = Peer() ?? "";
            forwarder.Start();
            if (S.Role == Role.Client) S.ClientView = 0;      // start on this computer's own screen
            ApplyEngine(true);
            layoutSig = LayoutSignature();
            Media.ServiceSenders();
            SyncPlayers();
            timer.Tick += (o, e) => Tick();
            timer.Start();
        }

        public void Shutdown()
        {
            timer.Stop();
            try { if (S.Role == Role.Server) CoreControl.WriteConfig(S, null); } catch { }   // no portal left behind
            foreach (var z in zones.Values) z.Close();
            forwarder.Stop(); agent.Stop(); Media.StopPlayers(); Media.StopSenders();
        }

        /// <summary>Write the engine settings; start or restart the engine when they changed (or when asked).</summary>
        public void ApplyEngine(bool forceStart = false)
        {
            if (S.Role == Role.None) return;
            bool changed = CoreControl.WriteConfig(S, S.Role == Role.Server ? PortalValue() : null);
            if (changed || forceStart || !CoreControl.Running)
            {
                if (S.StartEngineOnLaunch || forceStart || changed)
                    if (!CoreControl.Start()) Notice?.Invoke(CoreControl.LastError, true);
            }
        }

        public void RestartEngine() { CoreControl.Stop(); System.Threading.Thread.Sleep(500); if (!CoreControl.Start()) Notice?.Invoke(CoreControl.LastError, true); }
        public void StopEngine() => CoreControl.Stop();

        // ------------------------------------------------------------------------------------------------- screens
        IEnumerable<(string, Screen, int)> WantedPlayers()
        {
            if (S.Role == Role.Server)
            {
                foreach (var kv in S.Screens) { var m = Tools.ByName(kv.Key); if (m != null && kv.Value > 0) yield return (kv.Key, m, kv.Value); }
            }
            else if (S.Role == Role.Client && S.ClientView > 0) yield return ("view", Screen.PrimaryScreen, S.ClientView);
        }

        public void SyncPlayers()
        {
            Media.SyncPlayers(WantedPlayers(), Peer());
            UpdateDropZones();
            if (S.Role == Role.Server) UpdatePortals();
            else
            {
                if (S.ClientView <= 0) { forwarder.Active = false; return; }
                forwarder.Peer = Peer() ?? "";
                forwarder.SelectMonitor(S.ClientView.ToString());
                UpdateForwarderPicture();
                forwarder.Active = true;
            }
            Changed?.Invoke();
        }

        /// <summary>Server: monitor shows the other computer's screen n (0 = its own desktop again).</summary>
        public void SetScreen(string monitor, int n)
        {
            if (n > 0) foreach (var k in S.Screens.Where(kv => kv.Value == n).Select(kv => kv.Key).ToList()) S.Screens.Remove(k);   // one stream, one monitor
            if (n <= 0) S.Screens.Remove(monitor); else { S.Screens[monitor] = n; LastOn = monitor; }
            S.Save(); SyncPlayers();
        }

        /// <summary>Hotkey / command: server - put the other computer's screen 1 on monitor "want"; client - view server screen.</summary>
        public void ShowOn(string want)
        {
            var m = Regex.Match(want ?? "", @"^(\w+)=(\d)$");
            if (S.Role == Role.Server && m.Success) { var name = ResolveMonitor(m.Groups[1].Value); if (name != null) SetScreen(name, int.Parse(m.Groups[2].Value)); return; }
            if (string.IsNullOrEmpty(want) || want.Equals("off", StringComparison.OrdinalIgnoreCase))
            {
                if (S.Role == Role.Server) S.Screens.Clear(); else S.ClientView = 0;
                S.Save(); SyncPlayers(); Notice?.Invoke(S.Role == Role.Server ? "Other computer's screens off" : "Back to this computer", false); return;
            }
            if (S.Role == Role.Server)
            {
                var name = ResolveMonitor(want);
                if (name == null) { Notice?.Invoke("There is no monitor " + want + ".", true); return; }
                SetScreen(name, 1);
                Notice?.Invoke($"{S.RemoteName} shown on {name}", false);
            }
            else if (int.TryParse(want, out int n) && n >= 1 && n <= 9)
            {
                S.ClientView = n; LastOn = want; S.Save(); SyncPlayers();
                Notice?.Invoke($"Viewing the other computer's screen {n} - Ctrl+Alt+0 to come back", false);
            }
        }

        public static string ResolveMonitor(string want)
        {
            var list = Tools.OrderedScreens();
            if (int.TryParse(want, out int i)) return i >= 1 && i <= list.Length ? Tools.Short(list[i - 1]) : null;
            var s = list.FirstOrDefault(x => Tools.Short(x).Equals(want, StringComparison.OrdinalIgnoreCase));
            return s == null ? null : Tools.Short(s);
        }

        void OnHotkey(int vk)
        {
            if (vk == 0x30) { ShowOn("off"); return; }
            if (vk == 0x44)
            {
                List<string> names; int idx;
                if (S.Role == Role.Server)
                {
                    names = Tools.OrderedScreens().Select(Tools.Short).ToList(); names.Add("off");
                    var cur = S.Screens.FirstOrDefault(kv => kv.Value == 1).Key;
                    idx = cur == null ? names.Count - 1 : names.IndexOf(cur);
                }
                else { names = new List<string> { "1", "2", "3", "off" }; idx = S.ClientView == 0 ? 3 : S.ClientView - 1; }
                ShowOn(names[(idx + 1) % names.Count]); return;
            }
            ShowOn(((char)vk).ToString());
        }

        void SetAgentScreen(string want)
        {
            var name = ResolveMonitor(want);
            var m = name != null ? Tools.ByName(name) : Screen.PrimaryScreen;
            agent.TL = m.Bounds.Left; agent.TT = m.Bounds.Top; agent.TW = m.Bounds.Width; agent.TH = m.Bounds.Height;
        }

        // ------------------------------------------------------------------------------------------------- portals
        /// <summary>"x,y,w,h,SIDES[@client screen]" for every picture, separated by ';' (for the engine).</summary>
        string PortalValue()
        {
            if (!S.Interactive || !CoreControl.PortalCapable) return null;
            var pls = Media.Players.Values.OrderBy(p => p.Screen.Bounds.X).ToList();
            if (pls.Count == 0) return null;
            var rects = pls.Select(Media.PictureRect).ToList();
            var entries = new List<string>();
            for (int i = 0; i < pls.Count; i++)
            {
                var r = rects[i];
                var e = $"{r.X},{r.Y},{r.Width},{r.Height},{ExitSides(r, rects.Where((x, j) => j != i).ToList())}";
                if (pls[i].RemoteRect != null) e += "@" + pls[i].RemoteRect;
                entries.Add(e);
            }
            return string.Join(";", entries);
        }

        /// <summary>Sides the cursor may leave a picture by: only where everything just outside is on a monitor and
        /// not inside another picture (no landing in gaps, no bouncing straight back into the other computer).</summary>
        static string ExitSides(System.Drawing.Rectangle r, List<System.Drawing.Rectangle> others)
        {
            var mons = Screen.AllScreens.Select(s => s.Bounds).ToList();
            bool Ok(int x, int y) => !others.Any(o => o.Contains(x, y)) && mons.Any(m => m.Contains(x, y));
            bool Covered(IEnumerable<(int, int)> pts) => pts.All(p => Ok(p.Item1, p.Item2));
            var ys = Enumerable.Range(0, 21).Select(k => r.Top + (r.Height - 1) * k / 20).ToList();
            var xs = Enumerable.Range(0, 21).Select(k => r.Left + (r.Width - 1) * k / 20).ToList();
            string sides = "";
            if (Covered(ys.Select(y => (r.Left - 1, y)))) sides += "L";
            if (Covered(ys.Select(y => (r.Right, y)))) sides += "R";
            if (Covered(xs.Select(x => (x, r.Top - 1)))) sides += "T";
            if (Covered(xs.Select(x => (x, r.Bottom)))) sides += "B";
            return sides.Length == 0 ? "LRTB" : sides;
        }

        void UpdatePortals()
        {
            var value = PortalValue();
            if (value == lastPortal) return;
            lastPortal = value;
            // Only the portal changed: the engine re-reads it by itself within a second, no restart needed.
            CoreControl.UpdatePortal(S, value);
        }

        void UpdateForwarderPicture()
        {
            if (!Media.Players.TryGetValue("view", out var pl)) return;
            var r = Media.PictureRect(pl);
            forwarder.VidL = r.X; forwarder.VidT = r.Y; forwarder.VidW = r.Width; forwarder.VidH = r.Height;
        }

        // ------------------------------------------------------------------------------------------------- files
        /// <summary>Invisible drop targets over the other computer's pictures: files dragged onto them are sent there.</summary>
        void UpdateDropZones()
        {
            foreach (var k in zones.Keys.ToList())
                if (!Media.Players.TryGetValue(k, out var p) || p.RemoteRes == null) { zones[k].Close(); zones.Remove(k); }
            foreach (var pl in Media.Players.Values.Where(p => p.RemoteRes != null))
            {
                if (!zones.TryGetValue(pl.Key, out var z))
                {
                    z = new DeskViewDropZone { Target = S.Role == Role.Server ? (string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName) : "the server" };
                    z.Dropped += SendFiles;
                    zones[pl.Key] = z;
                }
                z.Place(Media.PictureRect(pl));
                z.TopMost = false; z.TopMost = true;   // stay above the video window, which also puts itself on top
            }
        }

        public void SendFiles(string[] files)
        {
            var peer = Peer();
            if (string.IsNullOrEmpty(peer)) { Notice?.Invoke("The other computer is not connected.", true); return; }
            transfers.Add(DeskViewTransfer.Start(Tools.Host(peer).Trim('[', ']'), S.ControlPort, S.PairCode, files));
            Notice?.Invoke($"Sending {files.Length} item(s)...", false);
        }

        void ServiceFiles()
        {
            foreach (var tr in transfers.Where(x => x.Done).ToList())
            {
                Notice?.Invoke(tr.Error != null ? "Sending failed: " + tr.Error : "Sent: " + string.Join(", ", tr.Paths.Select(Path.GetFileName)), tr.Error != null);
                transfers.Remove(tr);
            }
            var got = new List<string>();
            while (agent.Received.TryDequeue(out var p)) got.Add(p);
            if (got.Count == 0) return;
            Notice?.Invoke($"Received {got.Count} file(s) in Downloads\\DeskView: " + string.Join(", ", got.Take(3).Select(Path.GetFileName)), false);
            if ((DateTime.Now - lastReceivedNotice).TotalSeconds > 5) System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + got.Last() + "\"");
            lastReceivedNotice = DateTime.Now;
        }

        // ------------------------------------------------------------------------------------------------- heartbeat
        static string LayoutSignature() => string.Join(";", Tools.OrderedScreens().Select(s => s.DeviceName + "=" + s.Bounds));

        void Tick()
        {
            try
            {
                int hk = forwarder.TakeHotkey();
                if (hk != 0) OnHotkey(hk);

                var cmdFile = Path.Combine(AppSettings.Dir, "command.txt");
                if (File.Exists(cmdFile)) { var c = File.ReadAllText(cmdFile).Trim(); File.Delete(cmdFile); if (c.Length > 0) ShowOn(c); }

                ServiceFiles();
                var req = agent.TakeRequestedMonitor();
                if (req != null) SetAgentScreen(req);
                Media.ServiceSenders();

                // A screen that never shows up (the other computer has no such screen, or doesn't share it) would
                // leave a black window on that monitor: give the monitor back after 6 failed attempts and say why.
                foreach (var pl in Media.Players.Values.Where(p => !p.EverLive && p.Fails >= 6).ToList())
                {
                    Notice?.Invoke($"{(string.IsNullOrEmpty(S.RemoteName) ? "The other computer" : S.RemoteName)} has no screen {pl.RemoteN} (or isn't sharing it yet) - {pl.Key} shows its own desktop again.", true);
                    Media.StopPlayer(pl); Media.Players.Remove(pl.Key);
                    if (S.Role == Role.Server) S.Screens.Remove(pl.Key); else S.ClientView = 0;
                    S.Save(); SyncPlayers();
                }
                if (Media.ServicePlayers(Peer()))
                {
                    UpdateDropZones();
                    if (S.Role == Role.Server) UpdatePortals(); else UpdateForwarderPicture();
                    Changed?.Invoke();
                }

                if ((DateTime.Now - lastSlow).TotalSeconds >= 2)
                {
                    lastSlow = DateTime.Now;
                    var sig = LayoutSignature();
                    if (sig != layoutSig)
                    {
                        layoutSig = sig;
                        var all = Screen.AllScreens;
                        agent.VL = all.Min(s => s.Bounds.Left); agent.VR = all.Max(s => s.Bounds.Right);
                        Media.StopSenders(); Media.StopPlayers(); lastPortal = null; SyncPlayers();
                        Notice?.Invoke("Monitor layout changed - adjusted.", false);
                    }
                    var before = S.Peer; Peer();
                    if (S.Role == Role.Client && S.Peer != before) forwarder.Peer = S.Peer;
                    LearnRemoteName();
                    Changed?.Invoke();
                }
            }
            catch (Exception e) { Log.Write("tick: " + e.Message); }
        }

        /// <summary>Server: a computer we don't know yet tried to connect - it is the other computer: add it.</summary>
        void LearnRemoteName()
        {
            if (S.Role != Role.Server || !string.IsNullOrEmpty(S.RemoteName)) return;
            foreach (var line in CoreControl.TailLog(40).Reverse())
            {
                var m = Regex.Match(line, "unrecognised client name \"([^\"]+)\"");
                if (m.Success)
                {
                    S.RemoteName = m.Groups[1].Value; S.Save();
                    Notice?.Invoke($"{S.RemoteName} is connecting - added it.", false);
                    ApplyEngine(true);
                    return;
                }
            }
        }
    }

    /// <summary>DeskView's own log (%APPDATA%\DeskView\deskview.log).</summary>
    public static class Log
    {
        public static string Path => System.IO.Path.Combine(AppSettings.Dir, "deskview.log");
        public static void Write(string line)
        {
            try
            {
                Directory.CreateDirectory(AppSettings.Dir);
                File.AppendAllText(Path, $"[{DateTime.Now:yyyy-MM-ddTHH:mm:ss}] {line}\r\n");
                var fi = new FileInfo(Path); if (fi.Length > 2_000_000) File.Delete(Path);
            }
            catch { }
        }
    }
}
