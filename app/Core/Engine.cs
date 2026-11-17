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
            // a picture of the other computer's screen stopped: it restarts that screen's listener at once (whichever way
            // the link runs: the server answers through its agent, the client through its forwarder)
            Media.ViewerGone += n => { if (S.Role == Role.Server) agent.RequestSenderRestart(n); else forwarder.RequestSenderRestart(n); };
            Media.RemoteScreen = n => DvProto.ScreenFromList(S.Role == Role.Server ? agent.RemoteScreenList : forwarder.RemoteScreenList, n);
            // smart screens' memory survives restarts (else a restart would grab monitors the user gave back)
            foreach (var n in S.SmartReleased) userReleased.Add(n);
            foreach (var kv in S.SmartShown) { int cur; if (S.Screens.TryGetValue(kv.Key, out cur) && cur == kv.Value) autoShown[kv.Key] = kv.Value; }
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
        /// <summary>How many screens the other computer shares (it tells us; 4 until it has).</summary>
        public int RemoteScreenCount { get { return agent.ScreenCount > 0 ? agent.ScreenCount : 4; } }
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
            // The two halves of this computer: the person sitting here always wins over the other computer, and this
            // computer never drives the other one while it is being driven (no crossed control). Both log what they do.
            forwarder.DrivenByOther = () => agent.DrivenNow;
            forwarder.DrivenRecently = () => agent.DrivenRecently;
            forwarder.ClaimLocal = agent.GiveBack;
            forwarder.Log = agent.Log = Log.Later;   // never waits on a file: called from the input threads
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
            Log.Write(n > 0 ? string.Format("{0}: set to the other computer's screen {1}", monitor, n) : monitor + ": given back");
            // the user gave a monitor back: smart screens must not take it again until that screen empties first
            int was;
            if (n <= 0 && S.Screens.TryGetValue(monitor, out was)) userReleased.Add(was);
            if (n > 0) userReleased.Remove(n);
            autoShown.Remove(monitor);
            ApplyScreen(monitor, n);
        }

        void ApplyScreen(string monitor, int n)
        {
            if (n > 0) foreach (var k in S.Screens.Where(kv => kv.Value == n).Select(kv => kv.Key).ToList()) S.Screens.Remove(k);   // one stream, one monitor
            if (n <= 0) S.Screens.Remove(monitor); else { S.Screens[monitor] = n; LastOn = monitor; }
            KeepSmartMemory(); S.Save(); SyncPlayers();
        }

        /// <summary>Copies smart screens' memory into the settings (saved with them).</summary>
        void KeepSmartMemory()
        {
            S.SmartReleased = userReleased.OrderBy(x => x).ToList();
            S.SmartShown = new Dictionary<string, int>(autoShown);
        }

        /// <summary>Hotkey / command: server - put the other computer's screen 1 on monitor "want"; client - view server screen.</summary>
        public void ShowOn(string want)
        {
            var m = Regex.Match(want ?? "", @"^(\w+)=(\d)$");
            if (S.Role == Role.Server && m.Success) { var name = ResolveMonitor(m.Groups[1].Value); if (name != null) SetScreen(name, int.Parse(m.Groups[2].Value)); return; }
            if (string.IsNullOrEmpty(want) || want.Equals("off", StringComparison.OrdinalIgnoreCase))
            {
                if (S.Role == Role.Server) { foreach (var v in S.Screens.Values) userReleased.Add(v); S.Screens.Clear(); autoShown.Clear(); } else S.ClientView = 0;
                Log.Write("all monitors given back"); KeepSmartMemory(); S.Save(); SyncPlayers();
                // all back means ALL back: the windows on the laptop's extra screens come home to its own screen
                if (S.Role == Role.Server) { if (Builtin) forwarder.AskGatherHome(); } else GatherHome();
                SayEverywhere(S.Role == Role.Server ? "All back - the other computer's windows return to its own screen" : "All back - windows return to this screen", 2); OnNotice(S.Role == Role.Server ? "Other computer's screens off" : "Back to this computer", false); return;
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

        /// <summary>Laptop: every window on the extra (virtual) screens moves to its own screen. On a worker thread:
        /// moving another program's window waits for that program, and a hung one must not stop DeskView.</summary>
        void GatherHome() { GatherHome(-1); }

        /// <summary>Strip button "Give this monitor back": that monitor stops showing the other computer, and the
        /// windows that were on that screen go home to the other computer's own screen (no hunting for them).</summary>
        public void GiveBack(string monitor)
        {
            int n; bool had = S.Screens.TryGetValue(monitor, out n);
            Log.Write("guide: \"Give this monitor back\" clicked on " + monitor + (had ? " (it showed screen " + n + ")" : " (it showed nothing)"));
            SetScreen(monitor, 0);
            if (had && S.Role == Role.Server && Builtin) forwarder.AskGatherHome(n);
            SayEverywhere(had ? "Screen " + n + " given back - its windows return to " + (string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName) : "Given back", 2);
        }

        /// <summary>Strip button "All back" (same as Ctrl+Alt+0).</summary>
        public void AllBack() { Log.Write("guide: \"All back\" clicked"); ShowOn("off"); }

        void GatherHome(int screen)
        {
            if (S.Role != Role.Client) return;
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    var virt = new HashSet<string>(DeskViewDisplays.VirtualScreens(), StringComparer.OrdinalIgnoreCase);
                    var shared = Tools.SharedScreens();
                    // one screen (n = its number in the shared order) or all of them; only virtual screens, never a real monitor
                    var from = (screen > 0 ? shared.Skip(screen - 1).Take(1) : shared.AsEnumerable()).Where(x => virt.Contains(x.DeviceName)).Select(x => x.Bounds).ToArray();
                    if (from.Length == 0) return;
                    int n = DeskViewDisplays.BringWindowsHome(from, Screen.PrimaryScreen.WorkingArea);
                    Log.Write((screen > 0 ? "screen " + screen + " given back: " : "all back: ") + n + " window(s) moved from the extra screen(s) to this computer's own screen");
                }
                catch (Exception e) { Log.Write("all back: moving windows failed: " + e.Message); }
            });
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
            if (vk == 0x47)
            {
                // Ctrl+Alt+G: give back the monitor the mouse is on (and its windows go home)
                if (S.Role == Role.Server) GiveBack(Tools.Short(Screen.FromPoint(Cursor.Position)));
                else ShowOn("off");
                return;
            }
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
        readonly HashSet<int> userReleased = new HashSet<int>();                               // screens the user gave back while they held windows
        readonly Dictionary<int, DateTime> smartFailed = new Dictionary<int, DateTime>();      // screens smart screens showed whose picture never came
        readonly Dictionary<int, DateTime> releasedEmptySince = new Dictionary<int, DateTime>();   // given-back screens: since when reported empty
        string lastBusyLogged = null;

        /// <summary>Client: tell the server which extra screens (2, 3, ...) hold windows, when that changes.</summary>
        bool dragging;
        void ReportOccupied()
        {
            // every 0.5 s, every 0.2 s while something is being dragged (the picture should start while the drag is on)
            if (S.Role != Role.Client || !forwarder.Connected || (DateTime.Now - lastOccupiedCheck).TotalMilliseconds < (dragging ? 200 : 500)) return;
            lastOccupiedCheck = DateTime.Now;
            var screens = Tools.SharedScreens();
            var rects = screens.Select(s => s.Bounds).ToArray();
            var has = DeskViewDisplays.ScreensWithWindows(rects);
            int drag = DeskViewDisplays.DragScreen(rects);
            dragging = drag >= 0;
            if (drag >= 1) has[drag] = true;   // being dragged onto/over an extra screen: it holds a window (never given back mid-drag)
            var list = string.Join(",", Enumerable.Range(1, screens.Length - 1).Where(i => has[i]).Select(i => (i + 1).ToString()).ToArray());
            if (list != lastOccupied || (DateTime.Now - lastOccupiedSent).TotalSeconds > 5)
            {
                lastOccupied = list; lastOccupiedSent = DateTime.Now;
                forwarder.ReportScreenCount(screens.Length);
                forwarder.ReportScreens(ScreenList(screens));
                forwarder.ReportOccupied(list);
            }
        }

        /// <summary>"n:x,y,w,h;..." for the screens this computer shares (in the order they are offered).</summary>
        static string ScreenList(Screen[] screens)
        {
            return string.Join(";", screens.Select((s, i) => string.Format("{0}:{1},{2},{3},{4}", i + 1, s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height)).Take(10).ToArray());
        }
        string lastScreensSent; DateTime lastScreensAt = DateTime.MinValue;

        /// <summary>Server: tell the client where this computer's screens are (it shows them, with Ctrl+Alt+1..9).</summary>
        string lastShownSent; DateTime lastShownAt = DateTime.MinValue;
        void ReportShownToClient()
        {
            if (S.Role != Role.Server || string.IsNullOrEmpty(agent.Client)) { lastShownSent = null; return; }
            var shown = string.Join(",", S.Screens.Values.Where(v => v > 0).Distinct().OrderBy(v => v).Select(v => v.ToString()).ToArray());
            if (shown == lastShownSent && (DateTime.Now - lastShownAt).TotalSeconds < 5) return;
            lastShownSent = shown; lastShownAt = DateTime.Now;
            agent.ReportShown(shown);
        }

        // Laptop: a window the person brings up (taskbar, Alt+Tab, a notification) that sits on an extra screen no
        // monitor shows is moved onto this computer's own screen - seen live: Teams opened on a hidden extra screen
        // and could not be reached. Not during a drag (also when the other computer drives this one), and only after
        // it stayed there 1.5 s (a window just dragged there is shown by smart screens within that time).
        IntPtr strandedWin = IntPtr.Zero; DateTime strandedSince;
        void RescueStranded()
        {
            if (S.Role != Role.Client || !forwarder.Connected) { strandedWin = IntPtr.Zero; return; }
            var shownList = forwarder.ShownScreens;
            if (shownList == null) return;                                       // an older server: it doesn't say what it shows
            var screens = Tools.SharedScreens();
            var rects = screens.Select(x => x.Bounds).ToArray();
            IntPtr w; int i = DeskViewDisplays.ForegroundScreen(rects, out w);
            var virt = new HashSet<string>(DeskViewDisplays.VirtualScreens(), StringComparer.OrdinalIgnoreCase);
            bool stranded = i >= 1 && virt.Contains(screens[i].DeviceName) && !shownList.Split(',').Contains((i + 1).ToString())
                && DeskViewDisplays.DragScreen(rects) < 0;   // also while the other computer drives this one: that is how it is used
            if (!stranded) { strandedWin = IntPtr.Zero; return; }
            if (w != strandedWin) { strandedWin = w; strandedSince = DateTime.Now; return; }
            if ((DateTime.Now - strandedSince).TotalSeconds < 1.5) return;
            strandedWin = IntPtr.Zero;
            var home = Screen.PrimaryScreen.WorkingArea;
            if (DeskViewDisplays.BringWindowHome(w, home))
            {
                Log.Write("window brought here: it was on extra screen " + (i + 1) + ", which no monitor of the other computer shows");
                SayOn(Screen.PrimaryScreen.Bounds, "That window was on extra screen " + (i + 1) + " (not shown anywhere) - moved here", 2.5);
            }
        }

        void ReportScreensToClient()
        {
            ReportShownToClient();
            if (S.Role != Role.Server || string.IsNullOrEmpty(agent.Client)) { lastScreensSent = null; return; }
            var list = ScreenList(Tools.SharedScreens());
            if (list == lastScreensSent && (DateTime.Now - lastScreensAt).TotalSeconds < 10) return;
            lastScreensSent = list; lastScreensAt = DateTime.Now;
            agent.ReportScreens(list);
        }

        /// <summary>Server: show the client's extra screen N on monitor N-1 while it holds windows; give it back 3 s after
        /// it empties. Monitors the user set by hand are never touched.</summary>
        void ServiceSmartScreens()
        {
            if (S.Role != Role.Server || !S.SmartScreens) return;
            var occ = agent.OccupiedScreens;
            if (occ == null) return;
            int releasedBefore = userReleased.Count;
            var busy = new HashSet<int>(occ.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => { int n; return int.TryParse(x, out n) ? n : 0; }).Where(n => n >= 2));
            if (occ != lastBusyLogged) { lastBusyLogged = occ; Log.Write("other computer's screens with windows: " + (occ.Length > 0 ? occ : "none")); }
            // A screen the user gave back is smart again once it has really emptied: reported empty by the connected
            // laptop for 5 s. A dropped link (laptop restarting, asleep) or a brief gap is not that.
            bool linked = !string.IsNullOrEmpty(agent.Client);
            foreach (var n in userReleased.ToList())
            {
                DateTime since;
                if (!linked || busy.Contains(n)) { releasedEmptySince.Remove(n); continue; }
                if (!releasedEmptySince.TryGetValue(n, out since)) { releasedEmptySince[n] = DateTime.Now; continue; }
                if ((DateTime.Now - since).TotalSeconds >= 5) { userReleased.Remove(n); releasedEmptySince.Remove(n); }
            }
            foreach (var n in smartFailed.Keys.Where(k => !busy.Contains(k)).ToList()) smartFailed.Remove(n);
            var monitors = Tools.OrderedScreens().Select(Tools.Short).ToList();
            foreach (var k in autoShown.Keys.ToList()) { int cur; if (!S.Screens.TryGetValue(k, out cur) || cur != autoShown[k]) autoShown.Remove(k); }   // the user changed it: theirs now
            foreach (var n in busy)
            {
                if (S.Screens.ContainsValue(n) || n - 2 >= monitors.Count || userReleased.Contains(n)) continue;   // shown / no monitor / the user gave it back
                DateTime failedAt;
                if (smartFailed.TryGetValue(n, out failedAt) && (DateTime.Now - failedAt).TotalMinutes < 5) continue;   // its picture never came: not again for a while
                var mon = monitors[n - 2];
                if (S.Screens.ContainsKey(mon)) continue;                              // that monitor shows something the user chose
                autoShown[mon] = n; emptySince.Remove(mon); ApplyScreen(mon, n);
                // at once, before the picture is there: the person sees the move was understood
                var sm = Tools.ByName(mon);
                if (sm != null) SayOn(sm.Bounds, string.Format("Showing {0}'s screen {1}  -  Ctrl+Alt+G gives it back", string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName, n), 1.5);
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
                ApplyScreen(kv.Key, 0);   // empty for 3 s: the monitor is this computer's again
            }
            if (userReleased.Count != releasedBefore) { KeepSmartMemory(); S.Save(); }
        }

        // ------------------------------------------------------------------------------------------------- the guide
        readonly Dictionary<string, UI.MonitorStrip> strips = new Dictionary<string, UI.MonitorStrip>();
        readonly List<UI.Toast> toasts = new List<UI.Toast>();

        /// <summary>A short message on one monitor only (the others keep what they show).</summary>
        void SayOn(Rectangle monitor, string message, double seconds)
        {
            var mons = Screen.AllScreens;
            while (toasts.Count < mons.Length) toasts.Add(new UI.Toast());
            for (int i = 0; i < mons.Length; i++) if (mons[i].Bounds == monitor) { toasts[i].Say(monitor, message, seconds); return; }
        }

        /// <summary>The same short message on EVERY monitor at once (wherever the person is looking), clicks go through.</summary>
        void SayEverywhere(string message, double seconds)
        {
            var mons = Screen.AllScreens;
            while (toasts.Count < mons.Length) toasts.Add(new UI.Toast());
            for (int i = 0; i < toasts.Count; i++)
            {
                if (i < mons.Length) toasts[i].Say(mons[i].Bounds, message, seconds);
                else if (toasts[i].Visible) toasts[i].Hide();   // a monitor went away
            }
        }
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
            var name = string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName;
            SayEverywhere(now ? string.Format("Keyboard and mouse are on {0}  -  move back, or press Ctrl+Alt+0", name)
                               : string.Format("Back on {0}", S.ComputerName), now ? 2.5 : 1.5);
        }

        string PortalValue()
        {
            if (!S.Interactive || !CoreControl.PortalCapable) return null;
            // only pictures that are really there: a monitor still connecting (or reconnecting) shows this computer's
            // own desktop and must not hand the pointer over
            var pls = Media.Players.Values.Where(p => p.Live).OrderBy(p => p.Screen.Bounds.X).ToList();
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
                // every picture on every monitor takes input, each for its own screen of the other computer; the guide
                // strip along the top stays clickable here
                var pics = Media.Players.Values.Where(p => p.Live).Select(p =>
                {
                    var r = Media.PictureRect(p);
                    int top = S.ShowGuide ? Math.Max(r.Y, p.Screen.Bounds.Top + UI.MonitorStrip.StripHeight) : r.Y;
                    return new DeskViewForwarder.Picture { Full = r, Hit = Rectangle.FromLTRB(r.Left, Math.Min(top, r.Bottom), r.Right, r.Bottom), Screen = p.RemoteN };
                }).ToArray();
                if (pics.Length == 0) { forwarder.Active = false; forwarder.Pictures = null; return; }
                forwarder.KeysNeedClick = true;   // this computer's own monitors stay in use: the keyboard follows clicks
                forwarder.Pictures = pics;
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
                if (!Media.Players.TryGetValue(k, out p) || !p.Live) { zones[k].Close(); zones.Remove(k); }
            }
            foreach (var pl in Media.Players.Values.Where(p => p.Live))
            {
                DeskViewDropZone z;
                if (!zones.TryGetValue(pl.Key, out z))
                {
                    z = new DeskViewDropZone { Target = S.Role == Role.Server ? (string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName) : "the server" };
                    z.Dropped += SendFiles;
                    zones[pl.Key] = z;
                }
                var zr = Media.PictureRect(pl);
                if (S.ShowGuide)
                {
                    // never over the guide strip: an (invisible) drop zone above it ate the clicks on its buttons
                    int cut = Math.Max(0, pl.Screen.Bounds.Top + UI.MonitorStrip.StripHeight - zr.Y);
                    zr = new Rectangle(zr.X, zr.Y + cut, zr.Width, Math.Max(1, zr.Height - cut));
                }
                z.Place(zr);
                DeskViewPortal.MakePassive(z.Handle);   // above the picture, without taking focus
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
                RescueStranded();
                ReportScreensToClient();
                ServiceSmartScreens();
                int restart;
                while (agent.SenderRestarts.TryDequeue(out restart)) { Log.Write("screen " + restart + ": its viewer went away - fresh listener"); Media.RestartSender(restart); }
                while (forwarder.SenderRestarts.TryDequeue(out restart)) { Log.Write("screen " + restart + ": its viewer went away - fresh listener"); Media.RestartSender(restart); }
                int home; while ((home = agent.TakeGatherHome()) != 0) GatherHome(home);
                var req = agent.TakeRequestedMonitor();
                if (req != null) SetAgentScreen(req);
                Media.ServiceSenders();

                // A screen that never shows up (the other computer has no such screen, or doesn't share it) would
                // leave a black window on that monitor: give the monitor back after 6 failed attempts and say why.
                foreach (var pl in Media.Players.Values.Where(p => !p.EverLive && p.Fails >= 6).ToList())
                {
                    OnNotice(string.Format("{0} has no screen {1} (or isn't sharing it yet) - {2} shows its own desktop again.", string.IsNullOrEmpty(S.RemoteName) ? "The other computer" : S.RemoteName, pl.RemoteN, pl.Key), true);
                    if (autoShown.ContainsKey(pl.Key)) { smartFailed[pl.RemoteN] = DateTime.Now; autoShown.Remove(pl.Key); }   // don't take it again and again
                    Media.StopPlayer(pl); Media.Players.Remove(pl.Key);
                    if (S.Role == Role.Server) S.Screens.Remove(pl.Key); else S.ClientView = 0;
                    S.Save(); SyncPlayers();
                }
                // the other computer's extra screens (2..n) kept ready on the server, so a smart screen shows at once
                int rc = agent.ScreenCount;
                Media.WarmScreens = S.Role == Role.Server && S.KeepPicturesReady && rc > 1 ? Enumerable.Range(2, rc - 1).ToArray() : new int[0];
                Media.ServiceWarm(Peer());
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
                    // steady Wi-Fi while the computers are linked (no scans, no power saving), normal again when not
                    var wifi = forwarder.Connected || !string.IsNullOrEmpty(agent.Client) ? Wifi.Steady() : Wifi.Normal();
                    if (wifi != null) Log.Write(wifi);
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
                    // Keep the layers in order - picture, then the drop zone over it, then the guide strip - also after
                    // something else (the taskbar, once clicked) went on top; and re-check the hand-over areas.
                    foreach (var pl in Media.Players.Values) if (pl.Host != null) pl.Host.Raise();
                    UpdateDropZones();
                    if (strips.Count > 0) UpdateStrips();
                    foreach (var t in toasts) if (t.Visible) DeskViewPortal.MakePassive(t.Handle);
                    if (S.Role == Role.Server) UpdatePortals(); else UpdateForwarderPicture();
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
        static readonly object writeLock = new object();
        /// <summary>One line, with milliseconds (lags and switches are judged in ms). Safe from any thread. At 2 MB the
        /// log moves to deskview.log.1 (the one before is dropped) instead of being deleted: the history that explains
        /// a problem stays.</summary>
        public static void Write(string line) { WriteAt(DateTime.Now, line); }

        /// <summary>For threads that must never wait (input): the time is taken now, the file is written on a worker.</summary>
        public static void Later(string line) { var t = DateTime.Now; System.Threading.ThreadPool.QueueUserWorkItem(delegate { WriteAt(t, line); }); }

        static void WriteAt(DateTime when, string line)
        {
            lock (writeLock)
            {
                try
                {
                    Directory.CreateDirectory(AppSettings.Dir);
                    File.AppendAllText(Path, string.Format("[{0:yyyy-MM-ddTHH:mm:ss.fff}] {1}\r\n", when, line));
                    var fi = new FileInfo(Path);
                    if (fi.Length > 2000000) { var old = Path + ".1"; if (File.Exists(old)) File.Delete(old); File.Move(Path, old); }
                }
                catch { }
            }
        }
    }
}
