// The setup assistant: a few guided steps that leave both computers working.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace DeskView.UI
{
    public class SetupWizard : Form
    {
        readonly Engine engine;
        AppSettings S { get { return engine.S; } }
        readonly Panel body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(32, 24, 32, 8), BackColor = Theme.Page };
        readonly Label stepLabel = new Label { UseMnemonic = false, Dock = DockStyle.Top, Height = 36, Font = Theme.Small, ForeColor = Theme.Muted, TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(32, 0, 0, 0), BackColor = Theme.Page };
        readonly Button back, next;
        readonly List<Func<Control>> steps = new List<Func<Control>>();
        readonly List<Func<bool>> validators = new List<Func<bool>>();
        int step;

        // answers collected along the way (written to the settings at the end)
        Role role;
        string me, other, host, code, firstMonitor;
        Side side;

        public SetupWizard(Engine e)
        {
            engine = e;
            role = S.Role; me = S.ComputerName; other = S.RemoteName; host = S.ServerAddress; side = S.RemoteSide;
            code = string.IsNullOrEmpty(S.PairCode) ? AppSettings.NewPairCode() : S.PairCode;
            firstMonitor = S.Screens.FirstOrDefault(kv => kv.Value == 1).Key ?? "";
            Text = "DeskView setup"; Icon = AppIcon.Get(); Size = new Size(760, 560); StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; Font = Theme.Body; BackColor = Theme.Page; AutoScaleMode = AutoScaleMode.Dpi;

            var footer = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 58, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(24, 10, 24, 10), BackColor = Color.White };
            next = Theme.Button("Next", (o, ev) => Go(+1), true);
            back = Theme.Button("Back", (o, ev) => Go(-1));
            footer.Controls.Add(next); footer.Controls.Add(back);
            Controls.Add(body); Controls.Add(stepLabel); Controls.Add(footer);

            Step(Welcome); Step(RoleStep, () => role != Role.None || Warn("Choose Server or Client."));
            Step(NamesStep, () => (role != Role.Client || host.Length > 0 || Warn("Enter the server's address.")) && (me.Length > 0 || Warn("Give this computer a name.")));
            Step(PairStep, () => AppSettings.IsValidPairCode(code) || Warn("The pairing code is 8-12 letters and digits, as shown on the server."));
            Step(ScreensStep); Step(DoneStep);
            Go(0);
        }

        void Step(Func<Control> page, Func<bool> valid = null) { steps.Add(page); validators.Add(valid ?? (() => true)); }
        bool Warn(string text) { MessageBox.Show(this, text, "DeskView"); return false; }

        void Go(int delta)
        {
            if (delta > 0 && !validators[step]()) return;
            if (delta > 0 && step == steps.Count - 1) { Finish(); return; }
            step = Math.Max(0, Math.Min(steps.Count - 1, step + delta));
            body.Controls.Clear();
            var c = steps[step](); c.Dock = DockStyle.Fill; body.Controls.Add(c);
            stepLabel.Text = string.Format("Step {0} of {1}", step + 1, steps.Count);
            back.Enabled = step > 0;
            next.Text = step == steps.Count - 1 ? "Finish" : "Next";
        }

        static FlowLayoutPanel Page(string title, string text)
        {
            var p = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
            p.Controls.Add(Theme.Label(title, Theme.Title));
            p.Controls.Add(Theme.Hint(text, 660));
            return p;
        }

        Control Welcome()
        {
            var p = Page("Welcome to DeskView", "DeskView lets one keyboard and mouse work on several computers - and shows every computer's screens on " +
                "any monitor, in both directions. This assistant sets up this computer in a minute. Do the same on the other computer.");
            p.Controls.Add(Theme.Hint("You will need: both computers on the same network, and this assistant open on each of them."));
            return p;
        }

        Control RoleStep()
        {
            var p = Page("What is this computer?", "The SERVER is the computer whose keyboard and mouse you use - usually the desktop with the monitors. " +
                "The CLIENT is the other one - usually the laptop.");
            var s = new RadioButton { Text = "Server - I use this computer's keyboard and mouse", AutoSize = true, Font = Theme.Bold, Checked = role == Role.Server, Margin = new Padding(0, 10, 0, 2) };
            var c = new RadioButton { Text = "Client - this computer will be controlled from the server", AutoSize = true, Font = Theme.Bold, Checked = role == Role.Client, Margin = new Padding(0, 16, 0, 2) };
            s.CheckedChanged += (o, e) => { if (s.Checked) role = Role.Server; };
            c.CheckedChanged += (o, e) => { if (c.Checked) role = Role.Client; };
            p.Controls.Add(s); p.Controls.Add(Theme.Hint("Its monitors can show the client's screens, and moving the mouse onto them works on the client."));
            p.Controls.Add(c); p.Controls.Add(Theme.Hint("It can also show the server's screens full screen and control them with its own keyboard (Ctrl+Alt+1..9)."));
            return p;
        }

        Control NamesStep()
        {
            var p = Page(role == Role.Server ? "This computer's name" : "Find the server", role == Role.Server
                ? "The client will connect to this computer. Give it a name; the client's name is learned automatically when it first connects."
                : "Enter the server's address - DeskView on the server shows it (Connection page), or run 'ipconfig' there.");
            var meBox = new TextBox { Text = me, Width = 280 }; meBox.TextChanged += (o, e) => me = meBox.Text.Trim();
            p.Controls.Add(Theme.Row("This computer's name", meBox));
            if (role == Role.Client)
            {
                var hostBox = new TextBox { Text = host, Width = 280 }; hostBox.TextChanged += (o, e) => host = hostBox.Text.Trim();
                p.Controls.Add(Theme.Row("Server address", hostBox));
            }
            else
            {
                var addrs = System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                    .Where(n => n.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up && n.NetworkInterfaceType != System.Net.NetworkInformation.NetworkInterfaceType.Loopback)
                    .SelectMany(n => n.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork).Select(a => a.Address.ToString());
                p.Controls.Add(Theme.Row("Tell the client this address", Theme.Label(string.Join("   ", addrs), Theme.Bold)));
                var otherBox = new TextBox { Text = other, Width = 280 }; otherBox.TextChanged += (o, e) => other = otherBox.Text.Trim();
                p.Controls.Add(Theme.Row("Client's name (optional)", otherBox));
            }
            return p;
        }

        Control PairStep()
        {
            if (role == Role.Server)
            {
                var p = Page("Pairing code", "Type this code on the client. It keeps the video and remote control private: nobody without it can watch or control either computer.");
                p.Controls.Add(new Label { UseMnemonic = false, Text = code, AutoSize = true, Font = new Font("Consolas", 26f, FontStyle.Bold), ForeColor = Theme.Accent, Margin = new Padding(0, 16, 0, 16) });
                p.Controls.Add(Theme.Button("Copy", (o, e) => Theme.CopyText(code)));
                return p;
            }
            var c = Page("Pairing code", "Type the code the server shows (DeskView on the server: Connection page, or its setup assistant).");
            var box = new TextBox { Text = code == S.PairCode ? code : "", Width = 260, Font = new Font("Consolas", 18f), CharacterCasing = CharacterCasing.Upper, Margin = new Padding(0, 16, 0, 0) };
            box.TextChanged += (o, e) => code = box.Text.Trim();
            code = box.Text;
            c.Controls.Add(box);
            return c;
        }

        Control ScreensStep()
        {
            if (role == Role.Client)
            {
                var c = Page("Screens", "Nothing to set here. Later: press Ctrl+Alt+1..9 to show the server's screen 1..9 here and control it; Ctrl+Alt+0 comes back.");
                c.Controls.Add(Theme.Hint("Want this laptop's windows on more of the server's monitors? Give it extra virtual screens - see DeskView > Screens."));
                return c;
            }
            var p = Page("Where should the client's screen appear?", "Pick one of your monitors to show the client's main screen. You can change this any time on the Screens page " +
                "(and show more of the client's screens on other monitors).");
            var list = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 360 };
            list.Items.Add("Nowhere for now");
            int i = 0;
            foreach (var s in Tools.OrderedScreens()) { i++; list.Items.Add(string.Format("{0}. {1}  {2}x{3}{4}", i, Tools.Short(s), s.Bounds.Width, s.Bounds.Height, (s.Primary ? "  (main)" : ""))); }
            var names = Tools.OrderedScreens().Select(Tools.Short).ToList();
            list.SelectedIndex = firstMonitor.Length > 0 && names.Contains(firstMonitor) ? names.IndexOf(firstMonitor) + 1 : (names.Count > 1 ? names.Count : 0);
            firstMonitor = list.SelectedIndex > 0 ? names[list.SelectedIndex - 1] : "";
            list.SelectedIndexChanged += (o, e) => firstMonitor = list.SelectedIndex > 0 ? names[list.SelectedIndex - 1] : "";
            p.Controls.Add(Theme.Row("Show the client on", list));
            var sideBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
            sideBox.Items.AddRange(Enum.GetNames(typeof(Side))); sideBox.SelectedItem = side.ToString();
            sideBox.SelectedIndexChanged += (o, e) => side = (Side)Enum.Parse(typeof(Side), (string)sideBox.SelectedItem);
            p.Controls.Add(Theme.Row("The client sits to the", sideBox));
            p.Controls.Add(Theme.Hint("Moving the mouse off that edge of your desktop also goes to the client."));
            return p;
        }

        Control DoneStep()
        {
            var p = Page("Ready", "Click Finish to save and start. DeskView then lives in the tray (bottom-right); double-click it to open this window.");
            Action<string, bool, string> Line = (what, ok, fix) => p.Controls.Add(Theme.Status(ok ? what : what + " - " + fix, ok ? Theme.Good : Theme.Warn));
            Line("Keyboard & mouse engine installed", CoreControl.Installed, "run the DeskView installer first");
            Line("Video (FFmpeg) found", engine.Media.HasFFmpeg, "run the DeskView installer first");
            Line("Firewall allows DeskView", Firewall.RulesPresent(), "run the DeskView installer once as administrator");
            return p;
        }

        void Finish()
        {
            S.Role = role; S.ComputerName = me; S.RemoteName = other; S.ServerAddress = host; S.RemoteSide = side;
            S.PairCode = code.Trim().ToUpperInvariant();
            if (role == Role.Server)
            {
                foreach (var k in S.Screens.Where(kv => kv.Value == 1).Select(kv => kv.Key).ToList()) S.Screens.Remove(k);
                if (firstMonitor.Length > 0) S.Screens[firstMonitor] = 1;
            }
            S.SetupDone = true;
            S.Save();
            engine.ApplyEngine(true);
            engine.SyncPlayers();
            DialogResult = DialogResult.OK;
            Close();
        }
    }
}
