// The keyboard/mouse engine (DeskView's build; see THIRD_PARTY_NOTICES.md).
// DeskView writes the engine's own settings file and screen layout, and asks the engine service (which runs the
// engine with the rights it needs to work over admin windows too) to start or stop it, over its local pipe.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;

namespace DeskView
{
    public static class CoreControl
    {
        public static string InstallDir => @"C:\Program Files\Deskflow";
        public static string CorePath => Path.Combine(InstallDir, "deskflow-core.exe");
        public static bool Installed => File.Exists(CorePath);
        /// <summary>The engine understands portals (the DeskView build).</summary>
        public static bool PortalCapable => File.Exists(Path.Combine(InstallDir, "deskview.txt"));
        public static string ConfigPath => Path.Combine(AppSettings.Dir, "engine.conf");
        public static string LayoutPath => Path.Combine(AppSettings.Dir, "layout.conf");
        public static string TlsDir => @"C:\ProgramData\Deskflow\tls";
        public static string CertificatePath => Path.Combine(TlsDir, "deskflow.pem");
        public static string ServiceLog => @"C:\ProgramData\Deskflow\deskflow-daemon.log";
        const string PipeName = "deskflow-daemon";

        // ---------------------------------------------------------------------------------------------------------
        // engine settings (an INI file in Qt's format)
        // ---------------------------------------------------------------------------------------------------------
        static string B(bool v) => v ? "true" : "false";
        static string Q(string v) => "\"" + (v ?? "").Replace("\\", "/").Replace("\"", "") + "\"";

        /// <summary>Write the engine settings and layout. Returns true if anything changed (engine needs a restart).</summary>
        public static bool WriteConfig(AppSettings s, string portal)
        {
            var me = Safe(s.ComputerName); var other = Safe(s.RemoteName);
            var ini = new StringBuilder();
            void Section(string name) { ini.Append("\r\n[").Append(name).Append("]\r\n"); }
            void Kv(string k, string v) { ini.Append(k).Append('=').Append(v).Append("\r\n"); }

            Section("core");
            Kv("coreMode", s.Role == Role.Server ? "2" : s.Role == Role.Client ? "1" : "0");
            Kv("computerName", me);
            Kv("port", s.Port.ToString());
            Kv("preventSleep", B(s.PreventSleep));
            Kv("processMode", "0");
            Kv("useHooks", "true");
            Section("client");
            Kv("remoteHost", s.ServerAddress ?? "");
            Kv("invertYScroll", B(s.InvertScrollY));
            Kv("invertXScroll", B(s.InvertScrollX));
            Kv("yScrollScale", s.ScrollScaleY.ToString(System.Globalization.CultureInfo.InvariantCulture));
            Kv("xScrollScale", s.ScrollScaleX.ToString(System.Globalization.CultureInfo.InvariantCulture));
            Kv("languageSync", B(s.LanguageSync));
            Section("server");
            Kv("externalConfig", "true");
            Kv("externalConfigFile", Q(LayoutPath));
            Kv("protocol", "barrier");
            Kv("enableClipboard", B(s.ClipboardEnabled));
            Kv("clipboardSize", s.ClipboardSizeMb.ToString());
            Kv("enableHeartbeat", B(s.HeartbeatEnabled));
            Kv("heartbeat", s.HeartbeatMs.ToString());
            Kv("enableSwitchDelay", B(s.SwitchDelayEnabled));
            Kv("switchDelay", s.SwitchDelayMs.ToString());
            Kv("enableSwitchDoubleTap", B(s.DoubleTapEnabled));
            Kv("switchDoubleTap", s.DoubleTapMs.ToString());
            Kv("relativeMouseMoves", B(s.RelativeMouseMoves));
            Kv("win32KeepForeground", B(s.Win32KeepForeground));
            Kv("defaultLockToComputerState", B(s.DefaultLockToScreen));
            Kv("disableLockToComputer", B(s.DisableLockToScreen));
            Section("security");
            Kv("tlsEnabled", B(s.TlsEnabled));
            Kv("checkPeerFingerprints", B(s.CheckPeers));
            Kv("certificate", Q(CertificatePath));
            Kv("keySize", "2048");
            Section("log");
            Kv("level", s.LogLevel);
            if (s.Role == Role.Server)
            {
                Section("computer_" + me);
                Kv("name", me);
                if (other.Length > 0)
                {
                    Section("computer_" + other);
                    Kv("name", other);
                    Kv("switchCornerTopLeft", B(s.CornerTopLeft));
                    Kv("switchCornerTopRight", B(s.CornerTopRight));
                    Kv("switchCornerBottomLeft", B(s.CornerBottomLeft));
                    Kv("switchCornerBottomRight", B(s.CornerBottomRight));
                    Kv("switchCornerSize", s.CornerSize.ToString());
                    Kv("halfDuplexCapsLock", B(s.HalfDuplexCapsLock));
                    Kv("halfDuplexNumLock", B(s.HalfDuplexNumLock));
                    Kv("halfDuplexScrollLock", B(s.HalfDuplexScrollLock));
                    Kv("modifierShift", s.ModifierShift); Kv("modifierCtrl", s.ModifierCtrl); Kv("modifierAlt", s.ModifierAlt);
                    Kv("modifierAltGr", s.ModifierAltGr); Kv("modifierMeta", s.ModifierMeta); Kv("modifierSuper", s.ModifierSuper);
                    if (!string.IsNullOrEmpty(portal)) { Kv("portal", "\"" + portal + "\""); Kv("portalPid", Process.GetCurrentProcess().Id.ToString()); }
                }
            }

            // the screen layout: which edge of this computer leads to the other one
            var layout = new StringBuilder("section: links\r\n\t" + me + ":\r\n");
            if (s.Role == Role.Server && other.Length > 0 && s.RemoteSide != Side.None)
            {
                layout.Append("\t\t").Append(EdgeName(s.RemoteSide)).Append(" = ").Append(other).Append("\r\n");
                layout.Append('\t').Append(other).Append(":\r\n\t\t").Append(Opposite(s.RemoteSide)).Append(" = ").Append(me).Append("\r\n");
            }
            else if (other.Length > 0) layout.Append('\t').Append(other).Append(":\r\n");
            layout.Append("end\r\n\r\nsection: options\r\nend\r\n");

            Directory.CreateDirectory(AppSettings.Dir);
            bool changed = WriteIfChanged(ConfigPath, ini.ToString().TrimStart()) | WriteIfChanged(LayoutPath, layout.ToString());
            return changed;
        }

        /// <summary>Only the portal changed: the engine re-reads it by itself within a second (no restart).</summary>
        public static bool UpdatePortal(AppSettings s, string portal) => WriteConfig(s, portal);

        // The engine's layout file calls the top and bottom edges "up" and "down".
        static string EdgeName(Side side) => side switch { Side.Left => "left", Side.Right => "right", Side.Top => "up", Side.Bottom => "down", _ => "" };
        static string Opposite(Side side) => side switch { Side.Left => "right", Side.Right => "left", Side.Top => "down", Side.Bottom => "up", _ => "" };
        static string Safe(string name) => new string((name ?? "").Where(c => char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.').ToArray());

        static bool WriteIfChanged(string path, string text)
        {
            if (File.Exists(path) && File.ReadAllText(path) == text) return false;
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
            return true;
        }

        // ---------------------------------------------------------------------------------------------------------
        // the engine service (its pipe protocol: one "command=argument" line per message)
        // ---------------------------------------------------------------------------------------------------------
        public static string LastError { get; private set; } = "";
        /// <summary>DESKVIEW_DRYRUN=1: never talk to the engine service; record what would have been sent (tests).</summary>
        public static readonly bool DryRun = Environment.GetEnvironmentVariable("DESKVIEW_DRYRUN") == "1";
        public static readonly List<string> Sent = new List<string>();

        static bool Send(params string[] commands)
        {
            if (DryRun) { lock (Sent) Sent.AddRange(commands); return true; }
            try
            {
                using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut))
                {
                    pipe.Connect(2000);
                    var reader = new StreamReader(pipe, Encoding.UTF8);
                    var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
                    // The service checks versions in its greeting; it still accepts commands after a mismatch.
                    writer.WriteLine("hello=" + EngineVersion());
                    ReadLine(pipe, reader, 1500);
                    foreach (var c in commands) { writer.WriteLine(c); ReadLine(pipe, reader, 3000); }
                    LastError = "";
                    return true;
                }
            }
            catch (Exception e) { LastError = "engine service not reachable (" + e.Message + ")"; return false; }
        }

        static string ReadLine(PipeStream pipe, StreamReader reader, int ms)
        {
            var t = reader.ReadLineAsync();
            return t.Wait(ms) ? t.Result : null;
        }

        static string EngineVersion()
        {
            try { return FileVersionInfo.GetVersionInfo(CorePath).ProductVersion ?? "0"; } catch { return "0"; }
        }

        /// <summary>Start (or restart) the engine with our settings.</summary>
        public static bool Start()
        {
            StopForeignGui();
            return Send("configFile=" + ConfigPath.Replace('\\', '/'), "logLevel=" + "INFO", "start");
        }

        public static bool Stop() => Send("stop");

        /// <summary>The engine's own window would give the service its own settings: close it, DeskView manages the engine now.</summary>
        public static void StopForeignGui()
        {
            if (DryRun) return;
            foreach (var p in Process.GetProcessesByName("deskflow")) { try { p.Kill(); } catch { } }
        }

        /// <summary>Is an engine process running right now?</summary>
        public static bool Running => Process.GetProcessesByName("deskflow-core").Length > 0;

        // ---------------------------------------------------------------------------------------------------------
        // what the engine is doing, from the service log
        // ---------------------------------------------------------------------------------------------------------
        public static IList<string> TailLog(int lines)
        {
            try
            {
                using (var fs = new FileStream(ServiceLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    long start = Math.Max(0, fs.Length - 64 * 1024);
                    fs.Seek(start, SeekOrigin.Begin);
                    var text = new StreamReader(fs).ReadToEnd();
                    var all = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                    return all.Skip(Math.Max(0, all.Length - lines)).ToList();
                }
            }
            catch { return new List<string>(); }
        }

        /// <summary>SHA-256 fingerprint of this computer's TLS certificate (what the other side should trust).</summary>
        public static string CertificateFingerprint()
        {
            try
            {
                var pem = File.ReadAllText(CertificatePath);
                var m = System.Text.RegularExpressions.Regex.Match(pem, "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", System.Text.RegularExpressions.RegexOptions.Singleline);
                if (!m.Success) return "";
                var der = Convert.FromBase64String(m.Groups[1].Value.Replace("\r", "").Replace("\n", ""));
                using (var sha = System.Security.Cryptography.SHA256.Create())
                    return string.Join(":", sha.ComputeHash(der).Select(b => b.ToString("X2")));
            }
            catch { return ""; }
        }
    }
}
