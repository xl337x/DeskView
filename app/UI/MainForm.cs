// The DeskView window: a sidebar with pages. Every page explains itself; settings pages end with "Save and apply".
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows.Forms;

namespace DeskView.UI
{
    public class MainForm : Form
    {
        readonly Engine engine;
        AppSettings S { get { return engine.S; } }
        readonly Panel content = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Page };
        readonly FlowLayoutPanel nav = new FlowLayoutPanel { Dock = DockStyle.Left, Width = 210, BackColor = Theme.Sidebar, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(0, 16, 0, 0) };
        readonly Dictionary<string, Func<Control>> pages = new Dictionary<string, Func<Control>>();
        readonly Dictionary<string, Label> navItems = new Dictionary<string, Label>();
        string current;
        readonly Timer refresh = new Timer { Interval = 1000 };
        Action onRefresh;

        public MainForm(Engine e)
        {
            engine = e;
            Text = "DeskView"; Icon = AppIcon.Get(); StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1000, 720); MinimumSize = new Size(860, 560); Font = Theme.Body; BackColor = Theme.Page;
            AutoScaleMode = AutoScaleMode.Dpi;

            var brand = new Label { UseMnemonic = false, Text = "  DeskView", Font = new Font("Segoe UI Semibold", 15f), ForeColor = Color.White, AutoSize = false, Size = new Size(210, 44), TextAlign = ContentAlignment.MiddleLeft };
            nav.Controls.Add(brand);
            var sub = new Label { UseMnemonic = false, Text = "    one desk, every screen", Font = Theme.Small, ForeColor = Theme.SidebarText, AutoSize = false, Size = new Size(210, 26) };
            nav.Controls.Add(sub);

            Add("Overview", OverviewPage);
            Add("What you can do", GuidePage);
            Add("Screens", ScreensPage);
            Add("Connection", ConnectionPage);
            Add("Switching & input", InputPage);
            Add("Security", SecurityPage);
            Add("Logs", LogsPage);
            Add("About", AboutPage);

            Controls.Add(content);
            Controls.Add(nav);
            refresh.Tick += (o, ev) => { var h = onRefresh; if (h != null) h(); };
            refresh.Start();
            engine.Changed += () => { if (current == "Overview" || current == "Screens") BeginInvokeSafe(() => { var h = onRefresh; if (h != null) h(); }); };
            ShowPage("Overview");
        }

        void BeginInvokeSafe(Action a) { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); }

        void Add(string name, Func<Control> page)
        {
            pages[name] = page;
            var item = new Label { UseMnemonic = false, Text = "    " + name, AutoSize = false, Size = new Size(210, 40), TextAlign = ContentAlignment.MiddleLeft, ForeColor = Theme.SidebarText, Font = Theme.Body, Cursor = Cursors.Hand, Margin = new Padding(0) };
            item.MouseEnter += (o, e) => { if (current != name) item.BackColor = Theme.SidebarHover; };
            item.MouseLeave += (o, e) => { if (current != name) item.BackColor = Theme.Sidebar; };
            item.Click += (o, e) => ShowPage(name);
            navItems[name] = item;
            nav.Controls.Add(item);
        }

        public void ShowPage(string name)
        {
            current = name; onRefresh = null;
            foreach (var kv in navItems) { kv.Value.BackColor = kv.Key == name ? Theme.Accent : Theme.Sidebar; kv.Value.ForeColor = kv.Key == name ? Color.White : Theme.SidebarText; }
            content.SuspendLayout();
            foreach (Control c in content.Controls) c.Dispose();
            content.Controls.Clear();
            content.Controls.Add(pages[name]());
            content.ResumeLayout();
            if (!Visible) base.Show();
        }

        string Other { get { return string.IsNullOrEmpty(S.RemoteName) ? "the other computer" : S.RemoteName; } }

        // ================================================================================================ Overview
        Control OverviewPage()
        {
            var page = Theme.PageBody("Overview", "What DeskView is doing right now. Everything updates live.");
            var status = Theme.Card("Status");
            var actions = Theme.Card("Engine", "The engine shares this computer's keyboard and mouse (server) or receives them (client). " +
                "It runs in the background with the rights it needs to work over admin windows too.");
            actions.Controls.Add(Wrap(
                Theme.Button("Start / restart", (o, e) => { engine.RestartEngine(); }, true),
                Theme.Button("Stop", (o, e) => engine.StopEngine()),
                Theme.Button("Setup assistant...", (o, e) => { using (var w = new SetupWizard(engine)) w.ShowDialog(this); ShowPage("Overview"); })));
            var checks = Theme.Card("Health checks", "If something here is not green, it tells you what to do.");
            page.Controls.Add(status); page.Controls.Add(actions); page.Controls.Add(checks);

            // The rows are made once; each refresh only changes the text/colour that actually changed (no blinking).
            var vMe = Theme.Label(""); var vOther = Theme.Status("", Theme.Warn); var vEngine = Theme.Status("", Theme.Warn);
            var vShowing = Theme.Label(""); var vSharing = Theme.Status("", Theme.Warn); var vControl = Theme.Label("");
            status.Controls.Add(Theme.Row("This computer", vMe));
            status.Controls.Add(Theme.Row("Other computer", vOther));
            status.Controls.Add(Theme.Row("Keyboard & mouse", vEngine));
            status.Controls.Add(Theme.Row("Showing", vShowing));
            status.Controls.Add(Theme.Row("Sharing my screens", vSharing));
            status.Controls.Add(Theme.Row("Remote control channel", vControl));
            onRefresh = () =>
            {
                string role = S.Role == Role.Server ? "Server - this computer's keyboard and mouse are shared" : S.Role == Role.Client ? "Client - uses the server's keyboard and mouse" : "Not set up yet";
                Theme.SetText(vMe, string.Format("{0}  ({1})", S.ComputerName, role));
                var peer = engine.CurrentPeer();
                if (peer != null) Theme.SetStatus(vOther, string.Format("{0} connected ({1})", Other, peer), Theme.Good);
                else Theme.SetStatus(vOther, S.Role == Role.Client ? (string.IsNullOrEmpty(S.ServerAddress) ? "not connected - looking for the server on the local network" : string.Format("not connected - looking for the server at {0}", S.ServerAddress)) : string.Format("waiting for {0} to connect", Other), Theme.Warn);
                string eng = engine.Builtin ? "DeskView built-in" : "classic engine";
                if (engine.EngineRunning) Theme.SetStatus(vEngine, eng + " - running", Theme.Good); else Theme.SetStatus(vEngine, eng + " - not linked yet", Theme.Bad);
                string shown = string.Join(", ", engine.Media.Players.Values.Select(p => string.Format("{0} <- screen {1}{2}", p.Key, p.RemoteN, (p.Live ? string.Format(" ({0}x{1})", p.RemoteRes.Value.Width, p.RemoteRes.Value.Height) : " (connecting)"))));
                Theme.SetText(vShowing, shown.Length > 0 ? shown : "nothing (choose on the Screens page)");
                int senders = engine.Media.Senders.Values.Count(s => s.P != null && !s.P.HasExited);
                if (senders > 0) Theme.SetStatus(vSharing, string.Format("{0} screen(s) ready to be viewed (encrypted)", senders), Theme.Good); else Theme.SetStatus(vSharing, "not yet", Theme.Warn);
                Theme.SetText(vControl, engine.AgentClient.Length > 0 ? string.Format("{0} is linked to this computer (encrypted)", Other) : engine.ForwarderConnected ? "connected (encrypted)" : "ready");
            };
            onRefresh();

            // health checks don't need a live refresh
            Action<string, bool, string> Check = (what, ok, fix) => checks.Controls.Add(Theme.Status(ok ? what : what + " - " + fix, ok ? Theme.Good : Theme.Bad));
            if (engine.Builtin)
            {
                Check("Keyboard & mouse: DeskView built-in (nothing else to install)", true, "");
                Check("Linked with the other computer (encrypted)", engine.ForwarderConnected || engine.AgentClient.Length > 0,
                    S.Role == Role.Client ? "make sure DeskView runs on the server with the same pairing code" : "waiting for the other computer - start DeskView there");
            }
            else
            {
                Check("Keyboard & mouse engine installed", CoreControl.Installed, "run the DeskView installer with -ClassicEngine, or switch to DeskView built-in");
                Check("Engine supports portals (DeskView build)", CoreControl.PortalCapable, "switch to DeskView built-in on the Switching & input page to work directly on the other computer's picture");
            }
            Check("FFmpeg (video) found", engine.Media.HasFFmpeg, "run the DeskView installer (it downloads FFmpeg)");
            Check("Firewall allows DeskView on the local network", Firewall.RulesPresent(), "run the DeskView installer once as administrator");
            Check("Pairing code set", AppSettings.IsValidPairCode(S.PairCode), "set it on the Connection page");
            return page;
        }

        // ================================================================================================ What you can do
        Control GuidePage()
        {
            string me = S.Role == Role.Client ? "this laptop" : S.ComputerName, other = Other;
            var page = Theme.PageBody("What you can do", "Step by step: every DeskView feature and exactly how to use it.");
            page.Controls.Add(How("Move any window from any laptop to any screen",
                string.Format("One desktop across both computers: a window that lives on {0} can be dragged onto any monitor that shows {0}, and {1}'s own windows onto any of its own screens.", other, me),
                string.Format("Screens page: click a monitor and pick which of {0}'s screens it shows (each of {0}'s screens can be on a different monitor).", other),
                string.Format("Move the mouse onto that monitor - the mouse is now on {0}.", other),
                string.Format("Grab the window's title bar (for example a PowerShell tab on {0}) and drag it to another monitor showing {0}: it moves there like on a normal multi-monitor PC.", other),
                string.Format("Want more places for {0}'s windows? Give the laptop extra virtual screens (Screens page > More screens on a laptop), then show each one on a monitor.", other),
                "Shortcut: Ctrl+Alt+1..9 puts the other computer's main screen on monitor 1..9, Ctrl+Alt+D cycles it through your monitors, Ctrl+Alt+0 hides it."));
            page.Controls.Add(How("Work on the other computer",
                "Your keyboard and mouse follow the pointer, across both computers.",
                string.Format("Move the mouse off the edge set on the Connection page to go to {0}; move it back to return.", other),
                string.Format("Or move it onto a monitor showing {0}'s picture: it lands at the same spot on {0}.", other),
                "Scroll Lock locks the mouse to the computer it is on."));
            page.Controls.Add(How("Copy and paste between the computers",
                "Text, pictures and files you copy on one computer can be pasted on the other.",
                "Copy as usual (Ctrl+C) on one computer.",
                "Move the mouse to the other computer and paste (Ctrl+V). Clipboard size and on/off: Switching & input page."));
            page.Controls.Add(How("Send files by drag and drop",
                string.Format("Drop files or folders onto {0}'s picture to send them, encrypted with the pairing code.", other),
                string.Format("Drag files from Explorer and hold them over a monitor showing {0}: it lights up \"Drop to send\".", other),
                string.Format("Release: they arrive in Downloads\\DeskView on {0}, with a notification there. Nothing is ever overwritten.", other)));
            page.Controls.Add(How("Use the server from the laptop",
                "Two-way: the laptop can also view and control the server's screens.",
                "On the laptop press Ctrl+Alt+1..9 to show the server's screen 1..9 full screen and control it with the laptop's own keyboard and touchpad.",
                "Ctrl+Alt+0 comes back to the laptop."));
            return page;
        }

        Control How(string title, string what, params string[] steps)
        {
            var c = Theme.Card(title, what);
            for (int i = 0; i < steps.Length; i++) c.Controls.Add(Theme.Label(string.Format("{0}.  {1}", i + 1, steps[i])));
            return c;
        }

        static FlowLayoutPanel Wrap(params Control[] cs) { var p = new FlowLayoutPanel { AutoSize = true, WrapContents = true, Margin = new Padding(0, 4, 0, 0) }; foreach (var c in cs) p.Controls.Add(c); return p; }

        // ================================================================================================ Screens
        Control ScreensPage()
        {
            if (S.Role == Role.Client)
            {
                var pc = Theme.PageBody("Screens", "View one of the server's screens full screen and control it with this computer's own keyboard and touchpad.");
                var view = Theme.Card("View the server", "Or press Ctrl+Alt+1..9 anywhere (Ctrl+Alt+0 comes back).");
                var row = Wrap();
                for (int n = 1; n <= 4; n++) { int k = n; row.Controls.Add(Theme.Button(string.Format("Its screen {0}", n), (o, e) => engine.ShowOn(k.ToString()), S.ClientView == n)); }
                row.Controls.Add(Theme.Button("Back to this computer", (o, e) => engine.ShowOn("off")));
                view.Controls.Add(row);
                pc.Controls.Add(view);
                pc.Controls.Add(VirtualScreensCard());
                pc.Controls.Add(VideoCard());
                return pc;
            }
            var page = Theme.PageBody("Screens", string.Format("Any of your monitors can show any of {0}'s screens. Click a monitor to choose. ", Other) +
                string.Format("Move the mouse onto a monitor showing {0} to use it - the mouse then moves across all of {0}'s screens, so you can drag ", Other) +
                "windows between them like a normal multi-monitor desktop.");
            var map = Theme.Card("Your monitors");
            var sm = new ScreenMap(engine);
            map.Controls.Add(sm);
            map.Controls.Add(Theme.Hint("Shortcuts: Ctrl+Alt+1..9 puts the other computer's main screen on that monitor, Ctrl+Alt+0 hides everything, Ctrl+Alt+D cycles."));
            if (!engine.Builtin && !CoreControl.PortalCapable) map.Controls.Add(Theme.Status("The installed engine has no portals: you can watch the other computer here but not work on it directly.", Theme.Warn));
            page.Controls.Add(map);
            page.Controls.Add(VirtualScreensCard());
            page.Controls.Add(VideoCard());
            onRefresh = () => sm.Invalidate();
            return page;
        }

        Control VirtualScreensCard()
        {
            var c = Theme.Card("More screens on a laptop", "A laptop can get extra virtual screens that Windows treats as real monitors. They show up on the other computer's " +
                "monitors, so its windows can be dragged across all of them. Run on the laptop (administrator approval once):");
            var box = new TextBox { ReadOnly = true, Width = 640, Font = new Font("Consolas", 9f), Text = "iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile $env:TEMP\\deskview-install.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\\deskview-install.ps1 -VirtualScreens 2" };
            c.Controls.Add(box);
            c.Controls.Add(Theme.Button("Copy command", (o, e) => Theme.CopyText(box.Text)));
            c.Controls.Add(Theme.Hint("Then arrange the new screens in Windows Settings > System > Display (for example to the right of the laptop screen)."));
            return c;
        }

        Control VideoCard()
        {
            var c = Theme.Card("Picture", "How the other computer's screens are shown. Video runs on the graphics chip on both sides.");
            var pic = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
            pic.Items.AddRange(new object[] { "Fit - keep its shape", "Stretch - fill the monitor" });
            pic.SelectedIndex = S.Picture == "Stretch" ? 1 : 0;
            var q = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
            q.Items.AddRange(new object[] { "Auto (detect wired / Wi-Fi)", "Wired - 20 Mbps, lowest delay", "Wi-Fi - 10 Mbps, steadier" });
            q.SelectedIndex = S.Profile == "Wired" ? 1 : S.Profile == "WiFi" ? 2 : 0;
            var inter = Theme.Check("Interactive: moving the mouse onto a picture works on that computer", S.Interactive, v => S.Interactive = v);
            c.Controls.Add(Theme.Row("Picture", pic));
            c.Controls.Add(Theme.Row("Quality", q));
            if (S.Role == Role.Server) c.Controls.Add(inter);
            c.Controls.Add(Theme.Button("Save and apply", (o, e) =>
            {
                S.Picture = pic.SelectedIndex == 1 ? "Stretch" : "Fit";
                S.Profile = q.SelectedIndex == 1 ? "Wired" : q.SelectedIndex == 2 ? "WiFi" : "Auto";
                S.Save(); engine.Media.StopPlayers(); engine.Media.StopSenders(); engine.SyncPlayers();
                Toast("Saved");
            }, true));
            return c;
        }

        // ================================================================================================ Connection
        Control ConnectionPage()
        {
            var page = Theme.PageBody("Connection", "Which computer shares its keyboard and mouse, how the two find each other, and the code that pairs them.");
            var role = Theme.Card("Role", "The SERVER is the computer whose keyboard and mouse you use. The CLIENT is the other one (usually the laptop).");
            var rServer = new RadioButton { Text = "Server - share this computer's keyboard and mouse", AutoSize = true, Checked = S.Role == Role.Server };
            var rClient = new RadioButton { Text = "Client - use the server's keyboard and mouse", AutoSize = true, Checked = S.Role == Role.Client };
            role.Controls.Add(rServer); role.Controls.Add(rClient);

            var names = Theme.Card("Names and address");
            var me = new TextBox { Text = S.ComputerName, Width = 260 };
            var other = new TextBox { Text = S.RemoteName, Width = 260 };
            var host = new TextBox { Text = S.ServerAddress, Width = 260 };
            var port = Theme.Number(S.Port, 1, 65535, v => { }, 100);
            names.Controls.Add(Theme.Row("This computer's name", me));
            names.Controls.Add(Theme.Row("Other computer's name", other));
            names.Controls.Add(Theme.Hint("Server: leave the other name empty and DeskView adds the client automatically the first time it connects."));
            names.Controls.Add(Theme.Row("Server address (client only)", host));
            names.Controls.Add(Theme.Row("Port", port));
            names.Controls.Add(Theme.Row("This computer's addresses", Theme.Label(string.Join(", ", LocalAddresses()))));

            var layout = Theme.Card("Where is the other computer?", "Moving the mouse off this edge of your desktop goes to the other computer. " +
                "Pictures on your monitors work in addition to this.");
            var side = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
            side.Items.AddRange(Enum.GetNames(typeof(Side)));
            side.SelectedItem = S.RemoteSide.ToString();
            layout.Controls.Add(Theme.Row("Other computer is to the", side));

            var pair = Theme.Card("Pairing code", "Both computers need the same code. It protects the video and the remote control: " +
                "nobody without it can watch or control either computer.");
            var code = new TextBox { Text = S.PairCode, Width = 200, Font = new Font("Consolas", 12f), ReadOnly = S.Role == Role.Server, CharacterCasing = CharacterCasing.Upper };
            pair.Controls.Add(Theme.Row("Code", code));
            if (S.Role == Role.Server) pair.Controls.Add(Theme.Button("New code", (o, e) =>
            {
                if (MessageBox.Show(this, "The other computer will need the new code too. Continue?", "DeskView", MessageBoxButtons.YesNo) == DialogResult.Yes)
                { code.Text = AppSettings.NewPairCode(); }
            }));

            page.Controls.Add(role); page.Controls.Add(names); page.Controls.Add(layout); page.Controls.Add(pair);
            page.Controls.Add(Theme.Button("Save and apply", (o, e) =>
            {
                var newRole = rServer.Checked ? Role.Server : rClient.Checked ? Role.Client : Role.None;
                if (!AppSettings.IsValidPairCode(code.Text)) { MessageBox.Show(this, "The pairing code is 8-12 letters and digits, as shown on the server.", "DeskView"); return; }
                if (newRole == Role.Client && string.IsNullOrWhiteSpace(host.Text)) { MessageBox.Show(this, "Enter the server's address.", "DeskView"); return; }
                bool roleChanged = newRole != S.Role;
                S.Role = newRole; S.ComputerName = me.Text.Trim(); S.RemoteName = other.Text.Trim(); S.ServerAddress = host.Text.Trim();
                S.Port = (int)port.Value; S.RemoteSide = (Side)Enum.Parse(typeof(Side), (string)side.SelectedItem); S.PairCode = code.Text.Trim().ToUpperInvariant();
                S.Save(); engine.ApplyEngine(true);
                if (roleChanged) MessageBox.Show(this, "The role changed: restart DeskView to switch over completely.", "DeskView");
                Toast("Saved and applied");
            }, true));
            return page;
        }

        static IEnumerable<string> LocalAddresses()
        {
            try
            {
                return NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                    .SelectMany(n => n.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork).Select(a => a.Address.ToString()).Distinct();
            }
            catch { return new[] { "?" }; }
        }

        // ================================================================================================ Input
        Control InputPage()
        {
            var page = Theme.PageBody("Switching & input", "How the mouse moves between the computers and how keys, scrolling and the clipboard behave. " +
                "Every switching option, with clear names.");
            var sw = Theme.Card("Switching between computers");
            sw.Controls.Add(Theme.Row("Wait before switching", Theme.Check("on", S.SwitchDelayEnabled, v => S.SwitchDelayEnabled = v), Theme.Number(S.SwitchDelayMs, 10, 5000, v => S.SwitchDelayMs = v), Theme.Label("ms")));
            sw.Controls.Add(Theme.Hint("The mouse must rest at the edge this long before it switches - stops accidental switches."));
            sw.Controls.Add(Theme.Row("Double-tap the edge to switch", Theme.Check("on", S.DoubleTapEnabled, v => S.DoubleTapEnabled = v), Theme.Number(S.DoubleTapMs, 10, 5000, v => S.DoubleTapMs = v), Theme.Label("ms")));
            sw.Controls.Add(Theme.Check("Lock the mouse to the current computer by default (Scroll Lock toggles)", S.DefaultLockToScreen, v => S.DefaultLockToScreen = v));
            sw.Controls.Add(Theme.Check("Never lock the mouse to one computer", S.DisableLockToScreen, v => S.DisableLockToScreen = v));
            sw.Controls.Add(Theme.Check("Relative mouse moves (for games that capture the mouse)", S.RelativeMouseMoves, v => S.RelativeMouseMoves = v));
            sw.Controls.Add(Theme.Check("Keep the active window in front on Windows clients", S.Win32KeepForeground, v => S.Win32KeepForeground = v));
            var corners = Theme.Card("Dead corners", "No switching in these corners of the other computer (so its Start button or close buttons are easy to hit).");
            corners.Controls.Add(Wrap(Theme.Check("Top left", S.CornerTopLeft, v => S.CornerTopLeft = v), Theme.Check("Top right", S.CornerTopRight, v => S.CornerTopRight = v),
                Theme.Check("Bottom left", S.CornerBottomLeft, v => S.CornerBottomLeft = v), Theme.Check("Bottom right", S.CornerBottomRight, v => S.CornerBottomRight = v)));
            corners.Controls.Add(Theme.Row("Corner size", Theme.Number(S.CornerSize, 0, 500, v => S.CornerSize = v), Theme.Label("pixels")));
            var keys = Theme.Card("Keys on the other computer", "Remap modifier keys (for example Mac-style keyboards) and handle Caps/Num/Scroll Lock keys that only send one press.");
            string[] mods = { "shift", "ctrl", "alt", "altgr", "meta", "super", "none" };
            Func<string, Action<string>, ComboBox> Mod = (value, set) => { var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 110 }; c.Items.AddRange(mods); c.SelectedItem = mods.Contains(value) ? value : mods[0]; c.SelectedIndexChanged += (o, e) => set((string)c.SelectedItem); return c; };
            keys.Controls.Add(Theme.Row("Shift / Ctrl / Alt", Mod(S.ModifierShift, v => S.ModifierShift = v), Mod(S.ModifierCtrl, v => S.ModifierCtrl = v), Mod(S.ModifierAlt, v => S.ModifierAlt = v)));
            keys.Controls.Add(Theme.Row("AltGr / Meta / Super", Mod(S.ModifierAltGr, v => S.ModifierAltGr = v), Mod(S.ModifierMeta, v => S.ModifierMeta = v), Mod(S.ModifierSuper, v => S.ModifierSuper = v)));
            keys.Controls.Add(Wrap(Theme.Check("Half-duplex Caps Lock", S.HalfDuplexCapsLock, v => S.HalfDuplexCapsLock = v), Theme.Check("Half-duplex Num Lock", S.HalfDuplexNumLock, v => S.HalfDuplexNumLock = v),
                Theme.Check("Half-duplex Scroll Lock", S.HalfDuplexScrollLock, v => S.HalfDuplexScrollLock = v)));
            var scroll = Theme.Card("Scrolling and keyboard layout (on this computer as a client)");
            scroll.Controls.Add(Wrap(Theme.Check("Invert vertical scrolling", S.InvertScrollY, v => S.InvertScrollY = v), Theme.Check("Invert horizontal scrolling", S.InvertScrollX, v => S.InvertScrollX = v)));
            scroll.Controls.Add(Theme.Row("Scroll speed (%)", Theme.Number((int)(S.ScrollScaleY * 100), 10, 1000, v => { S.ScrollScaleY = v / 100.0; S.ScrollScaleX = v / 100.0; })));
            scroll.Controls.Add(Theme.Check("Follow the server's keyboard layout", S.LanguageSync, v => S.LanguageSync = v));
            var clip = Theme.Card("Clipboard", "Copy on one computer, paste on the other.");
            clip.Controls.Add(Theme.Check("Share the clipboard", S.ClipboardEnabled, v => S.ClipboardEnabled = v));
            var eng = Theme.Card("Keyboard & mouse engine", "Classic: the separate engine (most tested). DeskView built-in: switching and clipboard by DeskView itself - " +
                "one app, encrypted with the pairing code, no separate engine running. Both computers must use the same choice.");
            var engPick = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 380 };
            engPick.Items.AddRange(new object[] { "Classic engine", "DeskView built-in (new)" });
            engPick.SelectedIndex = S.InputEngine == "DeskView" ? 1 : 0;
            engPick.SelectedIndexChanged += (o, e) =>
            {
                var want = engPick.SelectedIndex == 1 ? "DeskView" : "Classic";
                if (want == S.InputEngine) return;
                S.InputEngine = want; S.Save(); engine.ApplyEngine(want == "Classic");
                Toast(want == "DeskView" ? "DeskView built-in switching is on. Use the same choice on the other computer." : "Classic engine is back on.");
                BeginInvoke((Action)(() => ShowPage("Switching & input")));   // the options that apply change with the engine
            };
            eng.Controls.Add(Theme.Row("Engine", engPick));
            var ptr = Theme.Card("Mouse pointer", "Windows hides the pointer on a laptop with no mouse plugged in, so the pointer you move from the other computer can be invisible. " +
                "DeskView keeps it visible by turning on Windows Mouse Keys (Accessibility) - nothing else changes while Num Lock is on.");
            ptr.Controls.Add(Theme.Check("Always show the mouse pointer on this computer when it is the client", S.AlwaysShowPointer, v => { S.AlwaysShowPointer = v; S.Save(); engine.ApplyPointer(); }));
            clip.Controls.Add(Theme.Row("Largest clipboard to share", Theme.Number(S.ClipboardSizeMb, 1, 1024, v => S.ClipboardSizeMb = v), Theme.Label("MB")));
            var misc = Theme.Card("Connection health and power");
            misc.Controls.Add(Theme.Row("Detect a dead connection", Theme.Check("on", S.HeartbeatEnabled, v => S.HeartbeatEnabled = v), Theme.Number(S.HeartbeatMs, 500, 60000, v => S.HeartbeatMs = v), Theme.Label("ms")));
            misc.Controls.Add(Theme.Check("Keep this computer awake while connected", S.PreventSleep, v => S.PreventSleep = v));
            if (engine.Builtin)
            {
                // These are settings of the classic engine: with DeskView's own switching they have no effect, so say so
                // instead of offering controls that silently do nothing.
                eng.Controls.Add(Theme.Hint("With DeskView built-in, the greyed-out options below belong to the classic engine and have no effect. " +
                    "Clipboard and mouse pointer apply to both engines; the side the other computer is on is set on the Connection page."));
                foreach (var c in new Control[] { sw, corners, keys, scroll, misc }) c.Enabled = false;
            }
            foreach (var c in new Control[] { eng, sw, corners, keys, scroll, clip, ptr, misc }) page.Controls.Add(c);
            page.Controls.Add(Theme.Button("Save and apply", (o, e) => { S.Save(); engine.ApplyEngine(); Toast("Saved and applied"); }, true));
            return page;
        }

        // ================================================================================================ Security
        Control SecurityPage()
        {
            var page = Theme.PageBody("Security", "How DeskView keeps the two computers' traffic private on your network.");
            var tls = Theme.Card("Keyboard and mouse traffic", "Encrypted with TLS. Each computer has a certificate; the other side remembers its fingerprint and refuses impostors.");
            tls.Controls.Add(Theme.Check("Encrypt keyboard and mouse traffic (TLS)", S.TlsEnabled, v => S.TlsEnabled = v));
            tls.Controls.Add(Theme.Check("Only accept a computer whose fingerprint was trusted", S.CheckPeers, v => S.CheckPeers = v));
            var fp = CoreControl.CertificateFingerprint();
            tls.Controls.Add(Theme.Row("This computer's fingerprint", new TextBox { ReadOnly = true, Width = 420, Font = new Font("Consolas", 8.5f), Text = fp.Length > 0 ? fp : "(no certificate yet)" }));
            var dv = Theme.Card("Video and remote control", "Video: AES-256 (SRT) with a key derived from the pairing code. Remote control: the code is never sent - both sides prove they know it " +
                "(PBKDF2 + HMAC challenge), then every message is AES-256 encrypted and authenticated. Finding the other computer on the network is sealed with the code too; " +
                "5 wrong attempts lock an address out for a minute. Firewall rules allow only the local network.");
            if (engine.Builtin)
            {
                tls.Controls.Add(Theme.Hint("These two options belong to the classic engine. DeskView built-in always encrypts and authenticates everything with the pairing code."));
                foreach (Control c in tls.Controls) if (c is CheckBox) c.Enabled = false;
            }
            page.Controls.Add(tls); page.Controls.Add(dv);
            page.Controls.Add(Theme.Button("Save and apply", (o, e) => { S.Save(); engine.ApplyEngine(); Toast("Saved and applied"); }, true));
            return page;
        }

        // ================================================================================================ Logs
        Control LogsPage()
        {
            var page = Theme.PageBody("Logs", "What the engine and DeskView have been doing - useful when something does not work.");
            var level = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 140 };
            level.Items.AddRange(new object[] { "ERROR", "WARNING", "NOTE", "INFO", "DEBUG", "DEBUG1", "DEBUG2" });
            level.SelectedItem = S.LogLevel;
            level.SelectedIndexChanged += (o, e) => { S.LogLevel = (string)level.SelectedItem; S.Save(); engine.ApplyEngine(); };
            page.Controls.Add(Theme.Row("Engine detail level", level));
            var box = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 9f), Size = new Size(700, 420), BackColor = Color.White };
            page.Controls.Add(box);
            page.Controls.Add(Wrap(Theme.Button("Open log folder", (o, e) => Process.Start("explorer.exe", AppSettings.Dir)),
                                  Theme.Button("Copy", (o, e) => { if (box.Text.Length > 0) Theme.CopyText(box.Text); })));
            onRefresh = () =>
            {
                var lines = CoreControl.TailLog(200);
                var mine = File.Exists(Log.Path) ? File.ReadAllLines(Log.Path).Reverse().Take(30).Reverse() : Enumerable.Empty<string>();
                var text = "=== engine ===\r\n" + string.Join("\r\n", lines) + "\r\n\r\n=== DeskView ===\r\n" + string.Join("\r\n", mine);
                if (box.Text != text) { box.Text = text; box.SelectionStart = box.Text.Length; box.ScrollToCaret(); }
            };
            onRefresh();
            return page;
        }

        // ================================================================================================ About
        Control AboutPage()
        {
            var page = Theme.PageBody("About DeskView", "One keyboard and mouse for several computers - and every computer's screens on any monitor, in both directions.");
            var c = Theme.Card("Version");
            c.Controls.Add(Theme.Row("DeskView", Theme.Label(Application.ProductVersion)));
            c.Controls.Add(Theme.Row("Engine", Theme.Label(CoreControl.Installed ? FileVersionInfo.GetVersionInfo(CoreControl.CorePath).ProductVersion + (CoreControl.PortalCapable ? " (DeskView build)" : " (standard)") : "not installed")));
            c.Controls.Add(Theme.Row("Project", Theme.Label("github.com/xl337x/DeskView")));
            c.Controls.Add(Theme.Hint("Third-party components and their licenses: THIRD_PARTY_NOTICES.md in the DeskView repository. Video by FFmpeg."));
            page.Controls.Add(c);
            return page;
        }

        void Toast(string text) { var t = TrayApp.Instance; if (t != null) t.Notify(text, false); }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // closing the window keeps DeskView running in the tray
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
            base.OnFormClosing(e);
        }
    }

    public static class Firewall
    {
        public static bool RulesPresent()
        {
            try
            {
                var psi = new ProcessStartInfo("netsh", "advfirewall firewall show rule name=\"DeskView video (UDP 9000-9009)\"") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
                using (var p = Process.Start(psi)) { p.StandardOutput.ReadToEnd(); p.WaitForExit(5000); return p.ExitCode == 0; }
            }
            catch { return false; }
        }
    }
}
