// Lists the DXGI outputs of the default graphics adapter in order, i.e. the numbering FFmpeg's ddagrab
// uses for output_idx (it captures from the default D3D11 device's adapter), with each output's
// Windows device name (\\.\DISPLAYn) and desktop rectangle, so a monitor can be picked by name.
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class DeskViewDxgi
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DXGI_OUTPUT_DESC
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public RECT DesktopCoordinates;
        public int AttachedToDesktop;
        public int Rotation;
        public IntPtr Monitor;
    }

    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIFactory1
    {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        [PreserveSig] int EnumAdapters(uint index, out IDXGIAdapter adapter);
    }

    [ComImport, Guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIAdapter
    {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        [PreserveSig] int EnumOutputs(uint index, out IDXGIOutput output);
    }

    [ComImport, Guid("ae02eedb-c735-4690-8d52-5a8dc20213aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIOutput
    {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        [PreserveSig] int GetDesc(out DXGI_OUTPUT_DESC desc);
    }

    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IDXGIFactory1 factory);

    /// <summary>One capturable screen: which graphics adapter it hangs off and its output number there.</summary>
    public class Output { public string Name; public int Adapter; public int Index; }

    /// <summary>Every screen on every graphics adapter. A screen on adapter 0 is captured with ddagrab directly;
    /// on another adapter (second GPU, a virtual display driver rendering elsewhere) ddagrab needs a D3D11 device
    /// on that adapter (-init_hw_device d3d11va=x:N -filter_hw_device x).</summary>
    public static Output[] AllOutputs()
    {
        var list = new List<Output>();
        Guid iid = typeof(IDXGIFactory1).GUID;
        IDXGIFactory1 factory;
        if (CreateDXGIFactory1(ref iid, out factory) != 0) return list.ToArray();
        for (uint a = 0; ; a++)
        {
            IDXGIAdapter adapter;
            if (factory.EnumAdapters(a, out adapter) != 0) break;
            for (uint i = 0; ; i++)
            {
                IDXGIOutput output;
                if (adapter.EnumOutputs(i, out output) != 0) break;
                DXGI_OUTPUT_DESC d;
                output.GetDesc(out d);
                if (d.AttachedToDesktop != 0) list.Add(new Output { Name = (d.DeviceName ?? "").Replace(@"\\.\", ""), Adapter = (int)a, Index = (int)i });
                Marshal.ReleaseComObject(output);
            }
            Marshal.ReleaseComObject(adapter);
        }
        Marshal.ReleaseComObject(factory);
        return list.ToArray();
    }

    /// <summary>Device names (e.g. "DISPLAY1") of adapter 0's outputs, index = ddagrab output_idx.</summary>
    public static string[] DdagrabOutputs()
    {
        var names = new List<string>();
        Guid iid = typeof(IDXGIFactory1).GUID;
        IDXGIFactory1 factory;
        if (CreateDXGIFactory1(ref iid, out factory) != 0) return names.ToArray();
        IDXGIAdapter adapter;
        if (factory.EnumAdapters(0, out adapter) != 0) return names.ToArray();
        for (uint i = 0; ; i++)
        {
            IDXGIOutput output;
            if (adapter.EnumOutputs(i, out output) != 0) break;
            DXGI_OUTPUT_DESC d;
            output.GetDesc(out d);
            names.Add((d.DeviceName ?? "").Replace(@"\\.\", ""));
            Marshal.ReleaseComObject(output);
        }
        Marshal.ReleaseComObject(adapter);
        Marshal.ReleaseComObject(factory);
        return names.ToArray();
    }
}
