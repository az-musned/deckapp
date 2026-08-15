using System.Runtime.InteropServices;

namespace DeckWindowsAgent.Screen;

/// Attaches/detaches the Virtual Display Driver's monitor to/from the Windows desktop on
/// demand for Extend mode, using the Windows CCD (Connecting and Configuring Displays) API.
/// The driver (https://github.com/VirtualDrivers/Virtual-Display-Driver, device ID prefix
/// "Root\MttVDD") is a real, already-installed display adapter -- Windows just doesn't
/// consider its monitor "connected" to the desktop until something asks it to be. This is
/// exactly what Win+P > Extend does for a disconnected-but-present display; this class does
/// the same thing programmatically, scoped to just the virtual driver's specific display path
/// (identified fresh each call, since its \\.\DISPLAYn number shifts across reboots/driver
/// reloads) rather than "extend everything," so it never touches the real monitor(s).
public sealed class VirtualDisplayAttachment(ILogger<VirtualDisplayAttachment> logger)
{
    private const string VirtualDisplayDriverIdPrefix = "Root\\MttVDD";
    private const int QDC_ALL_PATHS = 0x00000001;
    private const uint SDC_APPLY = 0x00000080;
    private const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    private const uint SDC_ALLOW_CHANGES = 0x00000400;
    private const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
    private const uint DISPLAYCONFIG_PATH_MODE_IDX_INVALID = 0xFFFFFFFF;
    private const int ERROR_SUCCESS = 0;

    /// Attaches the virtual display if it isn't already. Returns true if it's attached
    /// (whether this call did it or it already was), false if the driver isn't present/found
    /// or the attach attempt failed -- callers should treat false as "extend mode will have to
    /// run without an actual second monitor," not a fatal error.
    public bool TryAttach()
    {
        var deviceName = FindVirtualDisplayDeviceName();
        if (deviceName is null)
        {
            logger.LogWarning("Virtual Display Driver adapter not found (looked for device ID prefix {Prefix}); can't auto-attach an extend monitor.", VirtualDisplayDriverIdPrefix);
            return false;
        }

        // EnumDisplayMonitors (what capture-source resolution actually uses) is the source of
        // truth here, not the CCD path's own DISPLAYCONFIG_PATH_ACTIVE flag -- observed that
        // flag reading "already active" immediately after a detach moments earlier, when
        // EnumDisplayMonitors still reported zero non-primary monitors. Trusting the flag alone
        // produced a silent false "already attached" that broke the very next capture attempt.
        if (MonitorEnumerator.ResolveHandle(deviceName) is not null) return true;

        if (!TryQueryAllPaths(out var paths, out var modes))
        {
            logger.LogWarning("QueryDisplayConfig failed while looking for {Device}.", deviceName);
            return false;
        }

        var pathIndex = FindPathIndex(paths, deviceName);
        if (pathIndex < 0)
        {
            logger.LogWarning("Found the Virtual Display Driver adapter but no display path for {Device}.", deviceName);
            return false;
        }

        paths[pathIndex].flags |= DISPLAYCONFIG_PATH_ACTIVE;
        paths[pathIndex].sourceInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        paths[pathIndex].targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;

        var result = NativeMethods.SetDisplayConfig(
            (uint)paths.Length, paths, (uint)modes.Length, modes,
            SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES);
        if (result != ERROR_SUCCESS)
        {
            logger.LogWarning("Failed to attach the virtual display {Device} (SetDisplayConfig returned {Result}).", deviceName, result);
            return false;
        }

        // SetDisplayConfig returning success doesn't guarantee the monitor is immediately
        // visible to EnumDisplayMonitors on this same thread. Poll briefly instead of trusting
        // the return code alone; this runs once per extend-mode connection, not per frame, and
        // callers must call this off the lock that guards the capture/encode pipeline (see
        // ScreenStreamService.TryReserveMode) since it can block for up to ~1s.
        if (!WaitFor(() => MonitorEnumerator.ResolveHandle(deviceName) is not null))
        {
            logger.LogWarning("SetDisplayConfig for {Device} succeeded but it never became visible to EnumDisplayMonitors.", deviceName);
            return false;
        }

        ApplyResolution(deviceName, width: 1920, height: 1080, refreshHz: 60);

        logger.LogInformation("Attached the virtual display {Device} for extend mode.", deviceName);
        return true;
    }

    /// SetDisplayConfig above leaves Windows to pick *a* mode for the newly-activated path,
    /// which in practice is the driver's first configured resolution (800x600) rather than
    /// anything useful. A single-call ChangeDisplaySettingsEx targeting this device was tried
    /// first and reliably failed with DISP_CHANGE_FAILED even for a mode confirmed valid via
    /// EnumDisplaySettingsEx -- newly-attached/virtual displays commonly need the two-phase
    /// stage-then-reset pattern instead: stage this device's mode with CDS_NORESET (which
    /// doesn't fail even though nothing is applied yet), then a separate global
    /// ChangeDisplaySettingsEx(null, ..., CDS_RESET) call to actually commit every pending
    /// staged change at once. Best-effort: extend mode still works at whatever resolution
    /// SetDisplayConfig picked if this fails.
    private void ApplyResolution(string deviceName, int width, int height, int refreshHz)
    {
        var mode = new NativeMethods.DEVMODE
        {
            dmDeviceName = deviceName,
            dmSize = (short)Marshal.SizeOf<NativeMethods.DEVMODE>(),
            dmFields = NativeMethods.DM_PELSWIDTH | NativeMethods.DM_PELSHEIGHT | NativeMethods.DM_BITSPERPEL | NativeMethods.DM_DISPLAYFREQUENCY,
            dmPelsWidth = width,
            dmPelsHeight = height,
            dmBitsPerPel = 32,
            dmDisplayFrequency = refreshHz,
        };

        var stageResult = NativeMethods.ChangeDisplaySettingsExW(deviceName, ref mode, IntPtr.Zero, NativeMethods.CDS_UPDATEREGISTRY | NativeMethods.CDS_NORESET, IntPtr.Zero);
        if (stageResult != NativeMethods.DISP_CHANGE_SUCCESSFUL)
        {
            logger.LogWarning("Could not stage {Device} at {Width}x{Height}@{Hz} (ChangeDisplaySettingsEx returned {Result}); extend mode continues at whatever resolution it attached with.", deviceName, width, height, refreshHz, stageResult);
            return;
        }

        var applyResult = NativeMethods.ChangeDisplaySettingsExW(null, IntPtr.Zero, IntPtr.Zero, NativeMethods.CDS_RESET, IntPtr.Zero);
        if (applyResult != NativeMethods.DISP_CHANGE_SUCCESSFUL)
            logger.LogWarning("Staged {Device} at {Width}x{Height}@{Hz} but committing failed (ChangeDisplaySettingsEx returned {Result}).", deviceName, width, height, refreshHz, applyResult);
        else
            logger.LogInformation("Set {Device} to {Width}x{Height}@{Hz}.", deviceName, width, height, refreshHz);
    }

    private static bool WaitFor(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            if (condition()) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    /// Detaches the virtual display if it's currently attached. Best-effort: logs and returns
    /// on failure rather than throwing, since this runs during teardown where a partial
    /// failure shouldn't block the rest of extend-mode cleanup. Callers must call this off the
    /// _modeGate-equivalent lock in ScreenStreamService for the same reason as TryAttach.
    public void Detach()
    {
        var deviceName = FindVirtualDisplayDeviceName();
        if (deviceName is null) return;
        if (MonitorEnumerator.ResolveHandle(deviceName) is null) return; // Already detached.

        if (!TryQueryAllPaths(out var paths, out var modes)) return;

        var pathIndex = FindPathIndex(paths, deviceName);
        if (pathIndex < 0 || (paths[pathIndex].flags & DISPLAYCONFIG_PATH_ACTIVE) == 0) return;

        paths[pathIndex].flags &= ~DISPLAYCONFIG_PATH_ACTIVE;

        var result = NativeMethods.SetDisplayConfig(
            (uint)paths.Length, paths, (uint)modes.Length, modes,
            SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES);
        if (result != ERROR_SUCCESS)
        {
            logger.LogWarning("Failed to detach the virtual display {Device} (SetDisplayConfig returned {Result}).", deviceName, result);
            return;
        }

        // Same rationale as TryAttach's wait: confirm the detach actually took effect from
        // EnumDisplayMonitors' point of view before the next attach attempt can race against it.
        if (!WaitFor(() => MonitorEnumerator.ResolveHandle(deviceName) is null))
        {
            logger.LogWarning("SetDisplayConfig detach for {Device} succeeded but it's still visible to EnumDisplayMonitors.", deviceName);
            return;
        }

        logger.LogInformation("Detached the virtual display {Device} after extend mode ended.", deviceName);
    }

    /// The driver's \\.\DISPLAYn number shifts across reboots/driver reloads (observed 16 ->
    /// 17 across two sessions during development), so this can never be cached/hardcoded --
    /// it's re-resolved via EnumDisplayDevices (which, unlike EnumDisplayMonitors, reports
    /// adapters regardless of whether their monitor is currently attached to the desktop)
    /// every time. Public: this is a deterministic, hardware-ID-based lookup (unlike
    /// VirtualDisplayDriverLocator's resolution-matching heuristic), so capture-source and
    /// absolute-touch-input resolution both prefer it over that heuristic.
    public static string? FindVirtualDisplayDeviceName()
    {
        uint index = 0;
        while (true)
        {
            var device = new NativeMethods.DISPLAY_DEVICE { cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>() };
            if (!NativeMethods.EnumDisplayDevicesW(null, index, ref device, 0)) return null;
            if (device.DeviceID.StartsWith(VirtualDisplayDriverIdPrefix, StringComparison.OrdinalIgnoreCase))
                return device.DeviceName;
            index++;
        }
    }

    private static bool TryQueryAllPaths(out NativeMethods.DISPLAYCONFIG_PATH_INFO[] paths, out NativeMethods.DISPLAYCONFIG_MODE_INFO[] modes)
    {
        paths = [];
        modes = [];
        if (NativeMethods.GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out var pathCount, out var modeCount) != ERROR_SUCCESS)
            return false;

        paths = new NativeMethods.DISPLAYCONFIG_PATH_INFO[pathCount];
        modes = new NativeMethods.DISPLAYCONFIG_MODE_INFO[modeCount];
        var result = NativeMethods.QueryDisplayConfig(QDC_ALL_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (result != ERROR_SUCCESS) return false;

        // GetDisplayConfigBufferSizes gives an upper bound; QueryDisplayConfig can return
        // fewer entries than that (topology can change between the two calls).
        if (pathCount != paths.Length) Array.Resize(ref paths, (int)pathCount);
        if (modeCount != modes.Length) Array.Resize(ref modes, (int)modeCount);
        return true;
    }

    private static int FindPathIndex(NativeMethods.DISPLAYCONFIG_PATH_INFO[] paths, string deviceName)
    {
        for (var i = 0; i < paths.Length; i++)
        {
            var sourceName = new NativeMethods.DISPLAYCONFIG_SOURCE_DEVICE_NAME
            {
                header = new NativeMethods.DISPLAYCONFIG_DEVICE_INFO_HEADER
                {
                    type = NativeMethods.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
                    size = Marshal.SizeOf<NativeMethods.DISPLAYCONFIG_SOURCE_DEVICE_NAME>(),
                    adapterId = paths[i].sourceInfo.adapterId,
                    id = paths[i].sourceInfo.id,
                }
            };
            if (NativeMethods.DisplayConfigGetDeviceInfo(ref sourceName) == ERROR_SUCCESS
                && string.Equals(sourceName.viewGdiDeviceName, deviceName, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }
        return -1;
    }

    private static class NativeMethods
    {
        public const int DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevicesW(string? lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll")]
        public static extern int GetDisplayConfigBufferSizes(int flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

        [DllImport("user32.dll")]
        public static extern int QueryDisplayConfig(int flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray, ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

        [DllImport("user32.dll")]
        public static extern int SetDisplayConfig(uint numPathArrayElements, [In] DISPLAYCONFIG_PATH_INFO[] pathArray, uint numModeInfoArrayElements, [In] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, uint flags);

        [DllImport("user32.dll")]
        public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

        public const int DM_PELSWIDTH = 0x00080000;
        public const int DM_PELSHEIGHT = 0x00100000;
        public const int DM_BITSPERPEL = 0x00040000;
        public const int DM_DISPLAYFREQUENCY = 0x00400000;
        public const uint CDS_UPDATEREGISTRY = 0x00000001;
        public const uint CDS_NORESET = 0x10000000;
        public const uint CDS_RESET = 0x40000000;
        public const int DISP_CHANGE_SUCCESSFUL = 0;

        // Two overloads of the same entry point: staging a specific device's mode passes a
        // real device name + DEVMODE; committing every staged change afterward is the
        // documented ChangeDisplaySettingsEx(NULL, NULL, ...) call, which needs a null DEVMODE
        // pointer -- not reachable through the `ref DEVMODE` overload used for staging.
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
        public static extern int ChangeDisplaySettingsExW(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
        public static extern int ChangeDisplaySettingsExW(string? lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion;
            public short dmDriverVersion;
            public short dmSize;
            public short dmDriverExtra;
            public int dmFields;
            public int dmPositionX;
            public int dmPositionY;
            public int dmDisplayOrientation;
            public int dmDisplayFixedOutput;
            public short dmColor;
            public short dmDuplex;
            public short dmYResolution;
            public short dmTTOption;
            public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel;
            public int dmPelsWidth;
            public int dmPelsHeight;
            public int dmDisplayFlags;
            public int dmDisplayFrequency;
            public int dmICMMethod;
            public int dmICMIntent;
            public int dmMediaType;
            public int dmDitherType;
            public int dmReserved1;
            public int dmReserved2;
            public int dmPanningWidth;
            public int dmPanningHeight;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_SOURCE_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_TARGET_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public int outputTechnology;
            public int rotation;
            public int scaling;
            public uint refreshRateNumerator;
            public uint refreshRateDenominator;
            public int scanLineOrdering;
            public int targetAvailable;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_INFO
        {
            public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
            public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        // The real native struct is a union of per-source/per-target/desktop-image mode data
        // beyond the common 16-byte header; this process never reads or writes into that
        // union, so it's declared only as an opaquely-sized 64-byte block (the real,
        // documented total struct size on x64) -- correct total size is what matters for safe
        // array marshaling, not the union's individual field layout.
        [StructLayout(LayoutKind.Explicit, Size = 64)]
        public struct DISPLAYCONFIG_MODE_INFO
        {
            [FieldOffset(0)] public int infoType;
            [FieldOffset(4)] public uint id;
            [FieldOffset(8)] public LUID adapterId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_DEVICE_INFO_HEADER
        {
            public int type;
            public int size;
            public LUID adapterId;
            public uint id;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
        {
            public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string viewGdiDeviceName;
        }
    }
}
