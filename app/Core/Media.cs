// Video: every local screen streamed (one encrypted SRT listener per screen, GPU encode) and players showing the
// other computer's screens (a stalled stream ends its player, which is restarted; pictures held on top by DeskView). Same behaviour as the PowerShell DeskView.
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
        public static string OppositeSide(string side) { return side == "left" ? "right" : side == "right" ? "left" : side == "top" ? "bottom" : side == "bottom" ? "top" : ""; }

        public static string Find(string name)
        {
            // the pinned, checksum-checked build that setup puts next to the app first (the app runs inside powershell.exe,
            // so the process's own folder is PowerShell's), then one on PATH, then winget's
            foreach (var dir in new[] { Program.AppDir, AppDomain.CurrentDomain.BaseDirectory })
            {
                if (string.IsNullOrEmpty(dir)) continue;
                var local = Path.Combine(dir, "ffmpeg", name + ".exe");
                if (File.Exists(local)) return local;
            }
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try { var p = Path.Combine(dir.Trim(), name + ".exe"); if (File.Exists(p)) return p; } catch { }
            }
            var winget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WinGet\Links", name + ".exe");
            return File.Exists(winget) ? winget : null;
        }

        /// <summary>Monitors left to right (then top to bottom): screen n = the n-th one.</summary>
        public static Screen[] OrderedScreens() { return Screen.AllScreens.OrderBy(s => s.Bounds.X).ThenBy(s => s.Bounds.Y).ToArray(); }
        public static string Short(Screen s) { return s.DeviceName.Replace(@"\\.\", ""); }
        /// <summary>The order this computer's screens are offered to the other computer: the main screen is always
        /// screen 1 (even when extra screens sit to its left), the others follow left to right.</summary>
        public static Screen[] SharedScreens() { return Screen.AllScreens.OrderBy(s => s.Primary ? 0 : 1).ThenBy(s => s.Bounds.X).ThenBy(s => s.Bounds.Y).ToArray(); }
        public static Screen ByName(string name) { return OrderedScreens().FirstOrDefault(s => Short(s) == name); }

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
        public int N; public string Name; public Process P; public DateTime Started; public int Fails; public DateTime? RetryAt; public bool Gpu; public string Report;
    }

    public class Player
    {
        public string Key; public Screen Screen; public int RemoteN; public Process P; public string Report;
        public Size? RemoteRes; public string RemoteRect; public bool Passive, WasLive; public DeskViewPictureHost Host; public int AdoptFails; public int Fails; public bool EverLive; public bool Announced, WarnedDown;
        public DateTime LastStart = DateTime.MinValue, ShownAt = DateTime.MinValue;
        public bool Live { get { return RemoteRes.HasValue && P != null && !P.HasExited; } }
    }

    public class Media
    {
        readonly AppSettings S;
        readonly string ffmpeg = Tools.Find("ffmpeg"), ffplay = Tools.Find("ffplay");
        public readonly Dictionary<int, Sender> Senders = new Dictionary<int, Sender>();
        public readonly Dictionary<string, Player> Players = new Dictionary<string, Player>();
        bool cpuPath;
        public bool HasFFmpeg { get { return ffmpeg != null && ffplay != null; } }
        public event Action<string, bool> Notice;   // message, isWarning

        public Media(AppSettings settings) { S = settings; }

        // SRT latency = how long a lost packet may be re-sent before its frame is due: a few round trips. Wired LAN
        // round trips are ~1 ms (40 ms is plenty); Wi-Fi has bursts of loss and 5-20 ms round trips (150 ms - and it
        // adds that much delay: see docs/OPEN-ISSUES.md about trying less). Bitrates: enough for sharp text at
        // 1080p60 with a hardware encoder; Wi-Fi halved so the link keeps headroom. Both ends use the larger latency.
        static readonly Dictionary<string, int> LatencyMs = new Dictionary<string, int> { { "Wired", 40 }, { "WiFi", 150 } };
        static readonly Dictionary<string, int> BitrateMbps = new Dictionary<string, int> { { "Wired", 20 }, { "WiFi", 10 } };
        string Profile { get { return S.Profile == "Auto" ? Tools.LinkType() : S.Profile; } }

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

        // Which run of a report file may still write to it: a run that ended (killed, restarted) can deliver its last
        // lines late, and they must not land in the report of the run that replaced it.
        static readonly Dictionary<string, int> reportRun = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        /// <summary>Starts ffmpeg/ffplay and writes what it reports (info level, like FFREPORT did) into "report", with
        /// every video key removed. FFREPORT is not used: it writes the whole command line - the SRT address with the
        /// passphrase - into the file, and ffmpeg also prints that address in its own error messages.</summary>
        static Process StartReported(string exe, string args, Dictionary<string, string> env, string report)
        {
            int run;
            lock (reportRun) { int last; reportRun.TryGetValue(report, out last); run = last + 1; reportRun[report] = run; }
            try { File.Delete(report); } catch { }
            var psi = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardError = true, StandardErrorEncoding = System.Text.Encoding.UTF8
            };
            if (env != null) foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            psi.EnvironmentVariables.Remove("FFREPORT");
            var p = new Process { StartInfo = psi };
            // Always read: a player whose error output is not drained would block once the pipe is full.
            p.ErrorDataReceived += (o, e) =>
            {
                if (e.Data == null) return;
                lock (reportRun)
                {
                    int now; if (!reportRun.TryGetValue(report, out now) || now != run) return;
                    // Few lines (-nostats); opened per line so the file can be read, deleted and replaced at any time.
                    try { File.AppendAllText(report, Redact(e.Data) + "\r\n"); } catch { }
                }
            };
            p.Start();
            DeskViewPortal.KillWithMe(p);
            p.BeginErrorReadLine();
            return p;
        }

        /// <summary>Removes video keys from a line of text (an SRT address or option): "passphrase=***".</summary>
        public static string Redact(string line)
        {
            if (string.IsNullOrEmpty(line)) return line;
            return Regex.Replace(line, @"(passphrase[=\s:]+)[^&\s""']+", "$1***", RegexOptions.IgnoreCase);
        }

        // -------------------------------------------------------------------------------------------------- senders
        public void StopSenders() { foreach (var s in Senders.Values) Kill(s.P); Senders.Clear(); }

        void StartSender(int n, Screen screen, DeskViewDxgi.Output output, Sender st)
        {
            string prof = Profile, enc = Encoder();
            int mbps = BitrateMbps[prof]; string b = mbps + "M", buf = (mbps * 500) + "k";
            // A viewer that joins (a monitor switched to this screen, smart screens, a reconnect) shows nothing until the
            // next key frame (the player drops what it reads before it knows the picture size): one every 0.5 s,
            // on any network, at a small bitrate cost.
            string gop = "30";
            string encArgs;
            switch (enc)
            {
                case "h264_nvenc": encArgs = "-c:v h264_nvenc -preset p1 -tune ull -zerolatency 1 -rc cbr -b:v " + b + " -maxrate " + b + " -bufsize " + buf + " -g " + gop + " -bf 0"; break;
                case "h264_qsv": encArgs = "-c:v h264_qsv -preset veryfast -look_ahead 0 -async_depth 1 -b:v " + b + " -maxrate " + b + " -bufsize " + buf + " -g " + gop + " -bf 0"; break;
                case "h264_amf": encArgs = "-c:v h264_amf -usage ultralowlatency -quality speed -rc cbr -b:v " + b + " -maxrate " + b + " -bufsize " + buf + " -g " + gop + " -bf 0"; break;
                case "h264_mf": encArgs = "-c:v h264_mf -hw_encoding 1 -scenario display_remoting -rate_control cbr -b:v " + b + " -g " + gop + " -bf 0"; break;
                default: encArgs = "-c:v libx264 -preset ultrafast -tune zerolatency -b:v " + b + " -maxrate " + b + " -bufsize " + buf + " -g " + gop + " -bf 0"; break;
            }
            int port = S.VideoPort + n - 1;
            // pkt_size 1316 = 7 MPEG-TS packets: fits one UDP datagram without fragmenting on any normal network
            string url = "srt://0.0.0.0:" + port + "?mode=listener&latency=" + (LatencyMs[prof] * 1000) + "&pkt_size=1316&transtype=live&passphrase=" + S.VideoKey() + "&pbkeylen=32";
            // Frames stay on the GPU when the encoder can take them (~3x less CPU); CPU path if that keeps failing.
            string cap = "ddagrab=output_idx=" + output.Index + ":framerate=60:draw_mouse=1", chain, pix = "", device = "";
            if (output.Adapter != 0)
            {
                // A screen on another graphics adapter (a second GPU, or a virtual screen rendered there): capture it
                // with a device on that adapter and encode from memory - works with any mix of adapters and encoders.
                device = "-init_hw_device d3d11va=dv:" + output.Adapter + " -filter_hw_device dv ";
                chain = cap + ",hwdownload,format=bgra"; pix = "-pix_fmt nv12";
            }
            else if (!cpuPath && enc == "h264_qsv") chain = cap + ",hwmap=derive_device=qsv,format=qsv";
            else if (!cpuPath && (enc == "h264_nvenc" || enc == "h264_amf")) chain = cap;
            else { chain = cap + ",hwdownload,format=bgra"; pix = "-pix_fmt nv12"; }
            st.Gpu = !chain.Contains("hwdownload");
            var r = screen.Bounds;
            // The stream says which screen it is and where it sits, so the viewer maps its portal onto it.
            string meta = "DeskView|" + n + "|" + r.X + "," + r.Y + "," + r.Width + "," + r.Height;
            // a small report: tells afterwards whether a viewer was connected (then exiting is normal, not a failure)
            st.Report = Path.Combine(Path.GetTempPath(), "deskview-ffmpeg-screen" + n + ".log");
            // -flush_packets 1: every frame leaves at once (no muxer buffering); resend_headers: stream info goes out
            // again with key frames, so a viewer joining mid-stream can start. -loglevel info: the report needs the
            // "Output #0" line (a viewer connected); written by us without the key (StartReported).
            st.P = StartReported(ffmpeg, "-hide_banner -loglevel info -nostats " + device + "-f lavfi -i " + chain + " " + pix + " " + encArgs + " -metadata service_name=" + meta + " -flush_packets 1 -f mpegts -mpegts_flags resend_headers \"" + url + "\"", null, st.Report);
            st.Started = DateTime.Now; st.Name = Tools.Short(screen);
        }

        /// <summary>DESKVIEW_NOMEDIA=1: no video processes at all (tests of everything else).</summary>
        public static readonly bool NoMedia = Environment.GetEnvironmentVariable("DESKVIEW_NOMEDIA") == "1";

        public void ServiceSenders()
        {
            if (ffmpeg == null || NoMedia) return;
            var outputs = DeskViewDxgi.AllOutputs();   // every screen on every graphics adapter
            var screens = Tools.SharedScreens();
            var wanted = new HashSet<int>();
            for (int i = 0; i < screens.Length; i++)
            {
                int n = i + 1;
                var name = Tools.Short(screens[i]);
                var output = outputs.FirstOrDefault(o => o.Name == name);
                if (output == null) continue;
                wanted.Add(n);
                Sender st;
                if (!Senders.TryGetValue(n, out st)) Senders[n] = st = new Sender { N = n };
                if (st.P != null && !st.P.HasExited) continue;
                if (st.P != null)
                {
                    // A viewer came and went (switched its monitor away, smart screens gave it back): the listener simply
                    // ends - start the next one at once. Only quick exits without any viewer are failures (back-off).
                    if (ServedViewer(st.Report) || (DateTime.Now - st.Started).TotalSeconds >= 3) st.Fails = 0; else st.Fails++;
                }
                if (st.Fails >= 2 && st.Gpu) { cpuPath = true; st.Fails = 0; }
                st.P = null;
                if (st.RetryAt == null) st.RetryAt = DateTime.Now.AddSeconds(st.Fails > 0 ? Math.Min(30, 0.5 * Math.Pow(2, st.Fails)) : 0);
                if (DateTime.Now >= st.RetryAt) { st.RetryAt = null; StartSender(n, screens[i], output, st); }
            }
            foreach (var n in Senders.Keys.Where(k => !wanted.Contains(k)).ToList()) { Kill(Senders[n].P); Senders.Remove(n); }
        }

        /// <summary>The viewer of screen n went away (the other computer said so): a listener still holding on to that
        /// vanished viewer would turn the next one away for ~5 s, so a fresh one is started at once.</summary>
        public void RestartSender(int n)
        {
            Sender st;
            if (!Senders.TryGetValue(n, out st) || st.P == null) return;
            Kill(st.P); st.P = null; st.Fails = 0; st.RetryAt = null;
        }

        /// <summary>A picture of the other computer's screen n stopped (closed, or its player died): the other computer
        /// should restart that screen's listener.</summary>
        public event Action<int> ViewerGone;
        int reportSeq;
        /// <summary>Where the other computer's screen n is and how big (it tells us over the link), or null.</summary>
        public Func<int, Rectangle?> RemoteScreen;
        void OnViewerGone(Player pl) { if (!pl.EverLive) return; var h = ViewerGone; if (h != null) h(pl.RemoteN); }

        // -------------------------------------------------------------------------------------------------- players
        public void StopPlayers() { foreach (var p in Players.Values) StopPlayer(p); Players.Clear(); }
        public void StopPlayer(Player p)
        {
            // the player first, then the window holding its picture (never destroy a window that still has its child)
            if (p.P != null) { Kill(p.P); try { p.P.WaitForExit(500); } catch { } OnViewerGone(p); }
            try { File.Delete(p.Report); } catch { }
            p.P = null;
            if (p.Host != null) { p.Host.Release(); p.Host.Close(); p.Host = null; }
        }

        public void SyncPlayers(IEnumerable<Tuple<string, Screen, int>> wanted, string peer)
        {
            var w = wanted.ToList();
            foreach (var k in Players.Keys.ToList())
            {
                var x = w.FirstOrDefault(t => t.Item1 == k);
                if (x != null && x.Item3 == Players[k].RemoteN && x.Item2.Bounds == Players[k].Screen.Bounds) continue;
                var pl = Players[k]; Players.Remove(k);
                // The same screen moved to another monitor: move the running picture there instead of reconnecting
                // (a reconnect is a second or more of black). Stretch scales to the old monitor's size: reconnect.
                var to = w.FirstOrDefault(t => t.Item3 == pl.RemoteN && !Players.ContainsKey(t.Item1) && (x == null || x.Item3 != pl.RemoteN));
                if (to != null && S.Picture != "Stretch" && pl.P != null && !pl.P.HasExited && pl.Host != null && pl.Host.Holding)
                {
                    pl.Key = to.Item1; pl.Screen = to.Item2; pl.Host.Bounds = to.Item2.Bounds; pl.Announced = false;
                    Players[to.Item1] = pl;
                    continue;
                }
                StopPlayer(pl);
            }
            foreach (var x in w)
                if (!Players.ContainsKey(x.Item1))
                {
                    // its own report file: a picture moved to another monitor keeps its file, which must never be shared
                    var pl = new Player { Key = x.Item1, Screen = x.Item2, RemoteN = x.Item3, Report = Path.Combine(Path.GetTempPath(), "deskview-ffplay-" + Regex.Replace(x.Item1, @"[^\w]", "") + "-" + (++reportSeq) + ".log") };
                    Players[x.Item1] = pl; StartPlayer(pl, peer);
                }
        }

        void StartPlayer(Player pl, string peer)
        {
            Kill(pl.P); pl.P = null;
            if (pl.Host != null) pl.Host.Release();
            if (NoMedia) return;
            if (ffplay == null || string.IsNullOrEmpty(peer)) return;
            string prof = Profile; var r = pl.Screen.Bounds;
            int port = S.VideoPort + pl.RemoteN - 1;
            // Always encrypted (an unencrypted fallback for the old pre-app script version was removed: nobody runs it,
            // and it would have let a picture travel unencrypted).
            string url = "srt://" + Tools.Host(peer) + ":" + port + "?mode=caller&latency=" + (LatencyMs[prof] * 1000) + "&transtype=live&connect_timeout=3000&passphrase=" + S.VideoKey() + "&pbkeylen=32";
            // Frames 1 ms apart: the player is always "behind", shows the newest frame and drops older ones, so any lag
            // (start-up, a network or CPU hiccup) drains by itself. Measured on the server (loopback, key-to-picture):
            // ~400 ms before, 150-190 ms with this; after a 1.5 s stall back to normal within ~2 s.
            string vf = "-vf setpts=N*0.001/TB" + (S.Picture == "Stretch" ? ",scale=" + r.Width + ":" + r.Height : "") + " ";
            // a stream that stops sending (the other computer asleep, network gone) ends the player after 3 s instead of
            // leaving a frozen picture: the restart below takes over
            url += "&timeout=3000000";
            var env = new Dictionary<string, string> { { "SDL_WINDOWS_DPI_AWARENESS", "permonitorv2" } };
            // Probe: 32 KB and no analysis - the picture size is known from the first key frame, and every byte probed
            // is time before the first picture. After two failed starts of a screen that never showed a picture, a
            // longer probe (a sender that starts slowly).
            bool bigProbe = pl.Fails >= 2 && !pl.EverLive;
            string probe = bigProbe ? "-probesize 2000000 -analyzeduration 3000000" : "-probesize 32768 -analyzeduration 0";
            // nobuffer: the player schedules frames from the first one and never catches up (it doesn't treat srt:// as
            // live), so packets read while probing would become a lasting lag; dropping them costs the first key frame
            // (the next is <= 0.5 s away). discardcorrupt: a damaged frame is skipped instead of shown as garbage.
            // -flags low_delay: no decoder reordering delay (the sender uses no B-frames). -framedrop with
            // -sync ext: frames that are late against the clock are dropped instead of slowing the picture down.
            // No "-hwaccel d3d11va": this player's renderer can't use it (decoding stayed on the CPU anyway) and it
            // made the picture start later. -nostats: the report holds only what is read from it.
            string flags = "-fflags nobuffer+discardcorrupt ";
            pl.P = StartReported(ffplay, "-hide_banner -loglevel info -nostats -autoexit " + flags + "-flags low_delay -framedrop -sync ext " + probe + " -an -noborder " + vf + "-left " + r.X + " -top " + r.Y + " -x " + r.Width + " -y " + r.Height + " -window_title DeskView \"" + url + "\"", env, pl.Report);
            pl.LastStart = DateTime.Now; pl.Passive = false; pl.RemoteRes = null;
        }

        /// <summary>Keep players alive; returns true if what is shown changed (a picture appeared or went away, its
        /// resolution, which screen) - every such change must reach the hand-over areas, drop zones and guide.</summary>
        public bool ServicePlayers(string peer)
        {
            bool changed = false;
            foreach (var pl in Players.Values)
            {
                if (ServicePlayer(pl, peer)) changed = true;
                bool now = pl.Live;   // compared with the last tick: a player can also die between ticks
                if (now != pl.WasLive) { pl.WasLive = now; changed = true; }
            }
            return changed;
        }

        bool ServicePlayer(Player pl, string peer)
        {
            if (pl.P == null || pl.P.HasExited)
            {
                if (pl.P != null)
                {
                    int code = -1; try { code = pl.P.ExitCode; } catch { }
                    Log.Write(string.Format("{0}: player ended (exit {1}, {2}) - starting it again", pl.Key, code, pl.RemoteRes == null ? "no picture yet" : "picture was on"));
                    // 0: the stream ended (the other side is already starting over); anything else: the player died
                    // and the other side may still be waiting for it
                    if (code != 0) OnViewerGone(pl);
                }
                if (pl.P != null && pl.RemoteRes == null)
                {
                    pl.Fails++;
                    // say so instead of leaving an empty monitor: the other computer is not sending this screen
                    if (pl.Fails == 3 && !pl.WarnedDown) { pl.WarnedDown = true; var n = Notice; if (n != null) n("No picture from " + S.RemoteName + " screen " + pl.RemoteN + " yet. Make sure DeskView is running there (same pairing code) and it is on the network.", true); }
                }
                pl.P = null; pl.RemoteRes = null;
                if (pl.Host != null) pl.Host.Release();
                // again soon (the other side is usually back within a second), then less often
                double wait = pl.Fails <= 1 ? 0.5 : pl.Fails == 2 ? 1 : 2;
                if ((DateTime.Now - pl.LastStart).TotalSeconds >= wait) StartPlayer(pl, peer);
                return false;
            }
            bool changed = false;
            if (!pl.Passive)
            {
                // The picture goes inside a window of ours that is always in front and never takes focus (out of
                // Alt+Tab; a stray Esc can't close it). The player's window is found by its title: its "main
                // window" is a hidden helper.
                var w = DeskViewPortal.FindVisibleWindow(pl.P.Id, "DeskView");
                if (w != IntPtr.Zero)
                {
                    if (pl.AdoptFails < 2)
                    {
                        if (pl.Host == null) pl.Host = new DeskViewPictureHost(pl.Screen.Bounds);
                        if (pl.Host.Adopt(w)) { pl.Passive = true; pl.ShownAt = DateTime.Now; changed = true; }
                        else if (++pl.AdoptFails >= 2) Log.Write("could not hold the picture for " + pl.Key + " in DeskView's own window - showing it as is");
                    }
                    else { DeskViewPortal.MakePassive(w); pl.Passive = true; pl.ShownAt = DateTime.Now; changed = true; }   // fallback: the player's own window
                }
            }
            else if (pl.Host != null && pl.AdoptFails < 2 && !pl.Host.Holding)
            {
                // the picture window is gone or the player hangs: start it again
                Log.Write(pl.Key + ": picture window gone or not responding - restarting the player");
                Kill(pl.P); OnViewerGone(pl); pl.P = null; pl.RemoteRes = null; pl.Host.Release(); return true;
            }
            if (pl.RemoteRes == null)
            {
                // The picture is there once the player shows its window (it does at the first frame). Its size and
                // position on the other computer: from the player's report when it has them, else as the other
                // computer told us over the link; an older DeskView that tells nothing: this monitor's size.
                var info = ReadInfo(pl.Report);
                if (info == null && pl.Passive)
                {
                    var r = RemoteScreen != null ? RemoteScreen(pl.RemoteN) : null;
                    if (r.HasValue) info = new Info { size = r.Value.Size, rect = r.Value.X + "," + r.Value.Y + "," + r.Value.Width + "," + r.Value.Height };
                    else if ((DateTime.Now - pl.ShownAt).TotalSeconds > 2) info = new Info { size = pl.Screen.Bounds.Size, rect = null };
                }
                if (info != null)
                {
                    pl.RemoteRes = info.size; pl.RemoteRect = info.rect; pl.Fails = 0; pl.EverLive = true; changed = true;
                    if (!pl.Announced) { pl.Announced = true; pl.WarnedDown = false; var n = Notice; if (n != null) n(S.RemoteName + " screen " + pl.RemoteN + " is now on " + pl.Key + " (" + info.size.Width + "x" + info.size.Height + ")", false); }
                }
                else if ((DateTime.Now - pl.LastStart).TotalSeconds > 12)
                {
                    // connected (or still trying) but no picture for 12 s: count it as a failed attempt and try again
                    Log.Write(pl.Key + ": no picture after 12 s (" + (File.Exists(pl.Report) ? new FileInfo(pl.Report).Length + " bytes of report" : "no report") + ") - trying again");
                    pl.Fails++; Kill(pl.P); pl.P = null; if (pl.Host != null) pl.Host.Release(); return true;
                }
            }
            return changed;
        }

        class Info { public Size size; public string rect; }

        static Info ReadInfo(string report)
        {
            try
            {
                string text;
                using (var fs = new FileStream(report, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) text = new StreamReader(fs).ReadToEnd();
                var m = Regex.Match(text, @"Video: [^\r\n]*?, (\d{2,5})x(\d{2,5})[ ,\[]");
                if (!m.Success) return null;
                var r = Regex.Match(text, @"DeskView\|\d+\|(-?\d+),(-?\d+),(\d+),(\d+)");
                return new Info { size = new Size(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value)), rect = r.Success ? r.Groups[1].Value + "," + r.Groups[2].Value + "," + r.Groups[3].Value + "," + r.Groups[4].Value : null };
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

        static bool ServedViewer(string report)
        {
            try
            {
                using (var fs = new FileStream(report, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    return new StreamReader(fs).ReadToEnd().Contains("Output #0");
            }
            catch { return false; }
        }

        static void Kill(Process p) { if (p != null) { try { if (!p.HasExited) p.Kill(); } catch { } } }
    }
}
