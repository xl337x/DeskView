// DeskView Portal - makes the monitor showing the remote screen behave like the remote machine's own display.
//
// Deskflow only switches machines at the outer edges of the server's desktop. The portal watches the mouse
// (low-level hook, own thread) and, the moment the cursor enters the portal monitor, puts it on the outer edge
// that Deskflow links to the remote machine and nudges it, so Deskflow hands keyboard + mouse to the remote
// machine at the matching height. When Deskflow hands control back (read from its log), the cursor is placed
// just outside the portal monitor on the side it left from.
//
// Deskflow links required (written by DeskView.ps1):
//   portal has a monitor on its left  -> LOCAL: right = REMOTE ; REMOTE: left = LOCAL
//   portal has a monitor on its right -> LOCAL: left = REMOTE  ; REMOTE: right = LOCAL
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class DeskViewPortal
{
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int cb);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    const int WH_MOUSE_LL = 14, WM_MOUSEMOVE = 0x200;
    static readonly IntPtr Marker = new IntPtr(0x44565057);   // tags our own injected nudge
    static readonly IntPtr PerMonitorV2 = new IntPtr(-4);

    enum State { Local, Pending, Remote }

    // Configuration (physical pixels). Right/bottom are exclusive.
    public volatile bool Enabled;
    public int PL, PT, PR, PB;      // portal monitor
    public int VL, VR, VT, VB;      // whole local desktop
    public string LocalName = Environment.MachineName, RemoteName = "";   // Deskflow screen names
    public string LogPath = @"C:\ProgramData\Deskflow\deskflow-daemon.log";
    public string Status = "idle";

    // Where the remote picture is drawn inside the portal monitor (it may be letterboxed), and the remote
    // desktop's height in pixels (from the video stream). RemoteH = 0 means unknown: heights map 1:1.
    public int VidT, VidH, RemoteH;
    // How Deskflow translates heights across each local outer edge: remoteY = k * localY. Equal-height
    // screens give 1; Deskflow may scale proportionally when heights differ, so it is learned per edge
    // from every hand-over (the log reports where the cursor landed on the remote machine).
    public double KRight = 1.0, KLeft = 1.0;

    public string DebugLog;         // optional path; when set, state changes are appended here

    void Log(string s) { if (DebugLog != null) try { File.AppendAllText(DebugLog, DateTime.Now.ToString("HH:mm:ss.fff") + " " + s + Environment.NewLine); } catch { } }

    bool HasLeft  { get { return PL > VL; } }
    bool HasRight { get { return PR < VR; } }

    HookProc proc;
    IntPtr hook;
    Thread thread;
    System.Windows.Forms.Timer timer;
    volatile bool stopRequested, reinstallRequested;
    State state = State.Local;
    DateTime pendingSince, cooldownUntil, lastReinstall, lastMoveLog;
    int lastX = int.MinValue, pendingBackX, pendingBackY, sentY;
    bool pendingViaRight;
    long logPos;
    readonly StringBuilder logTail = new StringBuilder();
    static readonly Regex SwitchRx = new Regex("switch from \"(?<from>[^\"]+)\" to \"(?<to>[^\"]+)\" at (?<x>-?\\d+),(?<y>-?\\d+)");

    // --- child processes die with DeskView (Windows job object with KILL_ON_JOB_CLOSE) ---
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic; public IO_COUNTERS Io; public UIntPtr p, q, r, s; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint len);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    static IntPtr job;

    /// <summary>Kill this process automatically when DeskView exits, however it exits (even a crash).</summary>
    public static void KillWithMe(System.Diagnostics.Process p)
    {
        if (p == null) return;
        if (job == IntPtr.Zero)
        {
            job = CreateJobObject(IntPtr.Zero, null);
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
        }
        try { AssignProcessToJobObject(job, p.Handle); } catch { }
    }

    /// <summary>Make the calling thread use physical pixel coordinates.</summary>
    public static void UsePhysicalPixels() { SetThreadDpiAwarenessContext(PerMonitorV2); }

    /// <summary>Stop a window taking focus or appearing in Alt+Tab / the taskbar.</summary>
    public static void MakePassive(IntPtr hwnd)
    {
        const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_APPWINDOW = 0x40000;
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) & ~WS_EX_APPWINDOW);
        // ffplay's -alwaysontop doesn't stick: make the picture topmost ourselves (HWND_TOPMOST, no move/size/activate).
        SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }

    public void Start()
    {
        if (thread != null) return;
        stopRequested = false;
        thread = new Thread(Run) { IsBackground = true, Name = "DeskViewPortal" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    public void Stop() { stopRequested = true; if (thread != null) thread.Join(2000); thread = null; }

    /// <summary>Re-register the hook so it runs before Deskflow's (call after Deskflow restarts).</summary>
    public void Reinstall() { reinstallRequested = true; }

    void Run()
    {
        UsePhysicalPixels();
        proc = Hook;
        try { logPos = new FileInfo(LogPath).Length; } catch { logPos = 0; }
        InstallHook();
        timer = new System.Windows.Forms.Timer { Interval = 25 };
        timer.Tick += delegate { Tick(); };
        timer.Start();
        Application.Run();
        timer.Stop();
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    void InstallHook()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(null), 0);
        lastReinstall = DateTime.Now;
        if (hook == IntPtr.Zero) Log("hook install FAILED err=" + Marshal.GetLastWin32Error());
    }

    IntPtr Hook(int code, IntPtr w, IntPtr l)
    {
        // Low-level hook callbacks don't run in the thread's DPI context: without this, cursor moves made
        // here are DPI-virtualised and land 1.5x off on a 150% monitor.
        IntPtr prevCtx = SetThreadDpiAwarenessContext(PerMonitorV2);
        try { return HookCore(code, w, l); }
        finally { if (prevCtx != IntPtr.Zero) SetThreadDpiAwarenessContext(prevCtx); }
    }

    IntPtr HookCore(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0 && Enabled && (int)w == WM_MOUSEMOVE)
        {
            var m = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(MSLLHOOKSTRUCT));
            if (m.extra != Marker)
            {
                int x = m.pt.X, y = m.pt.Y;
                if (DebugLog != null && (DateTime.Now - lastMoveLog).TotalMilliseconds > 150) { lastMoveLog = DateTime.Now; Log("move " + x + "," + y + " state " + state + " enabled " + Enabled); }
                if (state == State.Pending) return (IntPtr)1;        // waiting for Deskflow to take over
                if (state == State.Local)
                {
                    bool inPortal = x >= PL && x < PR && y >= PT && y < PB;
                    if (inPortal && DateTime.Now >= cooldownUntil)
                    {
                        bool fromRight = lastX != int.MinValue ? lastX >= PR : x >= (PL + PR) / 2;
                        bool viaRightLink = HasLeft && (!fromRight || !HasRight);
                        if (viaRightLink) Enter(VR - 1, y, +4, PL - 2, true);
                        else if (HasRight) Enter(VL, y, -4, PR + 1, false);
                        return (IntPtr)1;
                    }
                    // Portal in the middle: both outer edges are linked to the remote machine, so keep the
                    // cursor off them - the remote machine is reached through the portal monitor only.
                    if (HasLeft && HasRight)
                    {
                        if (x >= VR - 2) { MoveTo(VR - 3, y); return (IntPtr)1; }
                        if (x <= VL + 1) { MoveTo(VL + 2, y); return (IntPtr)1; }
                    }
                    if (!inPortal) lastX = x;
                }
            }
        }
        return CallNextHookEx(hook, code, w, l);
    }

    static void Send(int dx, int dy, uint flags)
    {
        var input = new INPUT[1];
        input[0].type = 0;
        input[0].mi.dx = dx; input[0].mi.dy = dy;
        input[0].mi.flags = flags;
        input[0].mi.extra = Marker;
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
    }

    // Callers run in a per-monitor DPI context (hook wrapper / portal thread), so these are physical pixels.
    static void MoveTo(int x, int y) { SetCursorPos(x, y); }

    static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

    // Local y on the portal monitor -> remote y, by proportion of the picture actually shown.
    int RemoteYFor(int y)
    {
        if (RemoteH <= 0 || VidH <= 1) return y - PT;
        double f = (y - VidT) / (double)(VidH - 1);
        return (int)Math.Round(Math.Max(0, Math.Min(1, f)) * (RemoteH - 1));
    }

    // Remote y -> local y on the portal monitor.
    int LocalYFor(int remoteY)
    {
        if (RemoteH <= 0 || VidH <= 1) return Clamp(PT + remoteY, PT, PB - 1);
        double f = remoteY / (double)Math.Max(1, RemoteH - 1);
        return Clamp(VidT + (int)Math.Round(Math.Max(0, Math.Min(1, f)) * (VidH - 1)), PT, PB - 1);
    }

    void Enter(int edgeX, int y, int nudge, int backX, bool viaRight)
    {
        // Pick the height on Deskflow's edge that lands the remote cursor where the user is pointing.
        double k = viaRight ? KRight : KLeft;
        sentY = Clamp(VT + (int)Math.Round(RemoteYFor(y) / k), VT, VB - 1);
        pendingViaRight = viaRight;
        Log("enter portal y=" + y + " -> edge " + edgeX + "," + sentY + " (k=" + k + ", remoteH=" + RemoteH + ", vid " + VidT + "+" + VidH + ")");
        pendingBackX = backX; pendingBackY = y;
        MoveTo(edgeX, sentY);
        Send(nudge, 0, 0x0001);                                    // relative push across Deskflow's edge
        state = State.Pending;
        pendingSince = DateTime.Now;
    }

    void Tick()
    {
        if (stopRequested) { Application.ExitThread(); return; }
        ReadLog();

        if (state == State.Pending && (DateTime.Now - pendingSince).TotalMilliseconds > 700)
        {
            // Deskflow didn't switch (remote machine not connected?) - put the cursor back and back off.
            MoveTo(pendingBackX, pendingBackY);
            state = State.Local;
            lastX = pendingBackX;
            cooldownUntil = DateTime.Now.AddSeconds(3);
            Status = RemoteName + " did not take the cursor (is it connected?)";
            Log(Status);
        }

        // Keep our hook ahead of Deskflow's in the chain (Deskflow re-hooks when its core restarts).
        if (reinstallRequested || (state == State.Local && (DateTime.Now - lastReinstall).TotalSeconds > 5))
        {
            reinstallRequested = false;
            InstallHook();
        }
    }

    void ReadLog()
    {
        try
        {
            using (var fs = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (fs.Length < logPos) logPos = 0;                  // log rotated
                if (fs.Length == logPos) return;
                fs.Seek(logPos, SeekOrigin.Begin);
                var buf = new byte[fs.Length - logPos];
                int n = fs.Read(buf, 0, buf.Length);
                logPos += n;
                logTail.Append(Encoding.UTF8.GetString(buf, 0, n));
            }
        }
        catch { return; }

        string text = logTail.ToString();
        int lastNl = text.LastIndexOf('\n');
        if (lastNl < 0) return;
        logTail.Remove(0, lastNl + 1);
        foreach (var line in text.Substring(0, lastNl).Split('\n'))
        {
            var m = SwitchRx.Match(line);
            if (m.Success) OnSwitch(m.Groups["to"].Value, int.Parse(m.Groups["x"].Value), int.Parse(m.Groups["y"].Value));
        }
    }

    void OnSwitch(string to, int x, int y)
    {
        Log("deskflow switch to " + to + " at " + x + "," + y + " (state " + state + ")");
        if (string.Equals(to, RemoteName, StringComparison.OrdinalIgnoreCase))
        {
            // Learn the edge's height translation, unless the landing point was clamped to the remote edge.
            if (state == State.Pending && sentY - VT > 40 && y > 2 && (RemoteH <= 0 || y < RemoteH - 2))
            {
                double k = Math.Round(y / (double)(sentY - VT), 3);
                if (k > 0.25 && k < 4) { if (pendingViaRight) KRight = k; else KLeft = k; }
            }
            state = State.Remote;
            Status = "on " + RemoteName;
            return;
        }
        if (!string.Equals(to, LocalName, StringComparison.OrdinalIgnoreCase)) return;

        if (Enabled && state != State.Local)
        {
            // Deskflow re-enters on the outer edge opposite the remote edge that was crossed:
            // right outer edge = left the remote machine through its left side, and vice versa.
            bool cameBackOnRight = x > (VL + VR) / 2;
            int target = cameBackOnRight ? (HasLeft ? PL - 2 : PR + 1) : (HasRight ? PR + 1 : PL - 2);
            // y is on Deskflow's local edge; recover the remote height, then place it level with the picture.
            double k = cameBackOnRight ? KRight : KLeft;
            int targetY = LocalYFor((int)Math.Round((y - VT) * k));
            MoveTo(target, targetY);
            y = targetY;
            lastX = target;
        }
        state = State.Local;
        Status = "on " + LocalName;
    }
}
