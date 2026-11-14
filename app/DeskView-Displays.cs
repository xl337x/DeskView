// Virtual screens: Windows' display settings for the screens the virtual display driver adds - switch them on
// (extend the desktop onto them), give them a real resolution and put them in a row to the right of the computer's
// own screens, so the other computer can show each one and windows can be dragged across all of them.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DeskViewDisplays
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, int i, ref DISPLAY_DEVICE dd, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr lp);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);

    const int ENUM_CURRENT_SETTINGS = -1, ATTACHED = 1;
    const int DM_POSITION = 0x20, DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000;
    const int CDS_UPDATEREGISTRY = 0x1, CDS_NORESET = 0x10000000;

    static bool IsVirtual(DISPLAY_DEVICE dd) { return dd.DeviceString != null && dd.DeviceString.IndexOf("Virtual Display", StringComparison.OrdinalIgnoreCase) >= 0; }

    static List<DISPLAY_DEVICE> Devices()
    {
        var l = new List<DISPLAY_DEVICE>();
        for (int i = 0; ; i++)
        {
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            l.Add(dd);
        }
        return l;
    }

    /// <summary>Names (\\.\DISPLAYn) of the virtual screens that are part of the desktop.</summary>
    public static string[] VirtualScreens()
    {
        var l = new List<string>();
        foreach (var dd in Devices()) if (IsVirtual(dd) && (dd.StateFlags & ATTACHED) != 0) l.Add(dd.DeviceName);
        return l.ToArray();
    }

    /// <summary>Puts every virtual screen at width x height, in a row to the right of the computer's own screens.
    /// Returns what was done, one line per screen.</summary>
    public static string[] Arrange(int width, int height)
    {
        SetThreadDpiAwarenessContext(new IntPtr(-4));   // physical pixels
        var log = new List<string>();
        int right = 0; var virt = new List<string>();
        foreach (var dd in Devices())
        {
            if ((dd.StateFlags & ATTACHED) == 0) continue;
            if (IsVirtual(dd)) { virt.Add(dd.DeviceName); continue; }
            var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (EnumDisplaySettings(dd.DeviceName, ENUM_CURRENT_SETTINGS, ref cur)) right = Math.Max(right, cur.dmPositionX + cur.dmPelsWidth);
        }
        int x = right;
        foreach (var name in virt)
        {
            var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); bool found = false;
            for (int i = 0; EnumDisplaySettings(name, i, ref dm); i++) if (dm.dmPelsWidth == width && dm.dmPelsHeight == height) { found = true; break; }
            if (!found) { log.Add(name + ": no " + width + "x" + height + " mode"); continue; }
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_POSITION; dm.dmPositionX = x; dm.dmPositionY = 0;
            int r = ChangeDisplaySettingsEx(name, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
            log.Add(string.Format("{0}: {1}x{2} at {3},0 ({4})", name, width, height, x, r == 0 ? "ok" : "error " + r));
            x += width;
        }
        if (virt.Count > 0) ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);   // apply all at once
        return log.ToArray();
    }
}
