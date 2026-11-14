// DeskView's brain: keeps the keyboard/mouse engine, the video streams, the portals and the remote-control channel
// in line with the settings, four times a second, on the UI thread (like a game loop, but cheap).
using System;
using System.Collections.Generic;
using System.Drawing;
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
        readonly DeskViewDiscovery discovery = new DeskViewDiscovery();
        DateTime lastLink = DateTime.Now;
        readonly Timer timer = new Timer { Interval = 250 };
        string layoutSig = "", lastPortal = null;
        readonly Dictionary<string, DeskViewDropZone> zones = new Dictionary<string, DeskViewDropZone>();
        readonly List<DeskViewTransfer> transfers = new List<DeskViewTransfer>();
        DateTime lastReceivedNotice = DateTime.MinValue;
        DateTime lastSlow = DateTime.MinValue;
        public string LastOn = "";

        public event Action Changed;                  // something the UI shows changed
        public event Action<string, bool> Notice;     // message, isWarning

        void OnChanged() { var h = Changed; if (h != null) h(); }
        void OnNotice(string message, bool warning) { var h = Notice; if (h != null) h(message, warning); }

        public Engine(AppSettings settings)
        {
            S = settings;
            Media = new Media(S);
            Media.Notice += (m, w) => OnNotice(m, w);
        }

        // ------------------------------------------------------------------------------------------------- state
        public bool Connected { get { return !string.IsNullOrEmpty(CurrentPeer()); } }
        public bool EngineRunning { get { return Builtin ? forwarder.Connected || agent.Client.Length > 0 : CoreControl.Running; } }
        /// <summary>DeskView's own switching and clipboard instead of the separate engine.</summary>
        public bool Builtin { get { return S.InputEngine == "DeskView"; } }
        /// <summary>The side of this desktop that leads to the other computer.</summary>
        string EdgeName
        {
            get
            {
                var side = S.RemoteSide == Side.None ? Side.Right : S.RemoteSide;
                var name = side.ToString().ToLowerInvariant();
                return S.Role == Role.Server ? name : DeskView.Tools.OppositeSide(name);
            }
        }
        public string AgentClient { get { return agent.Client; } }
        public bool ForwarderConnected { get { return forwarder.Connected; } }
        public string ForwarderStatus { get { return forwarder.Status; } }

        /// <summary>The other computer's address, from the live keyboard/mouse connection.</summary>
        public string CurrentPeer()
        {
            if (Builtin)
            {
                // our own link: the client's forwarder reaches the server's agent (and the other way round)
                if (S.Role == Role.Server) return agent.Client.Length > 0 ? Regex.Replace(agent.Client, "^::ffff:", "") : null;
                return forwarder.Connected ? S.ServerAddress : null;
            }
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
            // Classic engine: only its connected partner may use the control channel. Built-in: the pairing code is the
            // gate (mutual proof + lockout; the firewall allows the local network only) - a remembered address may be old.
            if (Builtin) agent.AllowedIps = new string[0];
            else if (!string.IsNullOrEmpty(S.Peer)) agent.AllowedIps = new[] { S.Peer, "::ffff:" + S.Peer };
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
            try { agent.Start(); } catch { OnNotice(string.Format("Control port {0} is in use - control from the other computer is off.", S.ControlPort), true); }
            forwarder.Port = S.ControlPort; forwarder.Code = S.PairCode; forwarder.Name = S.ComputerName;
            forwarder.CountInjected = Environment.GetEnvironmentVariable("DESKVIEW_QA_INPUT") == "1";   // live QA with synthetic input
            if (S.Role == Role.Client) forwarder.Peer = Peer() ?? "";
            ApplyBuiltin();
            forwarder.Start();
            if (S.Role == Role.Client) S.ClientView = 0;      // start on this computer's own screen
            ApplyPointer();
            ApplyEngine(true);
            layoutSig = LayoutSignature();
            Media.ServiceSenders();
            SyncPlayers();
            timer.Tick += (o, e) => Tick();
            timer.Start();
        }

        /// <summary>Client: Windows hides the pointer when no mouse is plugged in - the pointer moved over the
        /// network then disappears. Mouse Keys makes Windows always draw it.</summary>
        public void ApplyPointer()
        {
            try
            {
                if (S.Role == Role.Client && S.AlwaysShowPointer) { if (DeskViewPointer.ForceVisible()) { S.PointerForcedByUs = true; S.Save(); } }
                else if (S.PointerForcedByUs) { DeskViewPointer.Release(); S.PointerForcedByUs = false; S.Save(); }
            }
            catch { }
        }

        public void Shutdown()
        {
            timer.Stop();
            try { if (S.Role == Role.Server) CoreControl.WriteConfig(S, null); } catch { }   // no portal left behind
            foreach (var z in zones.Values) z.Close();
            foreach (var st in strips.Values) st.Close();
            forwarder.TakeBack();
            discovery.Stop();
            forwarder.Stop(); agent.Stop(); Media.StopPlayers(); Media.StopSenders();
            if (Builtin && S.Role != Role.None && CoreControl.Installed) try { CoreControl.Start(); } catch { }   // the mouse keeps working without DeskView
        }

        /// <summary>Write the engine settings; start or restart the engine when they changed (or when asked).</summary>
        /// <summary>Switching edge, clipboard and peers for DeskView's own engine (or off for the classic one).</summary>
        public void ApplyBuiltin()
        {
            forwarder.Edge = Builtin && S.Role != Role.None ? EdgeName : "";
            if (!Builtin) forwarder.TakeBack();
            forwarder.ShareClipboard = agent.ShareClipboard = Builtin && S.ClipboardEnabled;
            forwarder.MaxClipboardBytes = agent.MaxClipboardBytes = Math.Max(1, S.ClipboardSizeMb) * 1024 * 1024;
            agent.AvoidLeftEdge = agent.AvoidRightEdge = S.Role == Role.Server && !Builtin;
            if (S.Role == Role.Server && Builtin && !string.IsNullOrEmpty(S.Peer)) forwarder.Peer = S.Peer;
            if (S.Role == Role.Client && Builtin) forwarder.Peer = S.ServerAddress ?? "";
            StartDiscovery();
        }

        /// <summary>Built-in engine: the server answers on the local network; a client without a (working) server
        /// address looks for it. Both sealed with the pairing code.</summary>
        void StartDiscovery()
        {
            if (!Builtin || S.Role == Role.None || !AppSettings.IsValidPairCode(S.PairCode)) { discovery.Stop(); return; }
            discovery.Code = S.PairCode; discovery.Name = S.ComputerName;
            if (discovery.Running) return;
            try
            {
                if (S.Role == Role.Server) discovery.StartResponder();
                else if (string.IsNullOrEmpty(S.ServerAddress)) discovery.StartSeeker(DeskViewDiscovery.BroadcastTargets());
            }
            catch (Exception e) { Log.Write("discovery: " + e.Message); }
        }

        /// <summary>Every 2 s: take what discovery found, look again when the server is gone, learn the other name.</summary>
        void ServiceDiscovery()
        {
            if (!Builtin) return;
            if (forwarder.Connected) lastLink = DateTime.Now;
            if (S.Role == Role.Client)
            {
                var found = discovery.Found;
                if (found != null)
                {
                    discovery.Found = null;
                    if (found != S.ServerAddress)
                    {
                        S.ServerAddress = found; S.Save(); forwarder.Peer = found;
                        OnNotice(string.Format("Found {0} at {1}.", string.IsNullOrEmpty(discovery.FoundName) ? "the server" : discovery.FoundName, found), false);
                    }
                }
                else if (!forwarder.Connected && (DateTime.Now - lastLink).TotalSeconds > 15 && !discovery.Running)
                {
                    lastLink = DateTime.Now;   // look again (the server may have a new address)
                    try { discovery.Code = S.PairCode; discovery.StartSeeker(DeskViewDiscovery.BroadcastTargets()); } catch (Exception e) { Log.Write("discovery: " + e.Message); }
                }
            }
            var name = agent.PeerName;
            if (!string.IsNullOrEmpty(name) && name != S.RemoteName) { S.RemoteName = name; S.Save(); OnChanged(); }
        }

        public void ApplyEngine(bool forceStart = false)
        {
            if (S.Role == Role.None) return;
            ApplyBuiltin();
            if (Builtin) { if (CoreControl.Installed && CoreControl.Running) CoreControl.Stop(); return; }   // our own switching: the separate engine stays off
            bool changed = CoreControl.WriteConfig(S, S.Role == Role.Server ? PortalValue() : null);
            if (changed || forceStart || !CoreControl.Running)
            {
                if (S.StartEngineOnLaunch || forceStart || changed)
                    if (!CoreControl.Start()) OnNotice(CoreControl.LastError, true);
            }
        }

        public void RestartEngine() { CoreControl.Stop(); System.Threading.Thread.Sleep(500); if (!CoreControl.Start()) OnNotice(CoreControl.LastError, true); }
        public void StopEngine() { CoreControl.Stop(); }

        // ------------------------------------------------------------------------------------------------- screens
        IEnumerable<Tuple<string, Screen, int>> WantedPlayers()
        {
            if (S.Role == Role.Server)
            {
                foreach (var kv in S.Screens) { var m = Tools.ByName(kv.Key); if (m != null && kv.Value > 0) yield return Tuple.Create(kv.Key, m, kv.Value); }
            }
            else if (S.Role == Role.Client && S.ClientView > 0) yield return Tuple.Create("view", Screen.PrimaryScreen, S.ClientView);
        }

        public void SyncPlayers()
        {
            Media.SyncPlayers(WantedPlayers(), Peer());
            UpdateDropZones();
            UpdateStrips();
            if (S.Role == Role.Server) UpdatePortals();
            else
            {
                if (S.ClientView <= 0) { forwarder.Active = false; return; }
                forwarder.Peer = Peer() ?? "";
                forwarder.SelectMonitor(S.ClientView.ToString());
                UpdateForwarderPicture();
                forwarder.Active = true;
            }
            OnChanged();
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
                S.Save(); SyncPlayers(); OnNotice(S.Role == Role.Server ? "Other computer's screens off" : "Back to this computer", false); return;
            }
            int n;
            if (S.Role == Role.Server)
            {
                var name = ResolveMonitor(want);
                if (name == null) { OnNotice("There is no monitor " + want + ".", true); return; }
                SetScreen(name, 1);
                OnNotice(string.Format("Connecting to {0}'s screen for {1}...", S.RemoteName, name), false);
            }
            else if (int.TryParse(want, out n) && n >= 1 && n <= 9)
            {
                S.ClientView = n; LastOn = want; S.Save(); SyncPlayers();
                OnNotice(string.Format("Viewing the other computer's screen {0} - Ctrl+Alt+0 to come back", n), false);
            }
        }

        public static string ResolveMonitor(string want)
        {
            var list = Tools.OrderedScreens();
            int i;
            if (int.TryParse(want, out i)) return i >= 1 && i <= list.Length ? Tools.Short(list[i - 1]) : null;
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
            // the other computer asks by stream number (main screen first, like the video) or by DISPLAYn
            Screen m = null; int n;
            var shared = Tools.SharedScreens();
            if (int.TryParse(want, out n)) { if (n >= 1 && n <= shared.Length) m = shared[n - 1]; }
            else { var name = ResolveMonitor(want); if (name != null) m = Tools.ByName(name); }
            if (m == null) m = Screen.PrimaryScreen;
            agent.TL = m.Bounds.Left; agent.TT = m.Bounds.Top; agent.TW = m.Bounds.Width; agent.TH = m.Bounds.Height;
        }

        // ------------------------------------------------------------------------------------------------- portals
        /// <summary>"x,y,w,h,SIDES[@client screen]" for every picture, separated by ';' (for the engine).</summary>
        static Rectangle? ParseRect(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            var p = s.Split(','); int x, y, w, h;
            if (p.Length == 4 && int.TryParse(p[0], out x) && int.TryParse(p[1], out y) && int.TryParse(p[2], out w) && int.TryParse(p[3], out h) && w > 0 && h > 0) return new Rectangle(x, y, w, h);
            return null;
        }

        // ------------------------------------------------------------------------------------------------- smart screens
        string lastOccupied = null; DateTime lastOccupiedSent = DateTime.MinValue, lastOccupiedCheck = DateTime.MinValue;
        readonly Dictionary<string, int> autoShown = new Dictionary<string, int>();        // monitor -> screen shown by smart screens
        readonly Dictionary<string, DateTime> emptySince = new Dictionary<string, DateTime>();

        /// <summary>Client: tell the server which extra screens (2, 3, ...) hold windows, when that changes.</summary>
        void ReportOccupied()
        {
            if (S.Role != Role.Client || !forwarder.Connected || (DateTime.Now - lastOccupiedCheck).TotalMilliseconds < 500) return;
            lastOccupiedCheck = DateTime.Now;
            var screens = Tools.SharedScreens();
            var has = DeskViewDisplays.ScreensWithWindows(screens.Select(s => s.Bounds).ToArray());
            var list = string.Join(",", Enumerable.Range(1, screens.Length - 1).Where(i => has[i]).Select(i => (i + 1).ToString()).ToArray());
            if (list != lastOccupied || (DateTime.Now - lastOccupiedSent).TotalSeconds > 5)
            {
                lastOccupied = list; lastOccupiedSent = DateTime.Now;
                forwarder.ReportOccupied(list);
            }
        }

        /// <summary>Server: show the client's extra screen N on monitor N-1 while it holds windows; give it back 3 s after
        /// it empties. Monitors the user set by hand are never touched.</summary>
        void ServiceSmartScreens()
        {
            if (S.Role != Role.Server || !S.SmartScreens) return;
            var occ = agent.OccupiedScreens;
            if (occ == null) return;
            var busy = new HashSet<int>(occ.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => { int n; return int.TryParse(x, out n) ? n : 0; }).Where(n => n >= 2));
            var monitors = Tools.OrderedScreens().Select(Tools.Short).ToList();
            foreach (var k in autoShown.Keys.ToList()) { int cur; if (!S.Screens.TryGetValue(k, out cur) || cur != autoShown[k]) autoShown.Remove(k); }   // the user changed it: theirs now
            foreach (var n in busy)
            {
                if (S.Screens.ContainsValue(n) || n - 2 >= monitors.Count) continue;   // already on a monitor / no monitor for it
                var mon = monitors[n - 2];
                if (S.Screens.ContainsKey(mon)) continue;                              // that monitor shows something the user chose
                SetScreen(mon, n); autoShown[mon] = n; emptySince.Remove(mon);
                var who = string.IsNullOrEmpty(S.RemoteName) ? "The other computer's" : S.RemoteName + "'s";
                OnNotice(string.Format("{0} screen {1} is now on monitor {2} (a window went there)", who, n, n - 1), false);
            }
            foreach (var kv in autoShown.ToList())
            {
                if (busy.Contains(kv.Value)) { emptySince.Remove(kv.Key); continue; }
                DateTime t;
                if (!emptySince.TryGetValue(kv.Key, out t)) { emptySince[kv.Key] = DateTime.Now; continue; }
                if ((DateTime.Now - t).TotalSeconds < 3) continue;
                emptySince.Remove(kv.Key); autoShown.Remove(kv.Key);
                SetScreen(kv.Key, 0);   // empty for 3 s: the monitor is this computer's again
            }
        }

        // ------------------------------------------------------------------------------------------------- the guide
        readonly Dictionary<string, UI.MonitorStrip> strips = new Dictionary<string, UI.MonitorStrip>();
        UI.Toast toast;
        long engineLogPos = -1;
        bool onOther; DateTime lastToast = DateTime.MinValue;

        /// <summary>A strip on every monitor that shows the other computer: which screen, and ways back.</summary>
        void UpdateStrips()
        {
            var want = S.ShowGuide && S.Role == Role.Server ? Media.Players.Values.ToList() : new List<Player>();
            foreach (var k in strips.Keys.ToList()) if (!want.Any(p => p.Key == k)) { strips[k].Close(); strips.Remove(k); }
            var name = string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName;
            foreach (var pl in want)
            {
                UI.MonitorStrip st;
                if (!strips.TryGetValue(pl.Key, out st)) strips[pl.Key] = st = new UI.MonitorStrip(this, pl.Key);
                var caption = pl.Live
                    ? string.Format("{0}  ·  screen {1}{2}     move the mouse below this bar to work on {0}", name, pl.RemoteN, pl.RemoteN == 1 ? " (its own display)" : "")
                    : string.Format("{0}  ·  screen {1}  -  connecting...", name, pl.RemoteN);
                st.Show(pl.Screen.Bounds, caption);
            }
        }

        /// <summary>A short message whenever keyboard and mouse move to the other computer or come back.</summary>
        void ServiceToast()
        {
            if (!S.ShowGuide || S.Role == Role.None) return;
            bool now = onOther;
            if (Builtin) now = forwarder.RemoteOwned;
            else
            {
                try
                {
                    var f = CoreControl.ServiceLog;
                    if (!File.Exists(f)) return;
                    using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        if (engineLogPos < 0 || engineLogPos > fs.Length) engineLogPos = fs.Length;   // start from now
                        if (fs.Length == engineLogPos) return;
                        fs.Seek(engineLogPos, SeekOrigin.Begin);
                        var text = new StreamReader(fs).ReadToEnd(); engineLogPos = fs.Length;
                        foreach (Match m in Regex.Matches(text, "switch from \"([^\"]+)\" to \"([^\"]+)\""))
                            now = m.Groups[2].Value != S.ComputerName;
                    }
                }
                catch { return; }
            }
            if (now == onOther) return;
            onOther = now;
            if ((DateTime.Now - lastToast).TotalSeconds < 4) return;   // crossing back and forth quickly: don't nag
            lastToast = DateTime.Now;
            if (toast == null) toast = new UI.Toast();
            var name = string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName;
            var mon = Screen.FromPoint(Cursor.Position).Bounds;
            toast.Say(mon, now ? string.Format("Keyboard and mouse are on {0}  -  move back, or press Ctrl+Alt+0", name)
                               : string.Format("Back on {0}", S.ComputerName), now ? 2.5 : 1.5);
        }

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
                // where on the other computer this picture is (an older sender: its screen 1, the main screen, at 0,0)
                Rectangle? src = ParseRect(pls[i].RemoteRect);
                if (src == null && pls[i].RemoteRes.HasValue && pls[i].RemoteN == 1) src = new Rectangle(0, 0, pls[i].RemoteRes.Value.Width, pls[i].RemoteRes.Value.Height);
                // the guide strip along the top of the monitor stays this computer's: the hand-over zone starts below it
                int cut = S.ShowGuide ? Math.Max(0, pls[i].Screen.Bounds.Top + UI.MonitorStrip.StripHeight - r.Y) : 0;
                if (cut > 0 && cut < r.Height)
                {
                    if (src.HasValue) { var s = src.Value; int sc = (int)Math.Round(cut * (double)s.Height / r.Height); src = new Rectangle(s.X, s.Y + sc, s.Width, s.Height - sc); }
                    r = new Rectangle(r.X, r.Y + cut, r.Width, r.Height - cut);
                }
                var e = string.Format("{0},{1},{2},{3},{4}", r.X, r.Y, r.Width, r.Height, ExitSides(r, rects.Where((x, j) => j != i).ToList()));
                if (src.HasValue) e += string.Format("@{0},{1},{2},{3}", src.Value.X, src.Value.Y, src.Value.Width, src.Value.Height);
                entries.Add(e);
            }
            return string.Join(";", entries);
        }

        /// <summary>Sides the cursor may leave a picture by: only where everything just outside is on a monitor and
        /// not inside another picture (no landing in gaps, no bouncing straight back into the other computer).</summary>
        static string ExitSides(System.Drawing.Rectangle r, List<System.Drawing.Rectangle> others)
        {
            var mons = Screen.AllScreens.Select(s => s.Bounds).ToList();
            Func<int, int, bool> Ok = (x, y) => !others.Any(o => o.Contains(x, y)) && mons.Any(m => m.Contains(x, y));
            Func<IEnumerable<Tuple<int, int>>, bool> Covered = pts => pts.All(p => Ok(p.Item1, p.Item2));
            var ys = Enumerable.Range(0, 21).Select(k => r.Top + (r.Height - 1) * k / 20).ToList();
            var xs = Enumerable.Range(0, 21).Select(k => r.Left + (r.Width - 1) * k / 20).ToList();
            string sides = "";
            if (Covered(ys.Select(y => Tuple.Create(r.Left - 1, y)))) sides += "L";
            if (Covered(ys.Select(y => Tuple.Create(r.Right, y)))) sides += "R";
            if (Covered(xs.Select(x => Tuple.Create(x, r.Top - 1)))) sides += "T";
            if (Covered(xs.Select(x => Tuple.Create(x, r.Bottom)))) sides += "B";
            return sides.Length == 0 ? "LRTB" : sides;
        }

        void UpdatePortals()
        {
            if (Builtin)
            {
                var pl = Media.Players.Values.FirstOrDefault(p => p.Live);
                if (pl == null) { forwarder.Active = false; return; }
                var r = Media.PictureRect(pl);
                forwarder.VidL = r.X; forwarder.VidT = r.Y; forwarder.VidW = r.Width; forwarder.VidH = r.Height;
                if (forwarder.Monitor != pl.RemoteN.ToString()) forwarder.SelectMonitor(pl.RemoteN.ToString());
                forwarder.Active = true;
                return;
            }
            var value = PortalValue();
            if (value == lastPortal) return;
            lastPortal = value;
            // Only the portal changed: the engine re-reads it by itself within a second, no restart needed.
            CoreControl.UpdatePortal(S, value);
        }

        void UpdateForwarderPicture()
        {
            Player pl;
            if (!Media.Players.TryGetValue("view", out pl)) return;
            var r = Media.PictureRect(pl);
            forwarder.VidL = r.X; forwarder.VidT = r.Y; forwarder.VidW = r.Width; forwarder.VidH = r.Height;
        }

        // ------------------------------------------------------------------------------------------------- files
        /// <summary>Invisible drop targets over the other computer's pictures: files dragged onto them are sent there.</summary>
        void UpdateDropZones()
        {
            foreach (var k in zones.Keys.ToList())
            {
                Player p;
                if (!Media.Players.TryGetValue(k, out p) || p.RemoteRes == null) { zones[k].Close(); zones.Remove(k); }
            }
            foreach (var pl in Media.Players.Values.Where(p => p.RemoteRes != null))
            {
                DeskViewDropZone z;
                if (!zones.TryGetValue(pl.Key, out z))
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
            if (string.IsNullOrEmpty(peer)) { OnNotice("The other computer is not connected.", true); return; }
            transfers.Add(DeskViewTransfer.Start(Tools.Host(peer).Trim('[', ']'), S.ControlPort, S.PairCode, files));
            OnNotice(string.Format("Sending {0} item(s)...", files.Length), false);
        }

        void ServiceFiles()
        {
            foreach (var tr in transfers.Where(x => x.Done).ToList())
            {
                OnNotice(tr.Error != null ? "Sending failed: " + tr.Error : "Sent: " + string.Join(", ", tr.Paths.Select(Path.GetFileName)), tr.Error != null);
                transfers.Remove(tr);
            }
            var got = new List<string>();
            string p;
            while (agent.Received.TryDequeue(out p)) got.Add(p);
            if (got.Count == 0) return;
            OnNotice(string.Format("Received {0} file(s) in Downloads\\DeskView: ", got.Count) + string.Join(", ", got.Take(3).Select(Path.GetFileName)), false);
            if ((DateTime.Now - lastReceivedNotice).TotalSeconds > 5) System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + got.Last() + "\"");
            lastReceivedNotice = DateTime.Now;
        }

        // ------------------------------------------------------------------------------------------------- heartbeat
        static string LayoutSignature() { return string.Join(";", Tools.OrderedScreens().Select(s => s.DeviceName + "=" + s.Bounds)); }

        void Tick()
        {
            try
            {
                int hk = forwarder.TakeHotkey();
                if (hk != 0) OnHotkey(hk);

                var cmdFile = Path.Combine(AppSettings.Dir, "command.txt");
                if (File.Exists(cmdFile)) { var c = File.ReadAllText(cmdFile).Trim(); File.Delete(cmdFile); if (c.Length > 0) ShowOn(c); }

                ServiceFiles();
                ServiceToast();
                ReportOccupied();
                ServiceSmartScreens();
                var req = agent.TakeRequestedMonitor();
                if (req != null) SetAgentScreen(req);
                Media.ServiceSenders();

                // A screen that never shows up (the other computer has no such screen, or doesn't share it) would
                // leave a black window on that monitor: give the monitor back after 6 failed attempts and say why.
                foreach (var pl in Media.Players.Values.Where(p => !p.EverLive && p.Fails >= 6).ToList())
                {
                    OnNotice(string.Format("{0} has no screen {1} (or isn't sharing it yet) - {2} shows its own desktop again.", string.IsNullOrEmpty(S.RemoteName) ? "The other computer" : S.RemoteName, pl.RemoteN, pl.Key), true);
                    Media.StopPlayer(pl); Media.Players.Remove(pl.Key);
                    if (S.Role == Role.Server) S.Screens.Remove(pl.Key); else S.ClientView = 0;
                    S.Save(); SyncPlayers();
                }
                if (Media.ServicePlayers(Peer()))
                {
                    UpdateDropZones();
                    UpdateStrips();
                    if (S.Role == Role.Server) UpdatePortals(); else UpdateForwarderPicture();
                    OnChanged();
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
                        OnNotice("Monitor layout changed - adjusted.", false);
                    }
                    ServiceDiscovery();
                    if (strips.Count > 0) UpdateStrips();   // stay above the pictures
                    var before = S.Peer; Peer();
                    if (S.Role == Role.Client && S.Peer != before) forwarder.Peer = S.Peer;
                    if (Builtin && S.Role == Role.Server && !string.IsNullOrEmpty(S.Peer) && forwarder.Peer != S.Peer) forwarder.Peer = S.Peer;
                    LearnRemoteName();
                    OnChanged();
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
                    OnNotice(string.Format("{0} is connecting - added it.", S.RemoteName), false);
                    ApplyEngine(true);
                    return;
                }
            }
        }
    }

    /// <summary>DeskView's own log (%APPDATA%\DeskView\deskview.log).</summary>
    public static class Log
    {
        public static string Path { get { return System.IO.Path.Combine(AppSettings.Dir, "deskview.log"); } }
        public static void Write(string line)
        {
            try
            {
                Directory.CreateDirectory(AppSettings.Dir);
                File.AppendAllText(Path, string.Format("[{0:yyyy-MM-ddTHH:mm:ss}] {1}\r\n", DateTime.Now, line));
                var fi = new FileInfo(Path); if (fi.Length > 2000000) File.Delete(Path);
            }
            catch { }
        }
    }
}
