// Shared look: colours, fonts and small control builders, so every page looks the same.
using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeskView.UI
{
    public static class Theme
    {
        public static readonly Color Accent = Color.FromArgb(37, 99, 235);       // blue
        public static readonly Color AccentDark = Color.FromArgb(29, 78, 216);
        public static readonly Color Sidebar = Color.FromArgb(17, 24, 39);       // near-black
        public static readonly Color SidebarHover = Color.FromArgb(31, 41, 55);
        public static readonly Color SidebarText = Color.FromArgb(209, 213, 219);
        public static readonly Color Page = Color.FromArgb(249, 250, 251);
        public static readonly Color CardColor = Color.White;
        public static readonly Color Border = Color.FromArgb(229, 231, 235);
        public static readonly Color Text = Color.FromArgb(17, 24, 39);
        public static readonly Color Muted = Color.FromArgb(107, 114, 128);
        public static readonly Color Good = Color.FromArgb(22, 163, 74);
        public static readonly Color Warn = Color.FromArgb(217, 119, 6);
        public static readonly Color Bad = Color.FromArgb(220, 38, 38);

        public static Font Body { get { return new Font("Segoe UI", 10f); } }
        public static Font Small { get { return new Font("Segoe UI", 9f); } }
        public static Font Bold { get { return new Font("Segoe UI Semibold", 10f); } }
        public static Font Title { get { return new Font("Segoe UI Semibold", 16f); } }
        public static Font Heading { get { return new Font("Segoe UI Semibold", 12f); } }

        public static Label Label(string text, Font font = null, Color? color = null)
        {
            return new Label { UseMnemonic = false, Text = text, AutoSize = true, Font = font ?? Body, ForeColor = color ?? Text, Margin = new Padding(0, 4, 0, 4) };
        }

        /// <summary>Wrapped explanatory text (the "guided" part of every page).</summary>
        public static Label Hint(string text, int width = 640)
        {
            return new Label { UseMnemonic = false, Text = text, AutoSize = true, MaximumSize = new Size(width, 0), Font = Small, ForeColor = Muted, Margin = new Padding(0, 0, 0, 10) };
        }

        public static Button Button(string text, EventHandler onClick, bool primary = false)
        {
            var b = new Button
            {
                Text = text, AutoSize = true, FlatStyle = FlatStyle.Flat, Font = Bold, Padding = new Padding(10, 4, 10, 4),
                BackColor = primary ? Accent : Color.White, ForeColor = primary ? Color.White : Text, Cursor = Cursors.Hand, Margin = new Padding(0, 4, 8, 4),
            };
            b.FlatAppearance.BorderColor = primary ? Accent : Border;
            b.Click += onClick;
            return b;
        }

        public static CheckBox Check(string text, bool value, Action<bool> set)
        {
            var c = new CheckBox { Text = text, Checked = value, AutoSize = true, Font = Body, Margin = new Padding(0, 4, 0, 4) };
            c.CheckedChanged += (o, e) => set(c.Checked);
            return c;
        }

        public static NumericUpDown Number(int value, int min, int max, Action<int> set, int width = 90)
        {
            var n = new NumericUpDown { Minimum = min, Maximum = max, Value = Math.Max(min, Math.Min(max, value)), Width = width, Font = Body };
            n.ValueChanged += (o, e) => set((int)n.Value);
            return n;
        }

        /// <summary>A white rounded-looking card with a heading, for grouping settings.</summary>
        public static FlowLayoutPanel Card(string heading, string hint = null)
        {
            var p = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, BackColor = CardColor,
                Padding = new Padding(16, 12, 16, 12), Margin = new Padding(0, 0, 0, 14), MinimumSize = new Size(660, 0),
            };
            p.Paint += (o, e) => { using (var pen = new Pen(Border)) e.Graphics.DrawRectangle(pen, 0, 0, p.Width - 1, p.Height - 1); };
            p.Controls.Add(Label(heading, Heading));
            if (hint != null) p.Controls.Add(Hint(hint));
            return p;
        }

        /// <summary>Label + control on one line.</summary>
        public static FlowLayoutPanel Row(string label, params Control[] controls)
        {
            var r = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 2) };
            var l = Label(label); l.MinimumSize = new Size(220, 0); l.Margin = new Padding(0, 7, 8, 0);
            r.Controls.Add(l);
            foreach (var c in controls) r.Controls.Add(c);
            return r;
        }

        /// <summary>A scrolling page body.</summary>
        public static FlowLayoutPanel PageBody(string title, string hint)
        {
            var p = new FlowLayoutPanel
            {
                Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true,
                BackColor = Page, Padding = new Padding(28, 22, 28, 22),
            };
            p.Controls.Add(Label(title, Title));
            p.Controls.Add(Hint(hint, 700));
            return p;
        }

        /// <summary>Coloured dot + text, for status lines.</summary>
        public static Label Status(string text, Color color)
        {
            var l = new Label { UseMnemonic = false, AutoSize = true, Font = Body, ForeColor = Text, Margin = new Padding(0, 4, 0, 4), Text = "      " + text };
            l.Paint += (o, e) => { using (var b = new SolidBrush(color)) e.Graphics.FillEllipse(b, 2, l.Height / 2 - 5, 10, 10); };
            return l;
        }

        /// <summary>Copies text, retrying while another program holds the clipboard; never throws.</summary>
        public static bool CopyText(string text)
        {
            // other programs (clipboard sync, chat apps) can hold the clipboard for a second or more: keep trying ~3 s
            for (int i = 0; i < 3; i++)
            {
                try { Clipboard.SetDataObject(text ?? "", true, 10, 100); return true; }
                catch (Exception) { System.Threading.Thread.Sleep(50); }
            }
            var app = TrayApp.Instance;
            if (app != null) app.Notify("The clipboard is busy (another program is using it). Try Copy again in a moment.", true);
            return false;
        }    }
}
