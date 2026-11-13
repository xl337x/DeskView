// Video: every local screen streamed (one encrypted SRT listener per screen, GPU encode) and players showing the
// other computer's screens (GPU decode, frozen-picture watchdog). Same behaviour as the PowerShell DeskView.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace DeskView
{
    public static class Tools
    {
        public static string Find(string name)
        {
            var local = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ffmpeg", name + ".exe");
            if (File.Exists(local)) return local;
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try { var p = Path.Combine(dir.Trim(), name + ".exe"); if (File.Exists(p)) return p; } catch { }
            }
            var winget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WinGet\Links", name + ".exe");
            return File.Exists(winget) ? winget : null;
        }

        /// <summary>Monitors left to right (then top to bottom): screen n = the n-th one.</summary>
        public static Screen[] OrderedScreens() => Screen.AllScreens.OrderBy(s => s.Bounds.X).ThenBy(s => s.Bounds.Y).ToArray();
        public static string Short(Screen s) => s.DeviceName.Replace(@"\\.\", "");
        public static Screen ByName(string name) => OrderedScreens().FirstOrDefault(s => Short(s) == name);

        /// <summary>Wired or Wi-Fi, from the adapter that carries the default route.</summary>
        public static string LinkType()
        {
            try
            {
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    var props = nic.GetIPProperties();
                    if (!props.GatewayAddresses.Any(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !g.Address.Equals(System.Net.IPAddress.Any))) continue;
                    return nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? "WiFi" : "Wired";
                }
            }
            catch { }
            return "Wired";
        }

        /// <summary>srt:// needs IPv6 in brackets; IPv4-mapped IPv6 (::ffff:a.b.c.d) is just IPv4.</summary>
        public static string Host(string a)
        {
            var m = Regex.Match(a ?? "", @"^::ffff:(\d+\.\d+\.\d+\.\d+)$");
            if (m.Success) return m.Groups[1].Value;
            return (a ?? "").Contains(":") ? "[" + Regex.Replace(a, "%.*$", "") + "]" : a;
        }
    }

    public class Sender
    {
        public int N; public string Name; public Process P; public DateTime Started; public int Fails; public DateTime? RetryAt; public bool Gpu;
    }

    public class Player
    {
        public string Key; public Screen Screen; public int RemoteN; public Process P; public string Report;
        public Size? RemoteRes; public string RemoteRect; public bool Passive; public int Fails; public bool Legacy; public bool EverLive; public bool Announced, WarnedDown;
        public DateTime LastStart = DateTime.MinValue; public long ReportLen = -1; public DateTime ReportGrew = DateTime.Now;
        public bool Live => RemoteRes.HasValue && P != null && !P.HasExited;
    }

    public class Media
    {
        readonly AppSettings S;
        readonly string ffmpeg = Tools.Find("ffmpeg"), ffplay = Tools.Find("ffplay");
        public readonly Dictionary<int, Sender> Senders = new Dictionary<int, Sender>();
        public readonly Dictionary<string, Player> Players = new Dictionary<string, Player>();
        bool cpuPath;
        public bool HasFFmpeg => ffmpeg != null && ffplay != null;
        public event Action<string, bool> Notice;   // message, isWarning
        bool warnedLegacy;

        public Media(AppSettings settings) { S = settings; }

        static readonly Dictionary<string, int> LatencyMs = new Dictionary<string, int> { { "Wired", 40 }, { "WiFi", 150 } };
        static readonly Dictionary<string, int> BitrateMbps = new Dictionary<string, int> { { "Wired", 20 }, { "WiFi", 10 } };
        string Profile => S.Profile == "Auto" ? Tools.LinkType() : S.Profile;

        // ------------------------------------------------------------------------------------------------- encoders
        bool TestEncoder(string enc)
        {
            try
            {
                var p = Start(ffmpeg, "-hide_banner -loglevel error -f lavfi -i color=s=640x360:r=30 -frames:v 3 -pix_fmt nv12 -c:v " + enc + " -f null -", null);
                if (!p.WaitForExit(8000)) { try { p.Kill(); } catch { } return false; }   // a hung driver probe must not block
                return p.ExitCode == 0;
            }
            catch { return false; }
        }

        string Encoder()
        {
            if (!string.IsNullOrEmpty(S.Encoder)) return S.Encoder;
            S.Encoder = "libx264";
            foreach (var e in new[] { "h264_nvenc", "h264_qsv", "h264_amf", "h264_mf" }) if (TestEncoder(e)) { S.Encoder = e; break; }
            S.Save();
            return S.Encoder;
        }

        static Process Start(string exe, string args, Dictionary<string, string> env)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true };
            if (env != null) foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            var p = Process.Start(psi);
            DeskViewPortal.KillWithMe(p);
            return p;
        }

        // -------------------------------------------------------------------------------------------------- senders
        public void StopSenders() { foreach (var s in Senders.Values) Kill(s.P); Senders.Clear(); }

        void StartSender(int n, Screen screen, int dxgiIndex, Sender st)
        {
            string prof = Profile, enc = Encoder();
            int mbps = BitrateMbps[prof]; string b = mbps + "M", buf = (mbps * 500) + "k";
            string encArgs = enc switch
            {
                "h264_nvenc" => $"-c:v h264_nvenc -preset p1 -tune ull -zerolatency 1 -rc cbr -b:v {b} -maxrate {b} -bufsize {buf} -g 120 -bf 0",
                "h264_qsv" => $"-c:v h264_qsv -preset veryfast -look_ahead 0 -async_depth 1 -b:v {b} -maxrate {b} -bufsize {buf} -g 120 -bf 0",
                "h264_amf" => $"-c:v h264_amf -usage ultralowlatency -quality speed -rc cbr -b:v {b} -maxrate {b} -bufsize {buf} -g 120 -bf 0",
                "h264_mf" => $"-c:v h264_mf -hw_encoding 1 -scenario display_remoting -rate_control cbr -b:v {b} -g 120 -bf 0",
                _ => $"-c:v libx264 -preset ultrafast -tune zerolatency -b:v {b} -maxrate {b} -bufsize {buf} -g 120 -bf 0",
            };
            int port = S.VideoPort + n - 1;
            string url = $"srt://0.0.0.0:{port}?mode=listener&latency={LatencyMs[prof] * 1000}&pkt_size=1316&transtype=live&passphrase={S.VideoKey()}&pbkeylen=32";
            // Frames stay on the GPU when the encoder can take them (~3x less CPU); CPU path if that keeps failing.
            string cap = $"ddagrab=output_idx={dxgiIndex}:framerate=60:draw_mouse=1", chain, pix = "";
            if (!cpuPath && enc == "h264_qsv") chain = cap + ",hwmap=derive_device=qsv,format=qsv";
            else if (!cpuPath && (enc == "h264_nvenc" || enc == "h264_amf")) chain = cap;
            else { chain = cap + ",hwdownload,format=bgra"; pix = "-pix_fmt nv12"; }
            st.Gpu = !chain.Contains("hwdownload");
            var r = screen.Bounds;
            // The stream says which screen it is and where it sits, so the viewer maps its portal onto it.
            string meta = $"DeskView|{n}|{r.X},{r.Y},{r.Width},{r.Height}";
            st.P = Start(ffmpeg, $"-hide_banner -loglevel error -f lavfi -i {chain} {pix} {encArgs} -metadata service_name={meta} -flush_packets 1 -f mpegts -mpegts_flags resend_headers \"{url}\"", null);
            st.Started = DateTime.Now; st.Name = Tools.Short(screen);
        }

        /// <summary>One listener per screen, kept alive with back-off when it keeps failing.</summary>
        /// <summary>DESKVIEW_NOMEDIA=1: no video processes at all (tests of everything else).</summary>
        public static readonly bool NoMedia = Environment.GetEnvironmentVariable("DESKVIEW_NOMEDIA") == "1";

        public void ServiceSenders()
        {
            if (ffmpeg == null || NoMedia) return;
            var outputs = DeskViewDxgi.DdagrabOutputs();
            var screens = Tools.OrderedScreens();
            var wanted = new HashSet<int>();
            for (int i = 0; i < screens.Length; i++)
            {
                int n = i + 1, idx = Array.IndexOf(outputs, Tools.Short(screens[i]));
                if (idx < 0) continue;
                wanted.Add(n);
                if (!Senders.TryGetValue(n, out var st)) Senders[n] = st = new Sender { N = n };
                if (st.P != null && !st.P.HasExited) continue;
                if (st.P != null) { if ((DateTime.Now - st.Started).TotalSeconds < 3) st.Fails++; else st.Fails = 0; }
                if (st.Fails >= 2 && st.Gpu) { cpuPath = true; st.Fails = 0; }
                st.P = null;
                if (st.RetryAt == null) st.RetryAt = DateTime.Now.AddSeconds(st.Fails > 0 ? Math.Min(30, 0.5 * Math.Pow(2, st.Fails)) : 0);
                if (DateTime.Now >= st.RetryAt) { st.RetryAt = null; StartSender(n, screens[i], idx, st); }
            }
            foreach (var n in Senders.Keys.Where(k => !wanted.Contains(k)).ToList()) { Kill(Senders[n].P); Senders.Remove(n); }
        }

        // -------------------------------------------------------------------------------------------------- players
        public void StopPlayers() { foreach (var p in Players.Values) Kill(p.P); Players.Clear(); }
        public void StopPlayer(Player p) { Kill(p.P); p.P = null; }

        public void SyncPlayers(IEnumerable<(string key, Screen screen, int n)> wanted, string peer)
        {
            var w = wanted.ToList();
            foreach (var k in Players.Keys.ToList())
            {
                var x = w.FirstOrDefault(t => t.key == k);
                if (x.key == null || x.n != Players[k].RemoteN || x.screen.Bounds != Players[k].Screen.Bounds) { Kill(Players[k].P); Players.Remove(k); }
            }
            foreach (var x in w)
                if (!Players.ContainsKey(x.key))
                {
                    var pl = new Player { Key = x.key, Screen = x.screen, RemoteN = x.n, Report = Path.Combine(Path.GetTempPath(), "deskview-ffplay-" + Regex.Replace(x.key, @"[^\w]", "") + ".log") };
                    Players[x.key] = pl; StartPlayer(pl, peer);
                }
        }

        void StartPlayer(Player pl, string peer)
        {
            Kill(pl.P); pl.P = null;
            if (NoMedia) return;
            if (ffplay == null || string.IsNullOrEmpty(peer)) return;
            string prof = Profile; var r = pl.Screen.Bounds;
            int port = S.VideoPort + pl.RemoteN - 1;
            // An old DeskView streams one screen unencrypted: after two failed encrypted attempts, alternate.
            pl.Legacy = pl.Fails >= 2 && pl.Fails % 2 == 1;
            string enc = pl.Legacy ? "" : $"&passphrase={S.VideoKey()}&pbkeylen=32";
            string url = $"srt://{Tools.Host(peer)}:{port}?mode=caller&latency={LatencyMs[prof] * 1000}&transtype=live&connect_timeout=3000{enc}";
            string vf = S.Picture == "Stretch" ? $"-vf scale={r.Width}:{r.Height} " : "";
            string hw = pl.Fails < 4 ? "-hwaccel d3d11va " : "";   // GPU decode: ~3.5x less CPU
            try { File.Delete(pl.Report); } catch { }
            var env = new Dictionary<string, string>
            {
                ["SDL_WINDOWS_DPI_AWARENESS"] = "permonitorv2",
                ["FFREPORT"] = "file=" + pl.Report.Replace('\\', '/').Replace(":", "\\:") + ":level=32",
            };
            pl.P = Start(ffplay, $"-hide_banner -loglevel error {hw}-fflags nobuffer+discardcorrupt -flags low_delay -framedrop -sync ext -probesize 32768 -analyzeduration 0 -an -noborder -alwaysontop {vf}-left {r.X} -top {r.Y} -x {r.Width} -y {r.Height} -window_title DeskView \"{url}\"", env);
            pl.LastStart = DateTime.Now; pl.ReportLen = -1; pl.ReportGrew = DateTime.Now; pl.Passive = false; pl.RemoteRes = null;
        }

        /// <summary>Keep players alive; returns true if what is shown changed (resolution / which screen).</summary>
        public bool ServicePlayers(string peer)
        {
            bool changed = false;
            foreach (var pl in Players.Values)
            {
                if (pl.P == null || pl.P.HasExited)
                {
                    if (pl.P != null && pl.RemoteRes == null)
                    {
                        pl.Fails++;
                        // say so instead of leaving an empty monitor: the other computer is not sending this screen
                        if (pl.Fails == 3 && !pl.WarnedDown) { pl.WarnedDown = true; Notice?.Invoke($"No picture from {S.RemoteName} screen {pl.RemoteN} yet. Make sure DeskView is running there (same pairing code) and it is on the network.", true); }
                    }
                    pl.P = null;
                    if ((DateTime.Now - pl.LastStart).TotalSeconds >= 2) StartPlayer(pl, peer);
                    continue;
                }
                if (!pl.Passive)
                {
                    pl.P.Refresh();
                    // out of Alt+Tab, never takes focus (a stray Esc would close it), really on top
                    if (pl.P.MainWindowHandle != IntPtr.Zero) { DeskViewPortal.MakePassive(pl.P.MainWindowHandle); pl.Passive = true; changed = true; }
                }
                long len = File.Exists(pl.Report) ? new FileInfo(pl.Report).Length : 0;
                if (len != pl.ReportLen) { pl.ReportLen = len; pl.ReportGrew = DateTime.Now; }
                else if (pl.RemoteRes != null && (DateTime.Now - pl.ReportGrew).TotalSeconds > 6)
                {
                    // the picture froze (stream gone, ffplay keeps the last frame): reconnect
                    pl.ReportGrew = DateTime.Now; Kill(pl.P); pl.P = null; continue;
                }
                var info = ReadInfo(pl.Report);
                if (info != null && (pl.RemoteRes != info.Value.size || pl.RemoteRect != info.Value.rect))
                {
                    pl.RemoteRes = info.Value.size; pl.RemoteRect = info.Value.rect; pl.Fails = 0; pl.EverLive = true; changed = true;
                    if (!pl.Announced) { pl.Announced = true; pl.WarnedDown = false; Notice?.Invoke($"{S.RemoteName} screen {pl.RemoteN} is now on {pl.Key} ({info.Value.size.Width}x{info.Value.size.Height})", false); }
                    if (pl.Legacy && !warnedLegacy) { warnedLegacy = true; Notice?.Invoke("The other computer runs an old DeskView: its picture is not encrypted. Update it.", true); }
                }
            }
            return changed;
        }

        static (Size size, string rect)? ReadInfo(string report)
        {
            try
            {
                string text;
                using (var fs = new FileStream(report, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) text = new StreamReader(fs).ReadToEnd();
                var m = Regex.Match(text, @"Video: [^\r\n]*?, (\d{2,5})x(\d{2,5})[ ,\[]");
                if (!m.Success) return null;
                var r = Regex.Match(text, @"DeskView\|\d+\|(-?\d+),(-?\d+),(\d+),(\d+)");
                return (new Size(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value)), r.Success ? $"{r.Groups[1].Value},{r.Groups[2].Value},{r.Groups[3].Value},{r.Groups[4].Value}" : null);
            }
            catch { return null; }
        }

        /// <summary>Where the picture sits on its monitor (Fit adds bars when the shapes differ).</summary>
        public Rectangle PictureRect(Player pl)
        {
            var b = pl.Screen.Bounds;
            if (pl.RemoteRes == null || S.Picture == "Stretch") return b;
            var rr = pl.RemoteRes.Value;
            double scale = Math.Min((double)b.Width / rr.Width, (double)b.Height / rr.Height);
            int w = (int)Math.Round(rr.Width * scale), h = (int)Math.Round(rr.Height * scale);
            return new Rectangle(b.X + (b.Width - w) / 2, b.Y + (b.Height - h) / 2, w, h);
        }

        static void Kill(Process p) { if (p != null) { try { if (!p.HasExited) p.Kill(); } catch { } } }
    }
}
