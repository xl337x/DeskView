// DeskView reverse control channel (the direction Deskflow can't do at the same time).
//
//   DeskViewAgent      on the machine being viewed: accepts one authenticated viewer over TCP and replays
//                      its mouse / keyboard input locally; can be asked which monitor to stream.
//   DeskViewForwarder  on the machine you sit at: while viewing, captures your *physical* input with
//                      low-level hooks and sends it to the agent. The local cursor keeps moving over the
//                      picture (instant pointer, no video lag); clicks, wheel and keys are swallowed locally
//                      and only happen on the remote machine. Ctrl+Alt+0..9 / D stay local (DeskView hotkeys).
//
// Wire format: UTF-8 lines.  Viewer -> agent:  HELLO <code> | S <DISPLAYn> | M <nx> <ny> (0..65535 within the
// streamed monitor) | B <button 0-4> <1 down/0 up> | W <delta> | H <delta> | K <vk> <scan> <ext 0/1> <1/0> | P
// Agent -> viewer:  OK | NO | PONG
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
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
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string n);

    public static readonly IntPtr PerMonitorV2 = new IntPtr(-4);
    public static readonly IntPtr AgentMarker = new IntPtr(0x44564147);   // 'DVAG': input replayed by the agent
}

public class DeskViewAgent
{
    public int Port = 9002;
    public string Code = "";                    // pairing code the viewer must present
    public string[] AllowedIps = new string[0];  // empty = any address on the LAN (code still required)
    public volatile int TL, TT, TW = 1, TH = 1;  // streamed monitor, physical pixels
    public volatile int VL, VR;                  // local desktop left/right
    public volatile bool AvoidLeftEdge, AvoidRightEdge;  // outer edges Deskflow links to the other machine
    public volatile string RequestedMonitor;     // set by "S"; the host restarts its stream for it
    public volatile string Status = "idle";
    public volatile string Client = "";
    public int Moves, Buttons, Keys;             // counters (diagnostics / tests)

    TcpListener listener;
    Thread thread;
    volatile bool stopping;
    readonly HashSet<int> heldButtons = new HashSet<int>();
    readonly HashSet<string> heldKeys = new HashSet<string>();

    public void Start()
    {
        if (thread != null) return;
        stopping = false;
        listener = new TcpListener(IPAddress.Any, Port);
        listener.Start();
        thread = new Thread(Run) { IsBackground = true, Name = "DeskViewAgent" };
        thread.Start();
        Status = "listening on " + Port;
    }

    public void Stop()
    {
        stopping = true;
        try { listener.Stop(); } catch { }
        if (thread != null) thread.Join(2000);
        thread = null;
    }

    void Run()
    {
        DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        while (!stopping)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { if (stopping) return; Thread.Sleep(200); continue; }
            try { Serve(c); } catch { }
            finally { ReleaseAll(); try { c.Close(); } catch { } Client = ""; Status = "listening on " + Port; }
        }
    }

    void Serve(TcpClient c)
    {
        string ip = ((IPEndPoint)c.Client.RemoteEndPoint).Address.ToString();
        if (AllowedIps.Length > 0 && Array.IndexOf(AllowedIps, ip) < 0) { Status = "refused " + ip; return; }
        c.NoDelay = true;
        var stream = c.GetStream();
        var reader = new StreamReader(stream, Encoding.UTF8);
        var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
        c.ReceiveTimeout = 10000;
        string hello = reader.ReadLine();
        if (hello == null || !hello.StartsWith("HELLO ") || !FixedEquals(hello.Substring(6).Trim(), Code)) { writer.WriteLine("NO"); Status = "bad code from " + ip; return; }
        writer.WriteLine("OK");
        c.ReceiveTimeout = 30000;                 // viewer pings every few seconds
        Client = ip; Status = "controlled by " + ip;
        string line;
        while (!stopping && (line = reader.ReadLine()) != null) Handle(line, writer);
    }

    static bool FixedEquals(string a, string b)
    {
        if (string.IsNullOrEmpty(b) || a.Length != b.Length) return false;
        int d = 0; for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i]; return d == 0;
    }

    void Handle(string line, StreamWriter writer)
    {
        var p = line.Split(' ');
        try
        {
            switch (p[0])
            {
                case "M":
                {
                    int x = TL + (int)Math.Round(int.Parse(p[1]) * (TW - 1) / 65535.0);
                    int y = TT + (int)Math.Round(int.Parse(p[2]) * (TH - 1) / 65535.0);
                    // Keep off outer edges that Deskflow links to the other machine, or it would switch.
                    if (AvoidRightEdge && x >= VR - 2) x = VR - 3;
                    if (AvoidLeftEdge && x <= VL + 1) x = VL + 2;
                    DvNative.SetCursorPos(x, y);   // no hook event: Deskflow and the portal don't react
                    Moves++;
                    break;
                }
                case "B": Button(int.Parse(p[1]), p[2] == "1"); Buttons++; break;
                case "W": Mouse(0x0800, int.Parse(p[1])); break;
                case "H": Mouse(0x1000, int.Parse(p[1])); break;
                case "K": Key(ushort.Parse(p[1]), ushort.Parse(p[2]), p[3] == "1", p[4] == "1"); Keys++; break;
                case "S": RequestedMonitor = p.Length > 1 ? p[1] : null; break;
                case "P": writer.WriteLine("PONG"); break;
            }
        }
        catch (FormatException) { }
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
    public string Peer = "", Code = "", Monitor = "";
    public int Port = 9002;
    public volatile int VidL, VidT, VidW = 1, VidH = 1;   // where the remote picture is on this machine (physical px)
    public volatile bool Active;                          // forward input only while viewing
    public bool AcceptInjected;                           // tests only: also forward synthetic input
    public volatile int PendingHotkey;                    // vk of a physical Ctrl+Alt+0..9 / D press (0 = none); caller resets it
    public volatile bool HotkeysEnabled = true;           // detect DeskView hotkeys from the physical keyboard only
    public volatile string Status = "idle";
    public volatile bool Connected;

    Thread hookThread, netThread;
    volatile bool stopping;
    DvNative.HookProc mouseProc, keyProc;
    IntPtr mouseHook, keyHook, mod;
    readonly BlockingCollection<string> queue = new BlockingCollection<string>(new ConcurrentQueue<string>(), 4096);
    bool ctrl, alt;
    int lastNx = -1, lastNy = -1;

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

    void HookLoop()
    {
        DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        mouseProc = MouseHook; keyProc = KeyHook;
        mod = DvNative.GetModuleHandle(null);
        mouseHook = DvNative.SetWindowsHookEx(14, mouseProc, mod, 0);   // WH_MOUSE_LL
        keyHook = DvNative.SetWindowsHookEx(13, keyProc, mod, 0);       // WH_KEYBOARD_LL
        var t = new System.Windows.Forms.Timer { Interval = 100 };
        DateTime lastReinstall = DateTime.Now;
        t.Tick += delegate
        {
            if (stopping) { Application.ExitThread(); return; }
            // Stay ahead of Deskflow's hooks (it re-hooks whenever its core restarts) so our hotkeys work
            // even while Deskflow has the cursor on the other machine. Not while forwarding a key stroke.
            if (!Active && (DateTime.Now - lastReinstall).TotalSeconds > 5)
            {
                lastReinstall = DateTime.Now;
                DvNative.UnhookWindowsHookEx(mouseHook); DvNative.UnhookWindowsHookEx(keyHook);
                mouseHook = DvNative.SetWindowsHookEx(14, mouseProc, mod, 0);
                keyHook = DvNative.SetWindowsHookEx(13, keyProc, mod, 0);
            }
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
            if (string.IsNullOrEmpty(Peer)) { Thread.Sleep(500); continue; }
            TcpClient c = null;
            try
            {
                c = new TcpClient { NoDelay = true };
                var ar = c.BeginConnect(Peer, Port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(3000)) throw new IOException("connect timeout");
                c.EndConnect(ar);
                var s = c.GetStream();
                var w = new StreamWriter(s, new UTF8Encoding(false)) { NewLine = "\n" };
                var r = new StreamReader(s, Encoding.UTF8);
                w.WriteLine("HELLO " + Code); w.Flush();
                c.ReceiveTimeout = 5000;
                string ans = r.ReadLine();
                if (ans != "OK") { Status = "pairing code rejected by " + Peer; Thread.Sleep(5000); continue; }
                string drained; while (queue.TryTake(out drained)) { }
                Connected = true; Status = "connected to " + Peer;
                if (!string.IsNullOrEmpty(Monitor)) { w.WriteLine("S " + Monitor); w.Flush(); }
                DateTime lastPing = DateTime.Now;
                while (!stopping)
                {
                    string msg;
                    if (queue.TryTake(out msg, 500)) { w.WriteLine(msg); while (queue.TryTake(out msg)) w.WriteLine(msg); w.Flush(); }
                    if ((DateTime.Now - lastPing).TotalSeconds > 5) { w.WriteLine("P"); w.Flush(); lastPing = DateTime.Now; }
                }
            }
            catch (Exception e) { Status = "not connected (" + e.Message + ")"; }
            finally { Connected = false; if (c != null) try { c.Close(); } catch { } }
            if (!stopping) Thread.Sleep(1000);
        }
    }

    bool InPicture(int x, int y) { return x >= VidL && x < VidL + VidW && y >= VidT && y < VidT + VidH; }

    IntPtr MouseHook(int code, IntPtr w, IntPtr l)
    {
        IntPtr prev = DvNative.SetThreadDpiAwarenessContext(DvNative.PerMonitorV2);
        try
        {
            if (code >= 0 && Active)
            {
                var m = (DvNative.MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(DvNative.MSLLHOOKSTRUCT));
                bool injected = (m.flags & 0x1) != 0;
                if ((!injected || AcceptInjected) && m.extra != DvNative.AgentMarker)
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
                    else if (inPic)
                    {
                        switch (msg)
                        {
                            case 0x0201: Enqueue("B 0 1"); break;  case 0x0202: Enqueue("B 0 0"); break;
                            case 0x0204: Enqueue("B 1 1"); break;  case 0x0205: Enqueue("B 1 0"); break;
                            case 0x0207: Enqueue("B 2 1"); break;  case 0x0208: Enqueue("B 2 0"); break;
                            case 0x020B: Enqueue("B " + ((m.mouseData >> 16) == 1 ? 3 : 4) + " 1"); break;
                            case 0x020C: Enqueue("B " + ((m.mouseData >> 16) == 1 ? 3 : 4) + " 0"); break;
                            case 0x020A: Enqueue("W " + (short)(m.mouseData >> 16)); break;
                            case 0x020E: Enqueue("H " + (short)(m.mouseData >> 16)); break;
                        }
                        return (IntPtr)1;                                 // click/wheel happens remotely only
                    }
                }
            }
        }
        finally { if (prev != IntPtr.Zero) DvNative.SetThreadDpiAwarenessContext(prev); }
        return DvNative.CallNextHookEx(mouseHook, code, w, l);
    }

    IntPtr KeyHook(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0)
        {
            var k = (DvNative.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(DvNative.KBDLLHOOKSTRUCT));
            bool injected = (k.flags & 0x10) != 0;
            bool down = ((int)w == 0x0100 || (int)w == 0x0104);   // WM_KEYDOWN / WM_SYSKEYDOWN
            int vk = (int)k.vkCode;
            bool physical = (!injected || AcceptInjected) && k.extra != DvNative.AgentMarker;
            if (physical)
            {
                if (vk == 0xA2 || vk == 0xA3 || vk == 0x11) ctrl = down;
                if (vk == 0xA4 || vk == 0xA5 || vk == 0x12) alt = down;
                // DeskView's own hotkeys (Ctrl+Alt+0..9 / D) are always handled here, on the machine you sit at,
                // never forwarded - and keys that Deskflow injects from the other machine never count.
                if (HotkeysEnabled && ctrl && alt && ((vk >= 0x30 && vk <= 0x39) || vk == 0x44))
                {
                    if (down)
                    {
                        if (Active) { Enqueue("K 162 29 0 0"); Enqueue("K 163 29 1 0"); Enqueue("K 164 56 0 0"); Enqueue("K 165 56 1 0"); }
                        PendingHotkey = vk;
                    }
                    return (IntPtr)1;
                }
            }
            if (Active && physical)
            {
                bool ext = (k.flags & 0x1) != 0;
                Enqueue("K " + vk + " " + k.scanCode + " " + (ext ? 1 : 0) + " " + (down ? 1 : 0));
                return (IntPtr)1;                                         // the key only happens remotely
            }
        }
        return DvNative.CallNextHookEx(keyHook, code, w, l);
    }
}
