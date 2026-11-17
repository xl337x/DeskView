// Wi-Fi made steady while the two computers are linked: "media streaming mode" on and background scans off on every
// connected Wi-Fi adapter. Background scans (about once a minute, seconds long on some drivers) and power saving are
// what turn a smooth mouse into jerks of 30-300 ms. Per user, no admin; Windows undoes both as soon as our handle
// closes (link down, DeskView closed), so nothing stays changed on the PC.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace DeskView
{
    public static class Wifi
    {
        [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiated, out IntPtr handle);
        [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr handle, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern int WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
        [DllImport("wlanapi.dll")] static extern int WlanSetInterface(IntPtr handle, ref Guid iface, int opcode, uint size, IntPtr data, IntPtr reserved);

        const int BackgroundScanEnabled = 2, MediaStreamingMode = 3;   // WLAN_INTF_OPCODE
        const int ItemSize = 16 + 512 + 4;                              // WLAN_INTERFACE_INFO: GUID, WCHAR[256], state
        static IntPtr handle = IntPtr.Zero;
        static DateTime lastApply = DateTime.MinValue;

        /// <summary>While linked: call every few seconds (re-applied every 30 s, e.g. after the Wi-Fi reconnected).
        /// Returns a line for the log when something was done, else null.</summary>
        public static string Steady()
        {
            if (handle != IntPtr.Zero && (DateTime.Now - lastApply).TotalSeconds < 30) return null;
            lastApply = DateTime.Now;
            try
            {
                uint v; int rc;
                if (handle == IntPtr.Zero && (rc = WlanOpenHandle(2, IntPtr.Zero, out v, out handle)) != 0) { handle = IntPtr.Zero; return rc == 1062 ? null : "wifi: no Wi-Fi service (" + rc + ")"; }   // 1062: service not started = no Wi-Fi
                IntPtr list;
                if ((rc = WlanEnumInterfaces(handle, IntPtr.Zero, out list)) != 0) return "wifi: cannot list adapters (" + rc + ")";
                var done = new List<string>();
                try
                {
                    int n = Marshal.ReadInt32(list);
                    for (int i = 0; i < n; i++)
                    {
                        IntPtr item = new IntPtr(list.ToInt64() + 8 + i * ItemSize);
                        var g = (Guid)Marshal.PtrToStructure(item, typeof(Guid));
                        int state = Marshal.ReadInt32(item, 16 + 512);
                        if (state != 1) continue;                                // 1 = connected
                        int a = Set(g, MediaStreamingMode, 1), b = Set(g, BackgroundScanEnabled, 0);
                        done.Add("streaming mode " + (a == 0 ? "on" : "failed (" + a + ")") + ", background scans " + (b == 0 ? "off" : "unchanged (" + b + ")"));
                    }
                }
                finally { WlanFreeMemory(list); }
                return done.Count == 0 ? null : "wifi: steady for the link - " + string.Join("; ", done);
            }
            catch (Exception e) { return "wifi: " + e.Message; }
        }

        /// <summary>Link down: Windows puts both settings back when the handle closes.</summary>
        public static string Normal()
        {
            if (handle == IntPtr.Zero) return null;
            try { WlanCloseHandle(handle, IntPtr.Zero); } catch { }
            handle = IntPtr.Zero;
            return "wifi: back to normal (link down)";
        }

        static int Set(Guid g, int opcode, int value)
        {
            IntPtr data = Marshal.AllocHGlobal(4);
            try { Marshal.WriteInt32(data, value); return WlanSetInterface(handle, ref g, opcode, 4, data, IntPtr.Zero); }
            finally { Marshal.FreeHGlobal(data); }
        }
    }
}
