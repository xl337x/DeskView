// DeskView runs in the tray: the window opens on demand, the engine keeps working when it is closed.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using DeskView.UI;
using Microsoft.Win32;

namespace DeskView
{
    public class TrayApp : ApplicationContext
    {
        public static TrayApp Instance;
        readonly Engine engine;
        readonly NotifyIcon tray;
        MainForm window;

        public TrayApp(Engine e, bool showWindow)
        {
            Instance = this;
            engine = e;
            tray = new NotifyIcon { Icon = AppIcon.Get(), Text = "DeskView", Visible = true, ContextMenuStrip = new ContextMenuStrip { Font = UI.Theme.Body } };
            tray.DoubleClick += (o, ev) => Open();
            tray.ContextMenuStrip.Opening += (o, ev) => BuildMenu();
            engine.Notice += (m, warn) => Notify(m, warn);
            BuildMenu();
            ApplyStartAtLogin(e.S.StartAtLogin);
            if (!e.S.SetupDone || e.S.Role == Role.None)
            {
                using (var w = new SetupWizard(engine)) w.ShowDialog();
                if (!e.S.SetupDone) { ExitThreadCore(); return; }
            }
            engine.Start();
            if (showWindow) Open();
        }

        public void Open(string page = "Overview")
        {
            if (window == null || window.IsDisposed) window = new MainForm(engine);
            window.ShowPage(page);
            window.WindowState = FormWindowState.Normal;
            window.Activate();
        }

        public void Notify(string text, bool warning) => tray.ShowBalloonTip(warning ? 5000 : 2000, "DeskView", text, warning ? ToolTipIcon.Warning : ToolTipIcon.Info);

        void BuildMenu()
        {
            var m = tray.ContextMenuStrip; m.Items.Clear();
            var S = engine.S;
            var head = new ToolStripMenuItem($"{S.ComputerName} ({S.Role})  -  {(engine.Connected ? "connected" : "not connected")}") { Enabled = false };
            m.Items.Add(head);
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add("Open DeskView", null, (o, e) => Open());
            if (S.Role == Role.Server)
            {
                var show = new ToolStripMenuItem("Show the other computer on");
                int i = 0;
                foreach (var s in Tools.OrderedScreens())
                {
                    i++; var n = Tools.Short(s); int k = i;
                    show.DropDownItems.Add(new ToolStripMenuItem($"{i}. {n}   Ctrl+Alt+{i}", null, (o, e) => engine.ShowOn(k.ToString())) { Checked = S.Screens.TryGetValue(n, out var v) && v == 1 });
                }
                show.DropDownItems.Add(new ToolStripSeparator());
                show.DropDownItems.Add("All off   Ctrl+Alt+0", null, (o, e) => engine.ShowOn("off"));
                show.DropDownItems.Add("More (Screens page)...", null, (o, e) => Open("Screens"));
                m.Items.Add(show);
            }
            else if (S.Role == Role.Client)
            {
                var view = new ToolStripMenuItem("View the server's screen");
                for (int n = 1; n <= 4; n++) { int k = n; view.DropDownItems.Add(new ToolStripMenuItem($"Screen {n}   Ctrl+Alt+{n}", null, (o, e) => engine.ShowOn(k.ToString())) { Checked = S.ClientView == n }); }
                view.DropDownItems.Add(new ToolStripSeparator());
                view.DropDownItems.Add("Back to this computer   Ctrl+Alt+0", null, (o, e) => engine.ShowOn("off"));
                m.Items.Add(view);
            }
            m.Items.Add("Restart engine", null, (o, e) => engine.RestartEngine());
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add("Exit", null, (o, e) => Quit());
        }

        void Quit()
        {
            engine.Shutdown();
            tray.Visible = false;
            ExitThreadCore();
        }

        public static void ApplyStartAtLogin(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (on) k.SetValue("DeskView", "\"" + Application.ExecutablePath + "\" --tray");
                    else if (k.GetValue("DeskView") != null) k.DeleteValue("DeskView");
                }
            }
            catch { }
        }
    }

    /// <summary>The DeskView icon: the .exe's own icon, or a drawn one (two screens) if that is missing.</summary>
    public static class AppIcon
    {
        static Icon icon;
        public static Icon Get()
        {
            if (icon != null) return icon;
            try { icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            if (icon != null) return icon;
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var b = new SolidBrush(UI.Theme.Accent)) { g.FillRectangle(b, 2, 6, 17, 12); g.FillRectangle(b, 13, 13, 17, 12); }
                    using (var w = new Pen(Color.White, 1.5f)) g.DrawRectangle(w, 13, 13, 17, 12);
                }
                icon = Icon.FromHandle(bmp.GetHicon());
            }
            return icon;
        }
    }
}
