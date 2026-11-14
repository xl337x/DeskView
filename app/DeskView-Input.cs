// DeskView reverse control channel (the direction the engine can't do at the same time).
//
//   DeskViewAgent      on the machine being viewed: accepts one authenticated viewer over TCP and replays
//                      its mouse / keyboard input locally; can be asked which monitor to stream.
//   DeskViewForwarder  on the machine you sit at: while viewing, captures your *physical* input with
//                      low-level hooks and sends it to the agent. The local cursor keeps moving over the
//                      picture (instant pointer, no video lag); clicks, wheel and keys are swallowed locally
//                      and only happen on the remote machine. Ctrl+Alt+0..9 / D stay local (DeskView hotkeys).
//
// Security (protocol v2): the pairing code is never sent. Both sides derive K = PBKDF2-SHA256(code) and prove
// knowledge of it with HMAC challenges over fresh nonces from both sides (mutual authentication). Each
// session then derives its own AES-256 and HMAC-SHA256 keys; every message is AES-CBC encrypted and
// authenticated (encrypt-then-MAC) with a strictly increasing sequence number (no replay, no tampering).
// Frames are length-limited, unauthenticated peers get a short deadline, and repeated failures from an
// address lock it out for a minute.
//
// Messages (inside the encrypted frames, viewer -> agent): S <DISPLAYn|n> | M <nx> <ny> (0..65535 within the
// streamed monitor) | B <button 0-4> <1 down/0 up> | W <delta> | H <delta> | K <vk> <scan> <ext 0/1> <1/0> | P
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

static class DvNative
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    // x64 layout: 4-byte type, 4 bytes padding, then the 32-byte union.
    [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }
    public delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);

    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern IntPtr CreateCursor(IntPtr inst, int x, int y, int w, int h, byte[] and, byte[] xor);

    public static readonly IntPtr PerMonitorV2 = new IntPtr(-4);
    public static readonly IntPtr AgentMarker = new IntPtr(0x44564147);   // 'DVAG': input replayed by the agent
}

/// <summary>Screen-edge geometry for switching computers (physical pixels).</summary>
public static class DvEdge
{
    public static string Opposite(string side)
    {
        switch (side) { case "left": return "right"; case "right": return "left"; case "top": return "bottom"; case "bottom": return "top"; }
        return "";
    }

    /// <summary>The whole desktop (all monitors) in physical pixels.</summary>
    public static System.Drawing.Rectangle Desktop()
    {
        var prev = DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        try { return new System.Drawing.Rectangle(DvNative.GetSystemMetrics(76), DvNative.GetSystemMetrics(77), DvNative.GetSystemMetrics(78), DvNative.GetSystemMetrics(79)); }
        finally { if (prev != IntPtr.Zero) DvNative.SetThreadDpiAwarenessContext(prev); }
    }

    static bool Vertical(string side) { return side == "left" || side == "right"; }
    static int Norm(int v, int size) { return Math.Max(0, Math.Min(65535, (int)Math.Round(v * 65535.0 / Math.Max(1, size - 1)))); }

    /// <summary>Is the pointer touching this side of the desktop?</summary>
    public static bool AtEdge(string side, int x, int y, System.Drawing.Rectangle d)
    {
        switch (side) { case "left": return x <= d.Left; case "right": return x >= d.Right - 1; case "top": return y <= d.Top; case "bottom": return y >= d.Bottom - 1; }
        return false;
    }

    /// <summary>Would this position be past this side of the desktop?</summary>
    public static bool Beyond(string side, int x, int y, System.Drawing.Rectangle d)
    {
        switch (side) { case "left": return x < d.Left; case "right": return x > d.Right - 1; case "top": return y < d.Top; case "bottom": return y > d.Bottom - 1; }
        return false;
    }

    /// <summary>Where along the side the point is, 0..65535 (top to bottom, or left to right).</summary>
    public static int Along(string side, int x, int y, System.Drawing.Rectangle d)
    {
        return Vertical(side) ? Norm(y - d.Top, d.Height) : Norm(x - d.Left, d.Width);
    }

    /// <summary>The point just inside this side of the desktop at 'along' (0..65535).</summary>
    public static System.Drawing.Point Place(string side, int along, System.Drawing.Rectangle d, int inset)
    {
        int ax = d.Left + (int)Math.Round(along * (d.Width - 1) / 65535.0), ay = d.Top + (int)Math.Round(along * (d.Height - 1) / 65535.0);
        switch (side)
        {
            case "left": return new System.Drawing.Point(d.Left + inset, ay);
            case "right": return new System.Drawing.Point(d.Right - 1 - inset, ay);
            case "top": return new System.Drawing.Point(ax, d.Top + inset);
            default: return new System.Drawing.Point(ax, d.Bottom - 1 - inset);
        }
    }
}

/// <summary>Clipboard text on its own STA thread (the clipboard needs one), with retries; never throws.</summary>
public static class DvClip
{
    public const int ChunkChars = 40000;
    static BlockingCollection<Action> work = new BlockingCollection<Action>();
    static Thread thread;
    static readonly object startLock = new object();

    static DateTime busySince = DateTime.MaxValue;   // when the current job started (a stuck job => new worker)

    static void Run(Action a)
    {
        lock (startLock)
        {
            if (thread != null && (DateTime.UtcNow - busySince).TotalSeconds > 5)
            {
                // the worker is stuck inside the clipboard (another program does not answer): start a fresh one
                work.CompleteAdding(); work = new BlockingCollection<Action>(); thread = null;
            }
            if (thread == null)
            {
                var q = work;
                thread = new Thread(() => { foreach (var w in q.GetConsumingEnumerable()) { busySince = DateTime.UtcNow; try { w(); } catch { } busySince = DateTime.MaxValue; } }) { IsBackground = true, Name = "DeskViewClipboard" };
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
            }
        }
        work.Add(a);
    }

    /// <summary>Current clipboard text, or null (no text, busy, or no answer within the timeout).</summary>
    public static string GetText(int timeoutMs = 400)
    {
        string text = null; var done = new ManualResetEventSlim();
        Run(() => { try { for (int i = 0; i < 5; i++) { try { if (Clipboard.ContainsText()) text = Clipboard.GetText(); break; } catch (ExternalException) { Thread.Sleep(30); } } } finally { done.Set(); } });
        return done.Wait(timeoutMs) ? text : null;
    }

    public static void SetText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        Run(() => Clipboard.SetDataObject(text, true, 10, 50));
    }

    /// <summary>The frames that carry a clipboard text: CB, CD &lt;base64 chunk&gt;..., CE (each with the given prefix).</summary>
    public static List<string> Frames(string text, string prefix)
    {
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
        var list = new List<string> { prefix + "CB" };
        for (int i = 0; i < b64.Length; i += ChunkChars) list.Add(prefix + "CD " + b64.Substring(i, Math.Min(ChunkChars, b64.Length - i)));
        list.Add(prefix + "CE");
        return list;
    }
}

/// <summary>Authenticated, encrypted framing shared by agent and forwarder.</summary>
public static class DvProto
{
    public const int NonceLen = 16, MacLen = 32, MaxFrame = 1024, MaxFileFrame = 60000;
    static readonly byte[] Salt = Encoding.ASCII.GetBytes("DeskView-pairing-v2");
    static readonly Dictionary<string, byte[]> keyCache = new Dictionary<string, byte[]>();

    /// <summary>Long-term key from the pairing code (PBKDF2-SHA256, slow on purpose; cached per code).</summary>
    public static byte[] PairKey(string code)
    {
        code = (code ?? "").Trim().ToUpperInvariant();
        lock (keyCache)
        {
            byte[] k;
            if (keyCache.TryGetValue(code, out k)) return k;
            using (var kdf = new Rfc2898DeriveBytes(code, Salt, 200000, HashAlgorithmName.SHA256)) k = kdf.GetBytes(32);
            keyCache[code] = k;
            return k;
        }
    }

    public static byte[] Hmac(byte[] key, params byte[][] parts)
    {
        using (var h = new HMACSHA256(key))
        {
            foreach (var p in parts) h.TransformBlock(p, 0, p.Length, null, 0);
            h.TransformFinalBlock(new byte[0], 0, 0);
            return h.Hash;
        }
    }

    public static byte[] Ascii(string s) { return Encoding.ASCII.GetBytes(s); }

    public static byte[] Random(int n) { var b = new byte[n]; using (var r = RandomNumberGenerator.Create()) r.GetBytes(b); return b; }

    public static bool SameBytes(byte[] a, byte[] b)
    {
        if (a == null || b == null || a.Length != b.Length) return false;
        int d = 0; for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i]; return d == 0;
    }

    /// <summary>Reads exactly n bytes or throws (EOF / timeout).</summary>
    public static byte[] ReadExact(Stream s, int n)
    {
        var b = new byte[n]; int got = 0;
        while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) throw new IOException("connection closed"); got += r; }
        return b;
    }

    /// <summary>Viewer side of the handshake: proves the code, checks the agent's proof, returns session keys
    /// (null if the agent refused the code or could not prove it knows it).</summary>
    public static byte[][] ClientHandshake(Stream s, string code)
    {
        var key = PairKey(code);
        var magic = ReadExact(s, 4);
        if (Encoding.ASCII.GetString(magic) != "DV2\n") throw new IOException("not a DeskView v2 agent (update the other machine)");
        var nonceA = ReadExact(s, NonceLen);
        var nonceV = Random(NonceLen);
        var proofV = Hmac(key, Ascii("viewer"), nonceA, nonceV);
        s.Write(nonceV, 0, nonceV.Length); s.Write(proofV, 0, proofV.Length);
        byte[] proofA;
        try { proofA = ReadExact(s, MacLen); } catch (IOException) { return null; }
        if (!SameBytes(proofA, Hmac(key, Ascii("agent"), nonceV, nonceA))) return null;
        return SessionKeys(key, nonceA, nonceV);
    }

    /// <summary>Per-session keys: [0] = AES-256 key, [1] = HMAC key.</summary>
    public static byte[][] SessionKeys(byte[] pairKey, byte[] nonceAgent, byte[] nonceViewer)
    {
        return new[] { Hmac(pairKey, Ascii("enc"), nonceAgent, nonceViewer), Hmac(pairKey, Ascii("mac"), nonceAgent, nonceViewer) };
    }

    public static void WriteFrame(Stream s, byte[][] keys, ulong seq, string message)
    {
        byte[] iv = Random(16), ct;
        using (var aes = Aes.Create())
        {
            aes.Key = keys[0]; aes.IV = iv; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
            using (var enc = aes.CreateEncryptor()) { var pt = Encoding.UTF8.GetBytes(message); ct = enc.TransformFinalBlock(pt, 0, pt.Length); }
        }
        var seqBytes = BitConverter.GetBytes(seq);
        var tag = Hmac(keys[1], seqBytes, iv, ct);
        int len = 8 + 16 + ct.Length + MacLen;
        var frame = new byte[2 + len];
        frame[0] = (byte)(len >> 8); frame[1] = (byte)len;
        Buffer.BlockCopy(seqBytes, 0, frame, 2, 8);
        Buffer.BlockCopy(iv, 0, frame, 10, 16);
        Buffer.BlockCopy(ct, 0, frame, 26, ct.Length);
        Buffer.BlockCopy(tag, 0, frame, 26 + ct.Length, MacLen);
        s.Write(frame, 0, frame.Length);
    }

    /// <summary>Reads, authenticates and decrypts one frame; seq must exceed lastSeq. Throws on anything wrong.</summary>
    public static string ReadFrame(Stream s, byte[][] keys, ref ulong lastSeq, int maxLen = MaxFrame)
    {
        var hdr = ReadExact(s, 2);
        int len = (hdr[0] << 8) | hdr[1];
        if (len < 8 + 16 + 16 + MacLen || len > maxLen) throw new InvalidDataException("bad frame length");
        var body = ReadExact(s, len);
        int ctLen = len - 8 - 16 - MacLen;
        var seqBytes = new byte[8]; var iv = new byte[16]; var ct = new byte[ctLen]; var tag = new byte[MacLen];
        Buffer.BlockCopy(body, 0, seqBytes, 0, 8); Buffer.BlockCopy(body, 8, iv, 0, 16);
        Buffer.BlockCopy(body, 24, ct, 0, ctLen); Buffer.BlockCopy(body, 24 + ctLen, tag, 0, MacLen);
        if (!SameBytes(tag, Hmac(keys[1], seqBytes, iv, ct))) throw new InvalidDataException("bad frame MAC");
        ulong seq = BitConverter.ToUInt64(seqBytes, 0);
        if (seq <= lastSeq) throw new InvalidDataException("replayed frame");
        lastSeq = seq;
        using (var aes = Aes.Create())
        {
            aes.Key = keys[0]; aes.IV = iv; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
            using (var dec = aes.CreateDecryptor()) return Encoding.UTF8.GetString(dec.TransformFinalBlock(ct, 0, ct.Length));
        }
    }
}

public class DeskViewAgent
{
    public int Port = 9002;
    public string Code = "";                     // pairing code the viewer must know
    public volatile string[] AllowedIps = new string[0];   // empty = any address the firewall lets through
    public volatile int TL, TT, TW = 1, TH = 1;  // streamed monitor, physical pixels
    public volatile int VL, VR;                  // local desktop left/right
    public volatile bool AvoidLeftEdge, AvoidRightEdge;  // outer edges the engine links to the other machine
    public volatile string Status = "idle";
    public volatile string Client = "";
    public int Moves, Buttons, Keys;             // counters (diagnostics / tests)
    public volatile bool ShareClipboard = true;
    public int MaxClipboardBytes = 3 * 1024 * 1024;
    // Test hooks: where the pointer goes / is, the desktop, and the clipboard (defaults: the real ones).
    public Action<int, int> SetCursor = (x, y) => { DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2); DvNative.SetCursorPos(x, y); };
    public Func<System.Drawing.Point> GetCursor = () => { DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2); DvNative.POINT p; DvNative.GetCursorPos(out p); return new System.Drawing.Point(p.X, p.Y); };
    public Func<System.Drawing.Rectangle> GetDesktop = DvEdge.Desktop;
    public Func<string> ReadClipboard = () => DvClip.GetText();
    public Action<string> WriteClipboard = DvClip.SetText;
    public int Switches;                         // times the pointer came over / went back (tests)
    public string LastClipboardIn;               // last clipboard text received (tests)
    public volatile string PeerName = "";        // the other computer's name, as it told us over the link

    string edgeIn;                               // side the pointer came in from while the other machine drives it (null = not)
    string lastClip;                             // last text synced either way: never echo it back
    StringBuilder clipIn;
    Stream sessionStream; byte[][] sessionKeys; ulong sendSeq;
    readonly object sendLock = new object();

    string requestedMonitor;
    TcpListener listener;
    Thread thread;
    volatile bool stopping;
    TcpClient active;                             // the authenticated session (one at a time)
    readonly object sessionLock = new object();
    readonly HashSet<int> heldButtons = new HashSet<int>();
    readonly HashSet<string> heldKeys = new HashSet<string>();
    readonly Dictionary<string, int> failures = new Dictionary<string, int>();
    readonly Dictionary<string, DateTime> lockedUntil = new Dictionary<string, DateTime>();

    /// <summary>Monitor the viewer asked for since the last call (atomic take), or null.</summary>
    public string TakeRequestedMonitor() { return Interlocked.Exchange(ref requestedMonitor, null); }

    public void Start()
    {
        if (thread != null) return;
        stopping = false;
        listener = new TcpListener(IPAddress.Any, Port);
        listener.Start();
        thread = new Thread(AcceptLoop) { IsBackground = true, Name = "DeskViewAgent" };
        thread.Start();
        Status = "listening on " + Port;
    }

    public void Stop()
    {
        stopping = true;
        try { listener.Stop(); } catch { }
        lock (sessionLock) { if (active != null) try { active.Close(); } catch { } }
        if (thread != null) thread.Join(2000);
        thread = null;
        ReleaseAll();
    }

    void AcceptLoop()
    {
        while (!stopping)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { if (stopping) return; Thread.Sleep(200); continue; }
            // Each connection on its own thread, so a slow or hostile peer can't hold the door shut.
            var t = new Thread(() => Serve(c)) { IsBackground = true, Name = "DeskViewAgentSession" };
            t.Start();
        }
    }

    bool IsLockedOut(string ip)
    {
        lock (failures) { DateTime until; return lockedUntil.TryGetValue(ip, out until) && DateTime.UtcNow < until; }
    }

    void Fail(string ip)
    {
        lock (failures)
        {
            int n; failures.TryGetValue(ip, out n); failures[ip] = ++n;
            if (n >= 5) { lockedUntil[ip] = DateTime.UtcNow.AddMinutes(1); failures[ip] = 0; }
        }
        Status = "refused " + ip;
    }

    void Serve(TcpClient c)
    {
        string ip = "";
        bool authed = false;
        try
        {
            ip = ((IPEndPoint)c.Client.RemoteEndPoint).Address.ToString();
            var allowed = AllowedIps;
            if ((allowed.Length > 0 && Array.IndexOf(allowed, ip) < 0) || IsLockedOut(ip) || string.IsNullOrEmpty(Code)) { Status = "refused " + ip; return; }
            c.NoDelay = true;
            c.ReceiveTimeout = 5000; c.SendTimeout = 5000;      // handshake deadline
            var s = c.GetStream();
            var key = DvProto.PairKey(Code);

            var nonceA = DvProto.Random(DvProto.NonceLen);
            s.Write(DvProto.Ascii("DV2\n"), 0, 4); s.Write(nonceA, 0, nonceA.Length);
            var nonceV = DvProto.ReadExact(s, DvProto.NonceLen);
            var proofV = DvProto.ReadExact(s, DvProto.MacLen);
            if (!DvProto.SameBytes(proofV, DvProto.Hmac(key, DvProto.Ascii("viewer"), nonceA, nonceV))) { Fail(ip); return; }
            var proofA = DvProto.Hmac(key, DvProto.Ascii("agent"), nonceV, nonceA);
            s.Write(proofA, 0, proofA.Length);
            lock (failures) failures.Remove(ip);
            var keys = DvProto.SessionKeys(key, nonceA, nonceV);
            authed = true;
            ulong lastSeq = 0;
            string first = DvProto.ReadFrame(s, keys, ref lastSeq);
            if (first == "FILES") { c.ReceiveTimeout = 30000; ServeFiles(s, keys, ref lastSeq, ip); return; }   // doesn't take over control

            // One controller at a time: a new authenticated session replaces the old one.
            lock (sessionLock) { if (active != null) try { active.Close(); } catch { } active = c; }
            ReleaseAll();
            c.ReceiveTimeout = 30000;                             // the viewer pings every few seconds
            Client = ip; Status = "controlled by " + ip;
            lock (sendLock) { sessionStream = s; sessionKeys = keys; sendSeq = 0; }
            edgeIn = null;
            Handle(first);
            // larger frames than the handshake allows: clipboard chunks (only after authentication)
            while (!stopping) Handle(DvProto.ReadFrame(s, keys, ref lastSeq, DvProto.MaxFileFrame));
        }
        catch (InvalidDataException) { if (!authed) Fail(ip); }
        catch { }
        finally
        {
            bool wasActive;
            lock (sessionLock) { wasActive = active == c; if (wasActive) active = null; }
            if (wasActive)
            {
                lock (sendLock) { sessionStream = null; sessionKeys = null; }
                edgeIn = null; clipIn = null;
                ReleaseAll(); Client = ""; Status = "listening on " + Port;
            }
            try { c.Close(); } catch { }
        }
    }

    /// <summary>Files received (full paths), for the app to announce. Saved under Downloads\DeskView.</summary>
    public readonly ConcurrentQueue<string> Received = new ConcurrentQueue<string>();
    public string ReceiveFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "DeskView");

    // F <base64 relative path> <size> | D <base64 bytes> | E (file done) | BYE
    void ServeFiles(Stream s, byte[][] keys, ref ulong lastSeq, string ip)
    {
        FileStream outFile = null; string outPath = null; long expected = 0, written = 0;
        Status = "receiving files from " + ip;
        try
        {
            while (!stopping)
            {
                var msg = DvProto.ReadFrame(s, keys, ref lastSeq, DvProto.MaxFileFrame);
                if (msg.StartsWith("F "))
                {
                    var p = msg.Split(' ');
                    if (outFile != null || p.Length != 3) throw new InvalidDataException("bad file header");
                    expected = long.Parse(p[2]);
                    if (expected < 0 || expected > 64L << 30) throw new InvalidDataException("bad file size");
                    outPath = SafeTarget(Encoding.UTF8.GetString(Convert.FromBase64String(p[1])));
                    Directory.CreateDirectory(Path.GetDirectoryName(outPath));
                    outFile = new FileStream(outPath, FileMode.CreateNew, FileAccess.Write); written = 0;
                }
                else if (msg.StartsWith("D ") && outFile != null)
                {
                    var data = Convert.FromBase64String(msg.Substring(2));
                    if (written + data.Length > expected) throw new InvalidDataException("more data than announced");
                    outFile.Write(data, 0, data.Length); written += data.Length;
                }
                else if (msg == "E" && outFile != null)
                {
                    outFile.Dispose(); outFile = null;
                    if (written != expected) { File.Delete(outPath); throw new InvalidDataException("file cut short"); }
                    Received.Enqueue(outPath);
                }
                else if (msg == "BYE") return;
            }
        }
        finally
        {
            if (outFile != null) { outFile.Dispose(); try { File.Delete(outPath); } catch { } }   // never leave half a file
            Status = "listening on " + Port;
        }
    }

    /// <summary>A path under the receive folder: no "..", no drive letters, no reserved names, never overwrites.</summary>
    string SafeTarget(string relative)
    {
        var parts = new List<string>();
        foreach (var raw in relative.Replace('\\', '/').Split('/'))
        {
            var seg = raw.Trim().TrimEnd('.');
            foreach (var ch in Path.GetInvalidFileNameChars()) seg = seg.Replace(ch, '_');
            if (seg.Length == 0 || seg == "." || seg == "..") continue;
            if (System.Text.RegularExpressions.Regex.IsMatch(seg, @"^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) seg = "_" + seg;
            parts.Add(seg.Length > 120 ? seg.Substring(0, 120) : seg);
        }
        if (parts.Count == 0) parts.Add("file");
        var full = Path.GetFullPath(Path.Combine(ReceiveFolder, Path.Combine(parts.ToArray())));
        if (!full.StartsWith(Path.GetFullPath(ReceiveFolder) + Path.DirectorySeparatorChar)) throw new InvalidDataException("bad file name");
        string dir = Path.GetDirectoryName(full), name = Path.GetFileNameWithoutExtension(full), ext = Path.GetExtension(full);
        for (int i = 2; File.Exists(full); i++) full = Path.Combine(dir, name + " (" + i + ")" + ext);
        return full;
    }

    /// <summary>Agent -> viewer message ("&lt;" marks this direction, so a reflected frame is never taken for input).</summary>
    void Send(string msg)
    {
        lock (sendLock)
        {
            if (sessionStream == null) return;
            try { DvProto.WriteFrame(sessionStream, sessionKeys, ++sendSeq, "<" + msg); } catch { }
        }
    }

    /// <summary>The other machine's pointer left its desktop through 'viewerSide' at 'along': it appears here
    /// on the opposite side, and its moves now drive this pointer.</summary>
    void Enter(string viewerSide, int along)
    {
        var side = DvEdge.Opposite(viewerSide);
        if (side == "") return;
        var pt = DvEdge.Place(side, Math.Max(0, Math.Min(65535, along)), GetDesktop(), 1);
        SetCursor(pt.X, pt.Y);
        edgeIn = side;
        Interlocked.Increment(ref Switches);
    }

    void MoveBy(int dx, int dy)
    {
        if (edgeIn == null) return;
        dx = Math.Max(-4000, Math.Min(4000, dx)); dy = Math.Max(-4000, Math.Min(4000, dy));
        var d = GetDesktop(); var cur = GetCursor();
        int nx = cur.X + dx, ny = cur.Y + dy;
        bool buttonHeld; lock (heldButtons) buttonHeld = heldButtons.Count > 0;
        // Back across the side it came in from (not while dragging: the drag stays on this machine).
        if (DvEdge.Beyond(edgeIn, nx, ny, d) && !buttonHeld) { SetCursor(Math.Max(d.Left, Math.Min(d.Right - 1, nx)), Math.Max(d.Top, Math.Min(d.Bottom - 1, ny))); Leave(DvEdge.Along(edgeIn, nx, ny, d)); return; }   // rests on the edge it left by
        SetCursor(Math.Max(d.Left, Math.Min(d.Right - 1, nx)), Math.Max(d.Top, Math.Min(d.Bottom - 1, ny)));
        Interlocked.Increment(ref Moves);
    }

    void Leave(int along)
    {
        SendClipboardIfChanged();
        ReleaseAll();                 // nothing stays held here once the keyboard is back on the other machine
        edgeIn = null;
        Interlocked.Increment(ref Switches);
        Send("L " + along);
    }

    void SendClipboardIfChanged()
    {
        if (!ShareClipboard) return;
        var text = ReadClipboard();
        if (string.IsNullOrEmpty(text) || text == lastClip || Encoding.UTF8.GetByteCount(text) > MaxClipboardBytes) return;
        lastClip = text;
        foreach (var f in DvClip.Frames(text, "")) Send(f);
    }

    void Handle(string line)
    {
        if (line.StartsWith("<")) throw new InvalidDataException("reflected frame");
        var p = line.Split(' ');
        try
        {
            switch (p[0])
            {
                case "E": Enter(p[1], int.Parse(p[2])); break;
                case "R": MoveBy(int.Parse(p[1]), int.Parse(p[2])); break;
                case "X": if (edgeIn != null) { edgeIn = null; ReleaseAll(); } break;   // the other machine took its pointer back
                case "N": if (p.Length > 1) PeerName = System.Text.RegularExpressions.Regex.Replace(p[1], @"[^\w\-.]", ""); break;
                case "CB": clipIn = new StringBuilder(); break;
                case "CD":
                    if (clipIn != null && p.Length > 1) { clipIn.Append(p[1]); if (clipIn.Length > MaxClipboardBytes / 3 * 4 + 8) clipIn = null; }
                    break;
                case "CE":
                    if (clipIn != null)
                    {
                        var text = Encoding.UTF8.GetString(Convert.FromBase64String(clipIn.ToString())); clipIn = null;
                        lastClip = text; LastClipboardIn = text;
                        if (ShareClipboard) WriteClipboard(text);
                    }
                    break;
                case "M":
                {
                    int x = TL + (int)Math.Round(int.Parse(p[1]) * (TW - 1) / 65535.0);
                    int y = TT + (int)Math.Round(int.Parse(p[2]) * (TH - 1) / 65535.0);
                    // Keep off outer edges that the engine links to the other machine, or it would switch.
                    if (AvoidRightEdge && x >= VR - 2) x = VR - 3;
                    if (AvoidLeftEdge && x <= VL + 1) x = VL + 2;
                    DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
                    DvNative.SetCursorPos(x, y);   // no hook event: the engine and the portal don't react
                    Interlocked.Increment(ref Moves);
                    break;
                }
                case "B": Button(int.Parse(p[1]), p[2] == "1"); Interlocked.Increment(ref Buttons); break;
                case "W": Mouse(0x0800, int.Parse(p[1])); break;
                case "H": Mouse(0x1000, int.Parse(p[1])); break;
                case "K": Key(ushort.Parse(p[1]), ushort.Parse(p[2]), p[3] == "1", p[4] == "1"); Interlocked.Increment(ref Keys); break;
                case "S": if (p.Length > 1 && p[1].Length <= 16) Interlocked.Exchange(ref requestedMonitor, p[1]); break;
                case "P": break;                                       // keep-alive
            }
        }
        catch (FormatException) { }
        catch (OverflowException) { }
        catch (IndexOutOfRangeException) { }
    }

    static void Mouse(uint flags, int data)
    {
        var a = new DvNative.INPUT[1];
        a[0].type = 0; a[0].mi.dwFlags = flags; a[0].mi.mouseData = (uint)data; a[0].mi.dwExtraInfo = DvNative.AgentMarker;
        DvNative.SendInput(1, a, Marshal.SizeOf(typeof(DvNative.INPUT)));
    }

    void Button(int b, bool down)
    {
        uint[] downF = { 0x0002, 0x0008, 0x0020, 0x0080, 0x0080 };
        uint[] upF   = { 0x0004, 0x0010, 0x0040, 0x0100, 0x0100 };
        if (b < 0 || b > 4) return;
        Mouse(down ? downF[b] : upF[b], b == 3 ? 1 : (b == 4 ? 2 : 0));
        lock (heldButtons) { if (down) heldButtons.Add(b); else heldButtons.Remove(b); }
    }

    void Key(ushort vk, ushort scan, bool ext, bool down)
    {
        var a = new DvNative.INPUT[1];
        a[0].type = 1; a[0].ki.wVk = vk; a[0].ki.wScan = scan;
        a[0].ki.dwFlags = (ext ? 0x0001u : 0u) | (down ? 0u : 0x0002u);
        a[0].ki.dwExtraInfo = DvNative.AgentMarker;
        DvNative.SendInput(1, a, Marshal.SizeOf(typeof(DvNative.INPUT)));
        string k = vk + " " + scan + " " + (ext ? 1 : 0);
        lock (heldKeys) { if (down) heldKeys.Add(k); else heldKeys.Remove(k); }
    }

    // A dropped connection must not leave keys or buttons stuck down.
    void ReleaseAll()
    {
        List<int> bs; List<string> ks;
        lock (heldButtons) { bs = new List<int>(heldButtons); }
        lock (heldKeys) { ks = new List<string>(heldKeys); }
        foreach (var b in bs) Button(b, false);
        foreach (var k in ks) { var p = k.Split(' '); Key(ushort.Parse(p[0]), ushort.Parse(p[1]), p[2] == "1", false); }
    }
}

public class DeskViewForwarder
{
    public string Peer = "", Code = "", Monitor = "", Name = Environment.MachineName;
    public int Port = 9002;
    public volatile int VidL, VidT, VidW = 1, VidH = 1;   // where the remote picture is on this machine (physical px)
    public volatile bool Active;                          // forward input only while viewing
    public bool AcceptInjected;                           // tests only: also treat synthetic input as physical
    public bool NoHooks;                                  // tests only: don't capture this machine's real input
    public bool CountInjected;                            // live QA only (DESKVIEW_QA_INPUT=1): synthetic input counts as physical
    public volatile bool HotkeysEnabled = true;           // detect DeskView hotkeys from the physical keyboard only
    public volatile string Status = "idle";
    public volatile bool Connected;
    // Built-in switching: push the pointer off this side of the desktop ("left"/"right"/"top"/"bottom",
    // "" = off) and it continues on the other machine, with the keyboard; it comes back the same way.
    public volatile string Edge = "";
    public volatile bool RemoteOwned;                     // the pointer and keyboard are on the other machine now
    public volatile bool ShareClipboard = true;
    public int MaxClipboardBytes = 3 * 1024 * 1024;
    public int Switches;                                  // times the pointer went over / came back (tests)
    public Func<System.Drawing.Rectangle> GetDesktop = DvEdge.Desktop;   // test hook

    int parkX, parkY;                                     // where the local pointer waits, hidden, meanwhile
    volatile bool clipToSend;
    string lastClip;
    StringBuilder clipIn;
    readonly ConcurrentQueue<string> clipToSet = new ConcurrentQueue<string>();
    Form cloak;                                           // invisible window under the parked pointer: hides it
    volatile bool readerDead;

    int pendingHotkey;                                   // vk of a physical Ctrl+Alt+0..9 / D press
    Thread hookThread, netThread;
    volatile bool stopping;
    DvNative.HookProc mouseProc, keyProc;
    IntPtr mouseHook, keyHook, mod;
    readonly BlockingCollection<string> queue = new BlockingCollection<string>(new ConcurrentQueue<string>(), 4096);
    bool ctrl, alt;                                       // tracked while we swallow keys (async state is stale then)
    int lastNx = -1, lastNy = -1;
    readonly bool[] forwardedDown = new bool[5];          // buttons whose press went to the remote machine
    bool wasForwarding;

    /// <summary>The DeskView hotkey pressed since the last call (atomic take), or 0.</summary>
    public int TakeHotkey() { return Interlocked.Exchange(ref pendingHotkey, 0); }

    public void Start()
    {
        if (hookThread != null) return;
        stopping = false;
        hookThread = new Thread(HookLoop) { IsBackground = true, Name = "DeskViewForwarderHooks" };
        hookThread.SetApartmentState(ApartmentState.STA);
        hookThread.Start();
        netThread = new Thread(NetLoop) { IsBackground = true, Name = "DeskViewForwarderNet" };
        netThread.Start();
    }

    public void Stop() { stopping = true; Active = false; if (hookThread != null) hookThread.Join(2000); hookThread = null; }

    /// <summary>Ask the agent to stream another monitor (takes effect on the next connection too).</summary>
    public void SelectMonitor(string name) { Monitor = name; Enqueue("S " + name); }

    void Enqueue(string s) { if (Connected) queue.TryAdd(s); }

    /// <summary>Forwarding right now: viewing and the encrypted link is up. Otherwise input stays local.</summary>
    bool Forwarding { get { return Active && Connected; } }

    void InstallHooks()
    {
        if (NoHooks) return;
        if (mouseHook != IntPtr.Zero) DvNative.UnhookWindowsHookEx(mouseHook);
        if (keyHook != IntPtr.Zero) DvNative.UnhookWindowsHookEx(keyHook);
        mouseHook = DvNative.SetWindowsHookEx(14, mouseProc, mod, 0);   // WH_MOUSE_LL
        keyHook = DvNative.SetWindowsHookEx(13, keyProc, mod, 0);       // WH_KEYBOARD_LL
        if (mouseHook == IntPtr.Zero || keyHook == IntPtr.Zero) Status = "input hook failed (error " + Marshal.GetLastWin32Error() + ")";
    }

    void HookLoop()
    {
        DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        mouseProc = MouseHook; keyProc = KeyHook;
        mod = DvNative.GetModuleHandle(null);
        cloak = new CloakForm();
        cloak.CreateControl(); var unused = cloak.Handle;     // created on this thread so the hook can show it at once
        InstallHooks();
        var t = new System.Windows.Forms.Timer { Interval = 50 };
        DateTime lastReinstall = DateTime.Now;
        t.Tick += delegate
        {
            if (stopping) { Application.ExitThread(); return; }
            // Clipboard, on this STA thread: ours goes over when the pointer does; theirs arrives when it comes back.
            if (clipToSend) { clipToSend = false; SendClipboardIfChanged(); }
            string incoming; while (clipToSet.TryDequeue(out incoming)) { lastClip = incoming; DvClip.SetText(incoming); }   // never on this (input) thread
            if (!RemoteOwned && cloak.Visible) cloak.Hide();
            bool fwd = Forwarding || RemoteOwned;
            if (fwd != wasForwarding)
            {
                // Started or stopped forwarding: modifier tracking restarts from the real keyboard state, and
                // anything still held on the remote side is let go.
                wasForwarding = fwd;
                ctrl = (DvNative.GetAsyncKeyState(0x11) & 0x8000) != 0;
                alt = (DvNative.GetAsyncKeyState(0xA4) & 0x8000) != 0;
                if (!fwd) for (int b = 0; b < 5; b++) forwardedDown[b] = false;
            }
            // Re-register now and then so our hooks run before the engine's (it re-hooks when its core restarts)
            // and come back if Windows dropped them after a slow callback. Not while forwarding a stroke.
            if (!fwd && (DateTime.Now - lastReinstall).TotalSeconds > 5) { lastReinstall = DateTime.Now; InstallHooks(); }
        };
        t.Start();
        Application.Run();
        t.Stop();
        DvNative.UnhookWindowsHookEx(mouseHook); DvNative.UnhookWindowsHookEx(keyHook);
    }

    void NetLoop()
    {
        while (!stopping)
        {
            if (string.IsNullOrEmpty(Peer) || string.IsNullOrEmpty(Code)) { Thread.Sleep(500); continue; }
            TcpClient c = null;
            try
            {
                c = new TcpClient(Peer.Contains(":") ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork) { NoDelay = true };
                var ar = c.BeginConnect(Peer, Port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(3000)) throw new IOException("connect timeout");
                c.EndConnect(ar);
                c.ReceiveTimeout = 5000; c.SendTimeout = 5000;
                var s = c.GetStream();
                var keys = DvProto.ClientHandshake(s, Code);
                if (keys == null) { Status = "pairing code rejected by " + Peer + " (or it could not prove the code)"; Thread.Sleep(15000); continue; }
                string drained; while (queue.TryTake(out drained)) { }
                ulong seq = 0;
                Connected = true; Status = "connected to " + Peer + " (encrypted)";
                if (!string.IsNullOrEmpty(Name)) DvProto.WriteFrame(s, keys, ++seq, "N " + Name.Replace(' ', '_'));   // who we are
                if (!string.IsNullOrEmpty(Monitor)) DvProto.WriteFrame(s, keys, ++seq, "S " + Monitor);
                // The agent's messages (pointer handed back, its clipboard) on their own thread: no added delay.
                readerDead = false;
                var reader = new Thread(() =>
                {
                    ulong rseq = 0;
                    try { while (!stopping) OnAgentMessage(DvProto.ReadFrame(s, keys, ref rseq, DvProto.MaxFileFrame)); }
                    catch { }
                    readerDead = true;
                }) { IsBackground = true, Name = "DeskViewForwarderRead" };
                c.ReceiveTimeout = 0;                              // the agent may stay quiet for a long time
                reader.Start();
                DateTime lastPing = DateTime.Now;
                while (!stopping)
                {
                    // A closed link is noticed within 100 ms, so input goes back to this machine instead of into it.
                    if (readerDead) throw new IOException("the other machine closed the link");
                    string msg;
                    if (queue.TryTake(out msg, 100)) { DvProto.WriteFrame(s, keys, ++seq, msg); while (queue.TryTake(out msg)) DvProto.WriteFrame(s, keys, ++seq, msg); }
                    if ((DateTime.Now - lastPing).TotalSeconds > 5) { DvProto.WriteFrame(s, keys, ++seq, "P"); lastPing = DateTime.Now; }
                }
            }
            catch (Exception e) { Status = "not connected (" + e.Message + ")"; }
            finally
            {
                Connected = false; if (c != null) try { c.Close(); } catch { }
                if (RemoteOwned) ComeBack(32768);                 // link lost: the pointer returns to this machine
            }
            if (!stopping) Thread.Sleep(1000);
        }
    }

    bool InPicture(int x, int y) { return x >= VidL && x < VidL + VidW && y >= VidT && y < VidT + VidH; }

    static int ButtonOf(int msg, uint mouseData)
    {
        switch (msg)
        {
            case 0x0201: case 0x0202: return 0;
            case 0x0204: case 0x0205: return 1;
            case 0x0207: case 0x0208: return 2;
            case 0x020B: case 0x020C: return (mouseData >> 16) == 1 ? 3 : 4;
        }
        return -1;
    }

    IntPtr MouseHook(int code, IntPtr w, IntPtr l)
    {
        IntPtr prev = DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        try
        {
            if (code >= 0 && Connected && (RemoteOwned || (Edge != "" && (int)w == 0x0200)))
            {
                var m = (DvNative.MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(DvNative.MSLLHOOKSTRUCT));
                bool injected = (m.flags & 0x1) != 0;
                if ((!injected || AcceptInjected || CountInjected) && m.extra != DvNative.AgentMarker)
                {
                    if (RemoteOwned) { RemoteMouse((int)w, m); return (IntPtr)1; }       // all of it happens over there
                    if (TryEnter(m.pt.X, m.pt.Y)) return (IntPtr)1;
                }
            }
            if (code >= 0 && Forwarding && !RemoteOwned)   // over a picture of the other machine
            {
                var m = (DvNative.MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(DvNative.MSLLHOOKSTRUCT));
                bool injected = (m.flags & 0x1) != 0;
                if ((!injected || AcceptInjected || CountInjected) && m.extra != DvNative.AgentMarker)
                {
                    int msg = (int)w, x = m.pt.X, y = m.pt.Y;
                    bool inPic = InPicture(x, y);
                    if (msg == 0x0200)                                   // move: forward, let the local cursor move
                    {
                        if (inPic)
                        {
                            int nx = (int)Math.Round((x - VidL) * 65535.0 / Math.Max(1, VidW - 1));
                            int ny = (int)Math.Round((y - VidT) * 65535.0 / Math.Max(1, VidH - 1));
                            if (nx != lastNx || ny != lastNy) { lastNx = nx; lastNy = ny; Enqueue("M " + nx + " " + ny); }
                        }
                    }
                    else if (msg == 0x020A || msg == 0x020E)             // wheel: only over the picture
                    {
                        if (inPic) { Enqueue((msg == 0x020A ? "W " : "H ") + (short)(m.mouseData >> 16)); return (IntPtr)1; }
                    }
                    else
                    {
                        int b = ButtonOf(msg, m.mouseData);
                        bool down = msg == 0x0201 || msg == 0x0204 || msg == 0x0207 || msg == 0x020B;
                        if (b >= 0)
                        {
                            // A press over the picture goes remote, and so does its release wherever it happens;
                            // a press outside stays local together with its release. No stuck buttons either way.
                            if (down && inPic) { forwardedDown[b] = true; Enqueue("B " + b + " 1"); return (IntPtr)1; }
                            if (!down && forwardedDown[b]) { forwardedDown[b] = false; Enqueue("B " + b + " 0"); return (IntPtr)1; }
                        }
                    }
                }
            }
        }
        finally { if (prev != IntPtr.Zero) DvNative.SetThreadDpiAwarenessContext(prev); }
        return DvNative.CallNextHookEx(mouseHook, code, w, l);
    }

    /// <summary>The pointer touches the switching edge: hand pointer and keyboard to the other machine.
    /// Public for tests (they call it with made-up positions).</summary>
    public bool TryEnter(int x, int y)
    {
        if (RemoteOwned || !Connected || Edge == "") return false;
        var d = GetDesktop();
        if (!DvEdge.AtEdge(Edge, x, y, d)) return false;
        // Not while a button is held: dragging a window to the edge must not throw it to the other machine.
        if (!AcceptInjected && (Held(0x01) || Held(0x02) || Held(0x04))) return false;
        // Park the local pointer in the middle of its monitor (moves are measured from there), hidden.
        var mon = Screen.FromPoint(new System.Drawing.Point(x, y)).Bounds;
        parkX = mon.Left + mon.Width / 2; parkY = mon.Top + mon.Height / 2;
        ctrl = (DvNative.GetAsyncKeyState(0x11) & 0x8000) != 0;
        alt = (DvNative.GetAsyncKeyState(0xA4) & 0x8000) != 0;
        RemoteOwned = true;
        Interlocked.Increment(ref Switches);
        Enqueue("E " + Edge + " " + DvEdge.Along(Edge, x, y, d));
        clipToSend = true;
        if (!AcceptInjected)
        {
            DvNative.SetCursorPos(parkX, parkY);
            if (cloak != null) cloak.BeginInvoke((Action)(() => { cloak.Bounds = new System.Drawing.Rectangle(parkX - 40, parkY - 40, 80, 80); cloak.Show(); DvNative.SetCursorPos(parkX, parkY); }));
        }
        return true;
    }

    static bool Held(int vk) { return (DvNative.GetAsyncKeyState(vk) & 0x8000) != 0; }

    void RemoteMouse(int msg, DvNative.MSLLHOOKSTRUCT m)
    {
        if (msg == 0x0200)
        {
            int dx = m.pt.X - parkX, dy = m.pt.Y - parkY;     // the local pointer stays parked: this is the motion
            if (dx != 0 || dy != 0) Enqueue("R " + dx + " " + dy);
            return;
        }
        if (msg == 0x020A || msg == 0x020E) { Enqueue((msg == 0x020A ? "W " : "H ") + (short)(m.mouseData >> 16)); return; }
        int b = ButtonOf(msg, m.mouseData);
        if (b >= 0) Enqueue("B " + b + " " + ((msg == 0x0201 || msg == 0x0204 || msg == 0x0207 || msg == 0x020B) ? 1 : 0));
    }

    /// <summary>The pointer returns to this machine on the switching edge, at 'along' (0..65535).</summary>
    void ComeBack(int along)
    {
        if (!RemoteOwned) return;
        RemoteOwned = false;
        Interlocked.Increment(ref Switches);
        if (AcceptInjected || Edge == "") return;
        var pt = DvEdge.Place(Edge, along, GetDesktop(), 2);
        DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        DvNative.SetCursorPos(pt.X, pt.Y);
        if (cloak != null && cloak.IsHandleCreated) cloak.BeginInvoke((Action)(() => cloak.Hide()));
    }

    /// <summary>Take the pointer back without moving it (Ctrl+Alt+0, or switching turned off).</summary>
    public void TakeBack() { if (RemoteOwned) { Enqueue("X"); ComeBack(32768); } }

    void OnAgentMessage(string msg)
    {
        if (!msg.StartsWith("<")) throw new InvalidDataException("not from the agent");
        var p = msg.Substring(1).Split(' ');
        switch (p[0])
        {
            case "L": int a; if (p.Length > 1 && int.TryParse(p[1], out a)) ComeBack(Math.Max(0, Math.Min(65535, a))); break;
            case "CB": clipIn = new StringBuilder(); break;
            case "CD": if (clipIn != null && p.Length > 1) { clipIn.Append(p[1]); if (clipIn.Length > MaxClipboardBytes / 3 * 4 + 8) clipIn = null; } break;
            case "CE":
                if (clipIn != null)
                {
                    try { var text = Encoding.UTF8.GetString(Convert.FromBase64String(clipIn.ToString())); if (ShareClipboard) clipToSet.Enqueue(text); } catch (FormatException) { }
                    clipIn = null;
                }
                break;
        }
    }

    void SendClipboardIfChanged()
    {
        if (!ShareClipboard || !Connected) return;
        // Reading the clipboard can hang (another program's data it renders on request): on the clipboard thread,
        // with a time limit, never on this input thread.
        var text = DvClip.GetText(300);
        if (string.IsNullOrEmpty(text) || text == lastClip || Encoding.UTF8.GetByteCount(text) > MaxClipboardBytes) return;
        lastClip = text;
        foreach (var f in DvClip.Frames(text, "")) Enqueue(f);
    }

    /// <summary>A nearly invisible window with an empty cursor, under the parked pointer.</summary>
    class CloakForm : Form
    {
        static readonly Cursor Empty = MakeEmpty();
        static Cursor MakeEmpty()
        {
            var and = new byte[32 * 4]; for (int i = 0; i < and.Length; i++) and[i] = 0xFF;
            var h = DvNative.CreateCursor(IntPtr.Zero, 0, 0, 32, 32, and, new byte[32 * 4]);
            return h == IntPtr.Zero ? Cursors.Default : new Cursor(h);
        }
        public CloakForm()
        {
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; Opacity = 0.01;
            StartPosition = FormStartPosition.Manual; Size = new System.Drawing.Size(80, 80); Cursor = Empty;
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80 | 0x8; return cp; }   // NOACTIVATE | TOOLWINDOW | TOPMOST
        }
    }

    IntPtr KeyHook(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0)
        {
            var k = (DvNative.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(DvNative.KBDLLHOOKSTRUCT));
            bool injected = (k.flags & 0x10) != 0;
            bool down = ((int)w == 0x0100 || (int)w == 0x0104);   // WM_KEYDOWN / WM_SYSKEYDOWN
            int vk = (int)k.vkCode;
            bool physical = (!injected || AcceptInjected || CountInjected) && k.extra != DvNative.AgentMarker;
            bool fwd = Forwarding || (RemoteOwned && Connected);
            if (physical)
            {
                // Ctrl and the LEFT Alt only: AltGr arrives as LCtrl+RAlt and must keep typing { [ ] } etc.
                if (vk == 0xA2 || vk == 0xA3 || vk == 0x11) ctrl = down;
                if (vk == 0xA4) alt = down;
                if (vk == 0xA5) alt = false;
                // While forwarding we swallow Ctrl/Alt, so Windows' key state is stale: use what we tracked.
                // Otherwise ask Windows - our flags can miss releases (secure desktop, Win+L, Ctrl+Alt+Del).
                bool tracked = fwd || AcceptInjected;
                bool ctrlNow = tracked ? ctrl : (DvNative.GetAsyncKeyState(0x11) & 0x8000) != 0;
                bool altNow = tracked ? alt : (DvNative.GetAsyncKeyState(0xA4) & 0x8000) != 0;
                // DeskView's own hotkeys (Ctrl+Alt+0..9 / D) are always handled here, on the machine you sit at,
                // never forwarded - and keys that the engine injects from the other machine never count.
                if (HotkeysEnabled && ctrlNow && altNow && ((vk >= 0x30 && vk <= 0x39) || vk == 0x44))
                {
                    if (down)
                    {
                        if (fwd) { Enqueue("K 162 29 0 0"); Enqueue("K 163 29 1 0"); Enqueue("K 164 56 0 0"); Enqueue("K 165 56 1 0"); }
                        if (vk == 0x30) TakeBack();                     // Ctrl+Alt+0 always brings the pointer home
                        Interlocked.Exchange(ref pendingHotkey, vk);
                    }
                    return (IntPtr)1;
                }
            }
            if (fwd && physical)
            {
                bool ext = (k.flags & 0x1) != 0;
                Enqueue("K " + vk + " " + k.scanCode + " " + (ext ? 1 : 0) + " " + (down ? 1 : 0));
                return (IntPtr)1;                                         // the key only happens remotely
            }
        }
        return DvNative.CallNextHookEx(keyHook, code, w, l);
    }
}

/// <summary>Finding the other computer on the local network without any other software: the client broadcasts
/// a probe sealed with the pairing code (HMAC over a fresh nonce); only a server with the same code answers, and its
/// answer proves it knows the code too, so nobody can pose as the server. UDP port 9010, local network only.</summary>
public class DeskViewDiscovery
{
    public int Port = 9010;
    public string Code = "";
    public string Name = Environment.MachineName;
    public volatile string Found;                 // client: the server's address once found (null until then)
    public volatile string FoundName;
    public volatile string Status = "idle";
    public int Answered;
    public bool Running { get { var t = thread; return t != null && t.IsAlive; } }                          // server: probes answered (tests)

    UdpClient udp;
    Thread thread;
    volatile bool stopping;

    static string Hex(byte[] b) { var sb = new StringBuilder(b.Length * 2); foreach (var x in b) sb.Append(x.ToString("x2")); return sb.ToString(); }
    static byte[] Unhex(string s)
    {
        if (s == null || s.Length % 2 != 0 || s.Length > 128) return null;
        var b = new byte[s.Length / 2];
        for (int i = 0; i < b.Length; i++) { int v; if (!int.TryParse(s.Substring(i * 2, 2), System.Globalization.NumberStyles.HexNumber, null, out v)) return null; b[i] = (byte)v; }
        return b;
    }

    /// <summary>Server: answer probes that carry the right pairing code.</summary>
    public void StartResponder()
    {
        Stop(); stopping = false;
        udp = new UdpClient(new IPEndPoint(IPAddress.Any, Port));
        thread = new Thread(() =>
        {
            Status = "answering on UDP " + Port;
            while (!stopping)
            {
                try
                {
                    var from = new IPEndPoint(IPAddress.Any, 0);
                    var data = udp.Receive(ref from);
                    var p = Encoding.ASCII.GetString(data, 0, Math.Min(data.Length, 300)).Split(' ');
                    if (p.Length != 3 || p[0] != "DVD1") continue;
                    var nonce = Unhex(p[1]); var mac = Unhex(p[2]);
                    if (nonce == null || nonce.Length != 16 || mac == null) continue;
                    var key = DvProto.PairKey(Code);
                    if (!DvProto.SameBytes(mac, DvProto.Hmac(key, DvProto.Ascii("probe"), nonce))) continue;
                    var safeName = System.Text.RegularExpressions.Regex.Replace(Name ?? "", @"[^\w\-.]", "");
                    if (safeName.Length > 40) safeName = safeName.Substring(0, 40);
                    var reply = "DVD1R " + safeName + " " + Hex(DvProto.Hmac(key, DvProto.Ascii("reply"), nonce, Encoding.UTF8.GetBytes(safeName)));
                    var bytes = Encoding.ASCII.GetBytes(reply);
                    udp.Send(bytes, bytes.Length, from);
                    Interlocked.Increment(ref Answered);
                }
                catch { if (stopping) return; Thread.Sleep(100); }
            }
        }) { IsBackground = true, Name = "DeskViewDiscovery" };
        thread.Start();
    }

    /// <summary>Client: keep asking (every 3 s) until a server with this pairing code answers.</summary>
    public void StartSeeker(string[] targets)
    {
        Stop(); stopping = false; Found = null;
        udp = new UdpClient(new IPEndPoint(IPAddress.Any, 0)) { EnableBroadcast = true };
        udp.Client.ReceiveTimeout = 1000;
        thread = new Thread(() =>
        {
            var key = DvProto.PairKey(Code);
            while (!stopping && Found == null)
            {
                try
                {
                    var nonce = DvProto.Random(16);
                    var probe = Encoding.ASCII.GetBytes("DVD1 " + Hex(nonce) + " " + Hex(DvProto.Hmac(key, DvProto.Ascii("probe"), nonce)));
                    foreach (var t in targets)
                        try { udp.Send(probe, probe.Length, new IPEndPoint(IPAddress.Parse(t), Port)); } catch { }
                    Status = "looking for the server on the local network";
                    var end = DateTime.UtcNow.AddSeconds(3);
                    while (!stopping && DateTime.UtcNow < end)
                    {
                        IPEndPoint from = new IPEndPoint(IPAddress.Any, 0); byte[] data;
                        try { data = udp.Receive(ref from); } catch (SocketException) { continue; }
                        var p = Encoding.ASCII.GetString(data, 0, Math.Min(data.Length, 300)).Split(' ');
                        if (p.Length != 3 || p[0] != "DVD1R") continue;
                        var mac = Unhex(p[2]);
                        if (mac == null || !DvProto.SameBytes(mac, DvProto.Hmac(key, DvProto.Ascii("reply"), nonce, Encoding.UTF8.GetBytes(p[1])))) continue;
                        FoundName = p[1]; Found = from.Address.ToString(); Status = "found " + p[1] + " at " + Found;
                        return;
                    }
                }
                catch { if (stopping) return; Thread.Sleep(500); }
            }
        }) { IsBackground = true, Name = "DeskViewDiscovery" };
        thread.Start();
    }

    /// <summary>Where to send probes: the broadcast address of every local IPv4 network.</summary>
    public static string[] BroadcastTargets()
    {
        var list = new List<string> { "255.255.255.255" };
        try
        {
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask == null || IPAddress.IsLoopback(ua.Address)) continue;
                    var a = ua.Address.GetAddressBytes(); var m = ua.IPv4Mask.GetAddressBytes(); var b = new byte[4];
                    for (int i = 0; i < 4; i++) b[i] = (byte)(a[i] | ~m[i]);
                    var s = new IPAddress(b).ToString();
                    if (!list.Contains(s)) list.Add(s);
                }
            }
        }
        catch { }
        return list.ToArray();
    }

    public void Stop()
    {
        stopping = true;
        try { if (udp != null) udp.Close(); } catch { }
        if (thread != null && thread != Thread.CurrentThread) thread.Join(1500);
        thread = null; udp = null;
    }
}

/// <summary>Sends files and folders to the other machine's agent over an encrypted, authenticated file session.</summary>
public static class DeskViewFiles
{
    /// <summary>Returns null on success, else what went wrong.</summary>
    public static string Send(string peer, int port, string code, string[] paths, Action<string> progress)
    {
        var items = new List<KeyValuePair<string, string>>();   // full path -> relative name on the other side
        foreach (var p in paths)
        {
            if (File.Exists(p)) items.Add(new KeyValuePair<string, string>(p, Path.GetFileName(p)));
            else if (Directory.Exists(p))
            {
                // same spelling as the enumerated paths (GetFullPath would expand 8.3 short names and shift the cut)
                var root = Path.GetDirectoryName(p.TrimEnd('\\'));
                foreach (var f in Directory.EnumerateFiles(p, "*", SearchOption.AllDirectories))
                    items.Add(new KeyValuePair<string, string>(f, f.Substring(root.Length).TrimStart('\\').Replace('\\', '/')));
            }
        }
        if (items.Count == 0) return "nothing to send";
        using (var c = new TcpClient(peer.Contains(":") ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork) { NoDelay = true })
        {
            var ar = c.BeginConnect(peer, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(4000)) return "the other machine did not answer";
            c.EndConnect(ar);
            c.ReceiveTimeout = 10000; c.SendTimeout = 30000;
            var s = c.GetStream();
            var keys = DvProto.ClientHandshake(s, code);
            if (keys == null) return "the other machine refused the pairing code";
            ulong seq = 0;
            DvProto.WriteFrame(s, keys, ++seq, "FILES");
            long total = 0, sent = 0; foreach (var it in items) total += new FileInfo(it.Key).Length;
            var buf = new byte[32 * 1024];
            int n = 0;
            foreach (var it in items)
            {
                n++;
                var len = new FileInfo(it.Key).Length;
                DvProto.WriteFrame(s, keys, ++seq, "F " + Convert.ToBase64String(Encoding.UTF8.GetBytes(it.Value)) + " " + len);
                using (var fs = new FileStream(it.Key, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    int r;
                    while ((r = fs.Read(buf, 0, buf.Length)) > 0)
                    {
                        DvProto.WriteFrame(s, keys, ++seq, "D " + Convert.ToBase64String(buf, 0, r));
                        sent += r;
                        if (progress != null) progress(string.Format("{0}/{1}: {2} ({3:0}%)", n, items.Count, it.Value, total == 0 ? 100 : sent * 100.0 / total));
                    }
                }
                DvProto.WriteFrame(s, keys, ++seq, "E");
            }
            DvProto.WriteFrame(s, keys, ++seq, "BYE");
            s.Flush();
            return null;
        }
    }
}

/// <summary>A file transfer running in the background (the UI polls Status / Done / Error).</summary>
public class DeskViewTransfer
{
    public volatile string Status = "starting", Error;
    public volatile bool Done;
    public string[] Paths;
    public static DeskViewTransfer Start(string peer, int port, string code, string[] paths)
    {
        var t = new DeskViewTransfer { Paths = paths };
        new Thread(() =>
        {
            try { t.Error = DeskViewFiles.Send(peer, port, code, paths, s => t.Status = s); }
            catch (Exception e) { t.Error = e.Message; }
            t.Done = true;
        }) { IsBackground = true, Name = "DeskViewTransfer" }.Start();
        return t;
    }
}

/// <summary>Invisible window over the other computer's picture that catches files dragged onto it.
/// It never takes focus; while files are dragged over it, it lights up and says where they go.</summary>
public class DeskViewDropZone : Form
{
    public string Target = "the other computer";
    public event Action<string[]> Dropped;
    bool hot;

    public DeskViewDropZone()
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        BackColor = System.Drawing.Color.FromArgb(37, 99, 235); Opacity = 0.01;   // nearly invisible, still a drop target
        AllowDrop = true; DoubleBuffered = true;
        DragEnter += (s, e) =>
        {
            if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
            e.Effect = DragDropEffects.Copy; hot = true; Opacity = 0.6; Invalidate();
        };
        DragLeave += (s, e) => Cool();
        DragDrop += (s, e) =>
        {
            Cool();
            var files = e.Data.GetData(DataFormats.FileDrop) as string[];
            if (files != null && files.Length > 0 && Dropped != null) Dropped(files);
        };
    }

    void Cool() { hot = false; Opacity = 0.01; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (!hot) return;
        using (var f = new System.Drawing.Font("Segoe UI Semibold", 28f))
        using (var b = new System.Drawing.SolidBrush(System.Drawing.Color.White))
            e.Graphics.DrawString("Drop to send to " + Target, f, b, ClientRectangle,
                new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Center, LineAlignment = System.Drawing.StringAlignment.Center });
    }

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80; return cp; }   // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
    }

    public void Place(System.Drawing.Rectangle r)
    {
        if (Bounds != r) Bounds = r;
        if (!Visible) Show();
    }
}