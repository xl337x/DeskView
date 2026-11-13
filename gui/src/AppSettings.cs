// DeskView settings: everything the app and the engine need, saved as JSON in %APPDATA%\DeskView\app.json.
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace DeskView
{
    public enum Role { None, Server, Client }
    public enum Side { None, Left, Right, Top, Bottom }

    public class AppSettings
    {
        // --- who is who ---------------------------------------------------------------------------------------
        public Role Role { get; set; } = Role.None;
        public string ComputerName { get; set; } = Environment.MachineName;
        public string RemoteName { get; set; } = "";          // the other computer's name (as it calls itself)
        public string ServerAddress { get; set; } = "";       // client: the server's address
        public int Port { get; set; } = 24800;
        public string Peer { get; set; } = "";                // last seen address of the other computer
        public bool SetupDone { get; set; }

        // --- pairing / security ---------------------------------------------------------------------------------
        public string PairCode { get; set; } = "";
        public bool TlsEnabled { get; set; } = true;
        public bool CheckPeers { get; set; } = true;

        // --- screens (DeskView) -----------------------------------------------------------------------------------
        public Dictionary<string, int> Screens { get; set; } = new Dictionary<string, int>(); // server: local monitor -> client screen
        public int ClientView { get; set; }                   // client: server screen being viewed, 0 = none
        public string Profile { get; set; } = "Auto";         // Auto / Wired / WiFi
        public bool Interactive { get; set; } = true;
        public string Picture { get; set; } = "Fit";          // Fit / Stretch
        public string Encoder { get; set; } = "";
        public int VideoPort { get; set; } = 9000;
        public int ControlPort { get; set; } = 9002;

        // --- layout: where the other computer sits for ordinary edge switching ------------------------------------
        public Side RemoteSide { get; set; } = Side.Right;

        // --- switching / input (server options) -----------------------------------------------------------
        public bool SwitchDelayEnabled { get; set; }
        public int SwitchDelayMs { get; set; } = 250;
        public bool DoubleTapEnabled { get; set; }
        public int DoubleTapMs { get; set; } = 250;
        public bool RelativeMouseMoves { get; set; }
        public bool Win32KeepForeground { get; set; }
        public bool DefaultLockToScreen { get; set; }
        public bool DisableLockToScreen { get; set; }
        public bool HeartbeatEnabled { get; set; }
        public int HeartbeatMs { get; set; } = 5000;
        public bool PreventSleep { get; set; }

        // --- clipboard ----------------------------------------------------------------------------------------------
        public bool ClipboardEnabled { get; set; } = true;
        /// <summary>Client: keep the mouse pointer visible (Windows hides it when no mouse is plugged in).</summary>
        public bool AlwaysShowPointer { get; set; } = true;
        /// <summary>"Classic" = the separate keyboard/mouse engine; "DeskView" = DeskView's own encrypted switching and clipboard.</summary>
        public string InputEngine { get; set; } = "Classic";
        /// <summary>True when DeskView turned Mouse Keys on (so turning the option off undoes only our change).</summary>
        public bool PointerForcedByUs { get; set; }
        public int ClipboardSizeMb { get; set; } = 3;

        // --- the other computer's options (corners, half-duplex keys, modifier remapping) -------------------------
        public bool CornerTopLeft { get; set; }
        public bool CornerTopRight { get; set; }
        public bool CornerBottomLeft { get; set; }
        public bool CornerBottomRight { get; set; }
        public int CornerSize { get; set; }
        public bool HalfDuplexCapsLock { get; set; }
        public bool HalfDuplexNumLock { get; set; }
        public bool HalfDuplexScrollLock { get; set; }
        public string ModifierShift { get; set; } = "shift";
        public string ModifierCtrl { get; set; } = "ctrl";
        public string ModifierAlt { get; set; } = "alt";
        public string ModifierAltGr { get; set; } = "altgr";
        public string ModifierMeta { get; set; } = "meta";
        public string ModifierSuper { get; set; } = "super";

        // --- client options --------------------------------------------------------------------------------------------
        public bool InvertScrollY { get; set; }
        public bool InvertScrollX { get; set; }
        public double ScrollScaleY { get; set; } = 1.0;
        public double ScrollScaleX { get; set; } = 1.0;
        public bool LanguageSync { get; set; } = true;

        // --- app ---------------------------------------------------------------------------------------------------------
        public string LogLevel { get; set; } = "INFO";
        public bool StartAtLogin { get; set; } = true;
        public bool StartEngineOnLaunch { get; set; } = true;

        // ------------------------------------------------------------------------------------------------------------------
        // DESKVIEW_HOME: a separate settings folder (tests use it so they never touch the real settings).
        public static string Dir => Environment.GetEnvironmentVariable("DESKVIEW_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DeskView");
        public static string FilePath => Path.Combine(Dir, "app.json");

        public static AppSettings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                {
                    var s = new JavaScriptSerializer().Deserialize<AppSettings>(File.ReadAllText(FilePath));
                    if (s != null) { s.Screens = s.Screens ?? new Dictionary<string, int>(); return s; }
                }
            }
            catch { }
            return new AppSettings();
        }

        public void Save()
        {
            Directory.CreateDirectory(Dir);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, Pretty(new JavaScriptSerializer().Serialize(this)), new UTF8Encoding(false));
            if (File.Exists(FilePath)) File.Replace(tmp, FilePath, null); else File.Move(tmp, FilePath);
        }

        /// <summary>12 characters from a cryptographic random generator (about 59 bits).</summary>
        public static string NewPairCode()
        {
            const string alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
            var bytes = new byte[12];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            var sb = new StringBuilder();
            foreach (var b in bytes) sb.Append(alphabet[b % alphabet.Length]);
            return sb.ToString();
        }

        public static bool IsValidPairCode(string code) =>
            code != null && System.Text.RegularExpressions.Regex.IsMatch(code.Trim().ToUpperInvariant(), "^[2-9A-HJKMNP-Z]{8,12}$");

        /// <summary>Key for the encrypted video streams (same derivation as the PowerShell DeskView).</summary>
        public string VideoKey()
        {
            using (var sha = SHA256.Create())
            {
                var h = sha.ComputeHash(Encoding.UTF8.GetBytes("DeskView-video-v2:" + (PairCode ?? "").Trim().ToUpperInvariant()));
                var sb = new StringBuilder();
                for (int i = 0; i < 16; i++) sb.Append(h[i].ToString("x2"));
                return sb.ToString();
            }
        }

        // JavaScriptSerializer writes one long line; indent it so people can read the file.
        static string Pretty(string json)
        {
            var sb = new StringBuilder(); int depth = 0; bool inString = false;
            for (int i = 0; i < json.Length; i++)
            {
                char c = json[i];
                if (c == '"' && (i == 0 || json[i - 1] != '\\')) inString = !inString;
                if (inString) { sb.Append(c); continue; }
                switch (c)
                {
                    case '{': case '[': sb.Append(c).Append('\n').Append(' ', ++depth * 2); break;
                    case '}': case ']': sb.Append('\n').Append(' ', --depth * 2).Append(c); break;
                    case ',': sb.Append(c).Append('\n').Append(' ', depth * 2); break;
                    case ':': sb.Append(": "); break;
                    default: sb.Append(c); break;
                }
            }
            return sb.ToString();
        }
    }
}
