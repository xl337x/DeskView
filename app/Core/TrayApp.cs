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

        public void Notify(string text, bool warning)
        {
            tray.ShowBalloonTip(warning ? 5000 : 2000, "DeskView", text, warning ? ToolTipIcon.Warning : ToolTipIcon.Info);
        }

        void BuildMenu()
        {
            var m = tray.ContextMenuStrip; m.Items.Clear();
            var S = engine.S;
            var head = new ToolStripMenuItem(string.Format("{0} ({1})  -  {2}", S.ComputerName, S.Role, (engine.Connected ? "connected" : "not connected"))) { Enabled = false };
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
                    int v;
                    show.DropDownItems.Add(new ToolStripMenuItem(string.Format("{0}. {1}   Ctrl+Alt+{0}", i, n), null, (o, e) => engine.ShowOn(k.ToString())) { Checked = S.Screens.TryGetValue(n, out v) && v == 1 });
                }
                show.DropDownItems.Add(new ToolStripSeparator());
                show.DropDownItems.Add("All off   Ctrl+Alt+0", null, (o, e) => engine.ShowOn("off"));
                show.DropDownItems.Add("More (Screens page)...", null, (o, e) => Open("Screens"));
                m.Items.Add(show);
            }
            else if (S.Role == Role.Client)
            {
                var view = new ToolStripMenuItem("View the server's screen");
                for (int n = 1; n <= 4; n++) { int k = n; view.DropDownItems.Add(new ToolStripMenuItem(string.Format("Screen {0}   Ctrl+Alt+{0}", n), null, (o, e) => engine.ShowOn(k.ToString())) { Checked = S.ClientView == n }); }
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

        /// <summary>Start at sign-in through the same Startup shortcut setup makes (DeskView runs inside powershell.exe,
        /// so the process's own path is no use). Only for the installed copy: a copy run from elsewhere (tests, a
        /// checkout) never takes over the real install's startup.</summary>
        public static void ApplyStartAtLogin(bool on)
        {
            try
            {
                // an older version started itself from the Run key (as "powershell.exe --tray", which fails)
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                    if (k != null && k.GetValue("DeskView") != null) k.DeleteValue("DeskView");
                var installed = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeskView");
                if (!string.Equals(Program.AppDir.TrimEnd('\\'), installed, StringComparison.OrdinalIgnoreCase)) return;
                var link = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "DeskView.lnk");
                if (!on) { if (System.IO.File.Exists(link)) System.IO.File.Delete(link); return; }
                var shellType = Type.GetTypeFromProgID("WScript.Shell");
                object shell = Activator.CreateInstance(shellType);
                object sc = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { link });
                var t = sc.GetType();
                t.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { "powershell.exe" });
                t.InvokeMember("Arguments", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + System.IO.Path.Combine(installed, "DeskView.ps1") + "\" -Tray" });
                t.InvokeMember("WindowStyle", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { 7 });
                t.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { "DeskView" });
                t.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, sc, null);
            }
            catch (Exception ex) { Log.Write("start at sign-in: " + ex.Message); }
        }
    }

    /// <summary>The DeskView icon: the .exe's own icon, or a drawn one (two screens) if that is missing.</summary>
    public static class AppIcon
    {
        static Icon icon;
        public static Icon Get()
        {
            if (icon != null) return icon;
            try { var f = System.IO.Path.Combine(Program.AppDir, "DeskView.ico"); if (System.IO.File.Exists(f)) icon = new Icon(f); } catch { }
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
