// The on-screen guide: a slim strip along the top of every monitor that shows the other computer (which screen it is,
// and one-click ways back), and a short toast whenever keyboard and mouse move to the other computer and back.
// The strip's area stays this computer's (the hand-over zone of the picture starts below it), so it can always be
// clicked - also when every monitor shows the other computer.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace DeskView.UI
{
    /// <summary>The strip on one monitor: "leet · screen 3" + Give back + All back.</summary>
    public class MonitorStrip : Form
    {
        public const int StripHeight = 30;
        readonly Label text;
        public string Monitor;

        public MonitorStrip(Engine engine, string monitor)
        {
            Monitor = monitor;
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(17, 24, 39); Opacity = 0.88; Height = StripHeight;
            text = new Label { AutoSize = false, Dock = DockStyle.Fill, ForeColor = Color.White, Font = new Font("Segoe UI", 9.5f), TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(10, 0, 0, 0), UseMnemonic = false };
            var back = StripButton("Give this monitor back", (o, e) => engine.SetScreen(Monitor, 0));
            var all = StripButton("All back  (Ctrl+Alt+0)", (o, e) => engine.ShowOn("off"));
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Right, AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, BackColor = BackColor, Padding = new Padding(0, 3, 6, 0) };
            buttons.Controls.Add(back); buttons.Controls.Add(all);
            Controls.Add(text); Controls.Add(buttons);
        }

        static Button StripButton(string label, EventHandler click)
        {
            var b = new Button { Text = label, AutoSize = true, FlatStyle = FlatStyle.Flat, ForeColor = Color.White, BackColor = Color.FromArgb(37, 99, 235), Font = new Font("Segoe UI", 8.5f), Height = 23, Margin = new Padding(4, 0, 0, 0), UseMnemonic = false, Cursor = Cursors.Hand };
            b.FlatAppearance.BorderSize = 0; b.Click += click; return b;
        }

        public void Show(Rectangle monitor, string caption)
        {
            if (text.Text != caption) text.Text = caption;
            var r = new Rectangle(monitor.Left, monitor.Top, monitor.Width, StripHeight);
            if (Bounds != r) Bounds = r;
            if (!Visible) Show();
            DeskViewPortal.MakePassive(Handle);   // above the picture, never takes focus or shows in Alt+Tab
        }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80 | 0x8; return cp; }   // NOACTIVATE | TOOLWINDOW | TOPMOST
        }
    }

    /// <summary>A short, click-through message near the top of a monitor that fades by itself.</summary>
    public class Toast : Form
    {
        readonly Label text;
        readonly Timer fade = new Timer { Interval = 40 };
        DateTime until;

        public Toast()
        {
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(17, 24, 39); Opacity = 0;
            text = new Label { AutoSize = false, Dock = DockStyle.Fill, ForeColor = Color.White, Font = new Font("Segoe UI", 12f), TextAlign = ContentAlignment.MiddleCenter, UseMnemonic = false };
            Controls.Add(text);
            fade.Tick += (o, e) =>
            {
                var left = (until - DateTime.Now).TotalMilliseconds;
                if (left > 400) { if (Opacity < 0.9) Opacity = Math.Min(0.9, Opacity + 0.15); }
                else if (left > 0) Opacity = Math.Max(0, 0.9 * left / 400);
                else { fade.Stop(); Hide(); }
            };
        }

        /// <summary>Shows the message centred near the top of this monitor for a few seconds.</summary>
        public void Say(Rectangle monitor, string message, double seconds)
        {
            text.Text = message;
            var size = TextRenderer.MeasureText(message, text.Font);
            int w = Math.Min(monitor.Width - 40, size.Width + 60), h = size.Height + 24;
            Bounds = new Rectangle(monitor.Left + (monitor.Width - w) / 2, monitor.Top + MonitorStrip.StripHeight + 24, w, h);
            until = DateTime.Now.AddSeconds(seconds);
            if (!Visible) { Opacity = 0; Show(); }
            DeskViewPortal.MakePassive(Handle);
            fade.Start();
        }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            // NOACTIVATE | TOOLWINDOW | TOPMOST | LAYERED | TRANSPARENT (clicks go through)
            get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80 | 0x8 | 0x80000 | 0x20; return cp; }
        }
    }
}
