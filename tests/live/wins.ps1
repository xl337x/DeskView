Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class W {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(P p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  public static List<string> Of(uint[] pids) { var o = new List<string>();
    EnumWindows((h,l) => { uint p; GetWindowThreadProcessId(h, out p); if (Array.IndexOf(pids,p) < 0) return true;
      var s = new StringBuilder(64); GetWindowText(h,s,64); R r; GetWindowRect(h, out r);
      o.Add(string.Format("pid={0} '{1}' vis={2} top={3} rect={4},{5},{6},{7}", p, s, IsWindowVisible(h), (GetWindowLong(h,-20)&8)!=0, r.L,r.T,r.Rr,r.B)); return true; }, IntPtr.Zero); return o; }
}
'@
$p = @(Get-Process ffplay -ErrorAction SilentlyContinue | % { [uint32]$_.Id })
"ffplay count: $($p.Count)"
if ($p.Count) { [W]::Of($p) | ? { $_ -match 'vis=True' } }
