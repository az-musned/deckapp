using System.Runtime.InteropServices;

namespace DeckWindowsAgent.Screen;

public static class MonitorEnumerator
{
    public static IReadOnlyList<MonitorDescriptor> EnumerateAll()
    {
        var monitors = new List<MonitorDescriptor>();
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMonitor, IntPtr _, ref NativeMethods.RECT _, IntPtr _) =>
        {
            if (TryDescribe(hMonitor, out var descriptor)) monitors.Add(descriptor);
            return true;
        }, IntPtr.Zero);
        return monitors;
    }

    /// Resolves a device name (e.g. "\\.\DISPLAY1") to its current HMONITOR handle.
    /// Returns null if no monitor with that device name is currently attached.
    public static IntPtr? ResolveHandle(string deviceName)
    {
        IntPtr? resolved = null;
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMonitor, IntPtr _, ref NativeMethods.RECT _, IntPtr _) =>
        {
            var info = new NativeMethods.MONITORINFOEX { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFOEX>() };
            if (NativeMethods.GetMonitorInfo(hMonitor, ref info) && info.szDevice == deviceName)
            {
                resolved = hMonitor;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return resolved;
    }

    private static bool TryDescribe(IntPtr hMonitor, out MonitorDescriptor descriptor)
    {
        var info = new NativeMethods.MONITORINFOEX { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFOEX>() };
        if (!NativeMethods.GetMonitorInfo(hMonitor, ref info))
        {
            descriptor = default;
            return false;
        }
        var isPrimary = (info.dwFlags & NativeMethods.MonitorInfoFPrimary) != 0;
        var width = info.rcMonitor.Right - info.rcMonitor.Left;
        var height = info.rcMonitor.Bottom - info.rcMonitor.Top;
        descriptor = new MonitorDescriptor(info.szDevice, isPrimary, info.rcMonitor.Left, info.rcMonitor.Top, width, height);
        return true;
    }

    private static class NativeMethods
    {
        public const uint MonitorInfoFPrimary = 0x1;

        public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

        [DllImport("user32.dll")]
        public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MONITORINFOEX
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szDevice;
        }
    }
}
