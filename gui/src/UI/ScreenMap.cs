// The visual screen map: this computer's monitors drawn to scale. On the server, click a monitor to choose which
// of the other computer's screens it shows; monitors showing one are drawn in the accent colour with what they show.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

namespace DeskView.UI
{
    public class ScreenMap : Control
    {
        readonly Engine engine;
        readonly Dictionary<string, RectangleF> hit = new Dictionary<string, RectangleF>();
        string hover;

        public ScreenMap(Engine e)
        {
            engine = e;
            DoubleBuffered = true; ResizeRedraw = true;
            Size = new Size(660, 260); BackColor = Theme.CardColor; Cursor = Cursors.Hand;
            MouseMove += (o, ev) => { var h = HitTest(ev.Location); if (h != hover) { hover = h; Invalidate(); } };
            MouseLeave += (o, ev) => { hover = null; Invalidate(); };
            MouseClick += (o, ev) => { var h = HitTest(ev.Location); if (h != null) ShowMenu(h, ev.Location); };
        }

        string HitTest(Point p) => hit.FirstOrDefault(kv => kv.Value.Contains(p)).Key;

        void ShowMenu(string monitor, Point at)
        {
            if (engine.S.Role != Role.Server) return;
            var menu = new ContextMenuStrip { Font = Theme.Body };
            int cur = engine.S.Screens.TryGetValue(monitor, out var n) ? n : 0;
            var own = new ToolStripMenuItem("Its own desktop") { Checked = cur == 0 };
            own.Click += (o, e) => { engine.SetScreen(monitor, 0); Invalidate(); };
            menu.Items.Add(own);
            menu.Items.Add(new ToolStripSeparator());
            var name = string.IsNullOrEmpty(engine.S.RemoteName) ? "the other computer" : engine.S.RemoteName;
            for (int k = 1; k <= 4; k++)
            {
                int kk = k;
                var it = new ToolStripMenuItem($"Show {name}'s screen {k}" + (k == 1 ? "  (its main screen)" : "")) { Checked = cur == k };
                it.Click += (o, e) => { engine.SetScreen(monitor, kk); Invalidate(); };
                menu.Items.Add(it);
            }
            menu.Show(this, at);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            hit.Clear();
            var screens = Tools.OrderedScreens();
            if (screens.Length == 0) return;
            var all = screens.Select(s => s.Bounds).Aggregate(Rectangle.Union);
            float pad = 16, scale = Math.Min((Width - 2 * pad) / all.Width, (Height - 2 * pad) / all.Height);
            float ox = (Width - all.Width * scale) / 2, oy = (Height - all.Height * scale) / 2;
            int num = 0;
            foreach (var s in screens)
            {
                num++;
                var name = Tools.Short(s);
                var r = new RectangleF(ox + (s.Bounds.X - all.X) * scale + 4, oy + (s.Bounds.Y - all.Y) * scale + 4, s.Bounds.Width * scale - 8, s.Bounds.Height * scale - 8);
                hit[name] = r;
                int shows = engine.S.Role == Role.Server && engine.S.Screens.TryGetValue(name, out var n) ? n : 0;
                engine.Media.Players.TryGetValue(name, out var pl);
                var fill = shows > 0 ? Theme.Accent : Color.FromArgb(243, 244, 246);
                if (hover == name) fill = shows > 0 ? Theme.AccentDark : Color.FromArgb(229, 231, 235);
                using (var path = Rounded(r, 8)) using (var b = new SolidBrush(fill)) using (var pen = new Pen(shows > 0 ? Theme.AccentDark : Theme.Border, 2))
                { g.FillPath(b, path); g.DrawPath(pen, path); }
                var fg = shows > 0 ? Color.White : Theme.Text;
                string line1 = $"{num}. {name}" + (s.Primary ? " (main)" : "");
                string line2 = shows > 0
                    ? $"{(string.IsNullOrEmpty(engine.S.RemoteName) ? "other" : engine.S.RemoteName)} - screen {shows}" + (pl != null && pl.Live ? $"\n{pl.RemoteRes.Value.Width}x{pl.RemoteRes.Value.Height}  live" : "\nconnecting...")
                    : "own desktop";
                using (var f1 = new Font("Segoe UI Semibold", 10f)) using (var f2 = new Font("Segoe UI", 9f)) using (var bfg = new SolidBrush(fg))
                {
                    // title at the top, what it shows in the middle
                    g.DrawString(line1, f1, bfg, new RectangleF(r.X, r.Y + 6, r.Width, 22), new StringFormat { Alignment = StringAlignment.Center });
                    g.DrawString(line2, f2, bfg, new RectangleF(r.X, r.Y + 24, r.Width, r.Height - 28), new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
                }
            }
        }

        static GraphicsPath Rounded(RectangleF r, float radius)
        {
            var p = new GraphicsPath(); float d = radius * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }
    }
}
