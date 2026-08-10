using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using WinRT;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

namespace DeckWindowsAgent.Screen;

public sealed class WindowsGraphicsCaptureSource : IScreenCaptureSource
{
    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDirect3DDevice _direct3DDevice;
    private readonly GraphicsCaptureItem _item;
    private readonly Direct3D11CaptureFramePool _framePool;
    private readonly GraphicsCaptureSession _session;
    private readonly object _gate = new();
    private bool _disposed;
    private ID3D11Texture2D? _stagingTexture;
    private Texture2DDescription _stagingDescription;

    public WindowsGraphicsCaptureSource(string? deviceName, ILogger<WindowsGraphicsCaptureSource> logger)
    {
        var featureLevels = new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 };
        D3D11.D3D11CreateDevice(
            null,
            DriverType.Hardware,
            DeviceCreationFlags.BgraSupport,
            featureLevels,
            out _device!).CheckError();
        _context = _device.ImmediateContext;

        _direct3DDevice = CreateDirect3DDeviceFromD3D11Device(_device);

        var monitor = ResolveMonitor(deviceName, logger);
        _item = GraphicsCaptureItemInterop.CreateItemForMonitor(monitor);

        _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            _direct3DDevice,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            2,
            _item.Size);
        _session = _framePool.CreateCaptureSession(_item);
        _session.IsCursorCaptureEnabled = true;
        _session.StartCapture();
    }

    public bool IsAvailable => !_disposed;

    public bool TryCaptureFrame(out CapturedFrame frame)
    {
        frame = default;
        if (_disposed) return false;

        lock (_gate)
        {
            using var captured = _framePool.TryGetNextFrame();
            if (captured is null) return false;

            var access = captured.Surface.As<IDirect3DDxgiInterfaceAccess>();
            try
            {
                var textureIid = typeof(ID3D11Texture2D).GUID;
                var texturePointer = access.GetInterface(ref textureIid);
                using var texture = new ID3D11Texture2D(texturePointer);
                var description = texture.Description;

                var stagingDescription = description with
                {
                    Usage = ResourceUsage.Staging,
                    BindFlags = BindFlags.None,
                    CPUAccessFlags = CpuAccessFlags.Read,
                    MiscFlags = ResourceOptionFlags.None,
                };

                // Creating a fresh staging texture every captured frame churns GPU-visible
                // resources faster than the driver reliably reclaims them, which shows up as
                // steadily growing private memory that .NET's GC can't see or collect (the
                // managed wrapper is disposed correctly each time; the underlying driver
                // allocation lags behind). Reuse one sized to the current capture instead.
                var staging = EnsureStagingTexture(stagingDescription);
                _context.CopyResource(staging, texture);

                var mapped = _context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
                try
                {
                    var rowPitch = (int)mapped.RowPitch;
                    var bytes = new byte[rowPitch * (int)description.Height];
                    Marshal.Copy(mapped.DataPointer, bytes, 0, bytes.Length);
                    frame = new CapturedFrame((int)description.Width, (int)description.Height, rowPitch, bytes);
                    return true;
                }
                finally
                {
                    _context.Unmap(staging, 0);
                }
            }
            finally
            {
                if (Marshal.IsComObject(access)) Marshal.ReleaseComObject(access);
            }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        lock (_gate)
        {
            _stagingTexture?.Dispose();
            _session.Dispose();
            _framePool.Dispose();
            _direct3DDevice.Dispose();
            _context.Dispose();
            _device.Dispose();
        }
    }

    private ID3D11Texture2D EnsureStagingTexture(Texture2DDescription description)
    {
        if (_stagingTexture is not null
            && _stagingDescription.Width == description.Width
            && _stagingDescription.Height == description.Height
            && _stagingDescription.Format == description.Format)
        {
            return _stagingTexture;
        }

        _stagingTexture?.Dispose();
        _stagingTexture = _device.CreateTexture2D(description);
        _stagingDescription = description;
        return _stagingTexture;
    }

    private static IntPtr ResolveMonitor(string? deviceName, ILogger<WindowsGraphicsCaptureSource> logger)
    {
        if (!string.IsNullOrWhiteSpace(deviceName))
        {
            var resolved = MonitorEnumerator.ResolveHandle(deviceName);
            if (resolved is { } handle) return handle;
            logger.LogWarning(
                "Configured monitor {DeviceName} is not currently attached; falling back to the primary monitor.",
                deviceName);
        }
        return NativeMethods.MonitorFromWindow(IntPtr.Zero, NativeMethods.MonitorDefaultToPrimary);
    }

    private static IDirect3DDevice CreateDirect3DDeviceFromD3D11Device(ID3D11Device device)
    {
        using var dxgiDevice = device.QueryInterface<IDXGIDevice>();
        NativeMethods.CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.NativePointer, out var inspectable);
        return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable)
            ?? throw new InvalidOperationException("Failed to project the Direct3D11 device to a WinRT IDirect3DDevice.");
    }

    [ComImport]
    [Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDirect3DDxgiInterfaceAccess
    {
        IntPtr GetInterface(ref Guid iid);
    }

    private static class NativeMethods
    {
        public const uint MonitorDefaultToPrimary = 1;

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

        [DllImport("d3d11.dll", ExactSpelling = true, PreserveSig = false)]
        public static extern void CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
    }

    private static unsafe class GraphicsCaptureItemInterop
    {
        private static readonly Guid InteropIid = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");

        // typeof(GraphicsCaptureItem).GUID is a CLR-reflection GUID, not the real ABI interface
        // IID -- CreateForMonitor needs the actual IGraphicsCaptureItem default-interface IID.
        private static readonly Guid GraphicsCaptureItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

        // Vtable layout for IGraphicsCaptureItemInterop (derives from IUnknown):
        // 0 = QueryInterface, 1 = AddRef, 2 = Release, 3 = CreateForWindow, 4 = CreateForMonitor.
        private const int CreateForMonitorVtableSlot = 4;

        public static GraphicsCaptureItem CreateItemForMonitor(IntPtr monitorHandle)
        {
            const string className = "Windows.Graphics.Capture.GraphicsCaptureItem";
            WindowsCreateString(className, className.Length, out var classNameHandle);
            try
            {
                var activationFactoryIid = InteropIid;
                RoGetActivationFactory(classNameHandle, ref activationFactoryIid, out var interopPointer);
                try
                {
                    var itemGuid = GraphicsCaptureItemIid;
                    var vtable = *(IntPtr**)interopPointer;
                    var createForMonitor = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)
                        vtable[CreateForMonitorVtableSlot];
                    IntPtr itemPointer;
                    var hr = createForMonitor(interopPointer, monitorHandle, &itemGuid, &itemPointer);
                    Marshal.ThrowExceptionForHR(hr);
                    return GraphicsCaptureItem.FromAbi(itemPointer) is GraphicsCaptureItem item
                        ? item
                        : throw new InvalidOperationException("Failed to create a GraphicsCaptureItem for the target monitor.");
                }
                finally
                {
                    Marshal.Release(interopPointer);
                }
            }
            finally
            {
                WindowsDeleteString(classNameHandle);
            }
        }

        [DllImport("combase.dll", ExactSpelling = true, PreserveSig = false)]
        private static extern void RoGetActivationFactory(
            IntPtr activatableClassId,
            ref Guid iid,
            out IntPtr factory);

        [DllImport("combase.dll", CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = false)]
        private static extern void WindowsCreateString(string sourceString, int length, out IntPtr hstring);

        [DllImport("combase.dll", ExactSpelling = true, PreserveSig = false)]
        private static extern void WindowsDeleteString(IntPtr hstring);
    }
}
