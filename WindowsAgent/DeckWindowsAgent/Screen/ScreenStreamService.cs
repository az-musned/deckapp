using System.Diagnostics;
using System.Runtime.InteropServices;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Screen.Models;

namespace DeckWindowsAgent.Screen;

public sealed class ScreenStreamService(
    AgentOptions options,
    IScreenCaptureSourceFactory sourceFactory,
    VirtualDisplayDriverLocator extendMonitorLocator,
    AgentSafetyState safety,
    ScreenStreamBroadcaster broadcaster,
    ScreenStreamSequence sequence,
    ILogger<ScreenStreamService> logger) : BackgroundService
{
    private readonly object _modeGate = new();
    private ScreenStreamMode? _activeMode;
    private IScreenCaptureSource? _source;
    private H264Encoder? _encoder;
    private int _lastSubscriberCount;

    /// Called by the WebSocket endpoint before subscribing a new client. Locks in the
    /// stream's active mode while any subscriber is connected; rejects a connection
    /// requesting a different mode than the one currently active.
    public bool TryReserveMode(ScreenStreamMode mode, out string? conflictReason)
    {
        lock (_modeGate)
        {
            if (broadcaster.SubscriberCount == 0 || _activeMode is null)
            {
                if (_activeMode != mode) TearDownCaptureLocked();
                _activeMode = mode;
                conflictReason = null;
                return true;
            }
            if (_activeMode == mode)
            {
                conflictReason = null;
                return true;
            }
            conflictReason = $"Screen streaming is currently active in {_activeMode} mode.";
            return false;
        }
    }

    /// Forces the next encoded frame to be a fresh keyframe (with in-band SPS/PPS) by
    /// recreating the encoder -- a newly-constructed encoder's first output is always an
    /// IDR. Called when a client explicitly asks for one, e.g. right after connecting.
    public void RequestKeyframe()
    {
        lock (_modeGate)
        {
            _encoder?.Dispose();
            _encoder = null;
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.ScreenStream.Enabled)
        {
            logger.LogInformation("Screen mirroring is disabled by local configuration.");
            return;
        }

        // Windows' default system timer resolution (~15.6ms ticks) makes Task.Delay
        // overshoot short requested delays by a similar margin regardless of how little
        // actual work preceded it -- measured directly: at a 30fps target, Task.Delay
        // alone (zero capture/encode work) produced a ~46.6ms mean period against a 33.3ms
        // target, and adding real capture+encode work didn't change that number at all,
        // proving the timer tick -- not the pipeline -- was the ceiling. Requesting 1ms
        // timer resolution for the process brings the same test to a ~32.7ms mean with
        // ~1.3ms stddev. Released in the finally below; safe to call repeatedly/nested
        // since Windows reference-counts it per process.
        NativeMethods.TimeBeginPeriod(1);
        try
        {
            await RunCaptureLoopAsync(stoppingToken);
        }
        finally
        {
            NativeMethods.TimeEndPeriod(1);
        }
    }

    private async Task RunCaptureLoopAsync(CancellationToken stoppingToken)
    {
        var tickStopwatch = new Stopwatch();
        while (!stoppingToken.IsCancellationRequested)
        {
            tickStopwatch.Restart();
            var subscriberCount = broadcaster.SubscriberCount;
            var active = safety.ScreenShareAllowed && subscriberCount > 0;
            if (active)
            {
                if (subscriberCount > _lastSubscriberCount) RequestKeyframe();
                _lastSubscriberCount = subscriberCount;

                var (source, encoder) = EnsureCapture();
                if (source is { IsAvailable: true } && encoder is not null)
                {
                    try
                    {
                        if (source.TryCaptureFrame(out var captured))
                        {
                            var encoded = encoder.Encode(captured);
                            if (encoded is { } result)
                            {
                                var frame = new ScreenFrame(
                                    sequence.Next(),
                                    DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                                    Math.Min(captured.Width, options.ScreenStream.MaxWidth),
                                    captured.Width > options.ScreenStream.MaxWidth
                                        ? (int)Math.Round(captured.Height * (options.ScreenStream.MaxWidth / (double)captured.Width))
                                        : captured.Height,
                                    result.IsKeyframe,
                                    result.AnnexB);
                                broadcaster.Publish(frame);
                            }
                        }
                    }
                    catch (Exception error) when (IsRecoverableCaptureFailure(error))
                    {
                        logger.LogWarning("Screen capture is temporarily unavailable; the Agent will retry: {Message}", error.Message);
                    }
                }
            }
            else
            {
                _lastSubscriberCount = 0;
                lock (_modeGate) TearDownCaptureLocked();
            }

            // Fixed-rate scheduling, not sleep-after-work: capture+encode time varies frame to
            // frame (scene complexity, system load, the resize step when downscaling), so
            // sleeping a constant interval after variable-length work produces a variable
            // total period between frames -- i.e. jitter baked in before the client ever sees
            // a byte, which client-side display-timing fixes can't undo. Target a fixed
            // wall-clock tick instead: subtract the work just done from the interval, clamped
            // at zero if a frame overran its budget (no negative delay, no busy-loop catch-up).
            var targetInterval = active
                ? TimeSpan.FromSeconds(1d / options.ScreenStream.TargetFps)
                : TimeSpan.FromMilliseconds(500);
            var remaining = targetInterval - tickStopwatch.Elapsed;
            if (remaining > TimeSpan.Zero) await Task.Delay(remaining, stoppingToken);
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        lock (_modeGate) TearDownCaptureLocked();
        await base.StopAsync(cancellationToken);
    }

    private (IScreenCaptureSource? Source, H264Encoder? Encoder) EnsureCapture()
    {
        lock (_modeGate)
        {
            if (_activeMode is not { } mode) return (null, null);

            if (_source is null)
            {
                var deviceName = mode == ScreenStreamMode.Mirror
                    ? options.ScreenStream.MirrorMonitorDeviceName
                    : options.ScreenStream.ExtendMonitorDeviceName ?? extendMonitorLocator.TryResolveDeviceName();
                try
                {
                    _source = sourceFactory.Create(deviceName);
                }
                catch (Exception error) when (IsRecoverableCaptureFailure(error))
                {
                    logger.LogWarning("Failed to start screen capture for {Mode} mode: {Message}", mode, error.Message);
                    return (null, null);
                }
            }

            if (_encoder is null && _source is { IsAvailable: true } source)
            {
                try
                {
                    // Probe a frame to learn the real capture dimensions before sizing the encoder.
                    if (!source.TryCaptureFrame(out var probe)) return (_source, null);
                    var scale = Math.Min(1.0, options.ScreenStream.MaxWidth / (double)probe.Width);
                    var width = EvenDimension((int)Math.Round(probe.Width * scale));
                    var height = EvenDimension((int)Math.Round(probe.Height * scale));
                    _encoder = new H264Encoder(width, height, options.ScreenStream.TargetFps, options.ScreenStream.BitrateKbps * 1000);
                }
                catch (Exception error) when (IsRecoverableCaptureFailure(error))
                {
                    logger.LogWarning("Failed to start the H.264 encoder: {Message}", error.Message);
                    return (_source, null);
                }
            }

            return (_source, _encoder);
        }
    }

    private void TearDownCaptureLocked()
    {
        _encoder?.Dispose();
        _encoder = null;
        _source?.Dispose();
        _source = null;
    }

    private static int EvenDimension(int value) => value % 2 == 0 ? value : value - 1;

    private static bool IsRecoverableCaptureFailure(Exception error) => error is
        InvalidOperationException or
        ObjectDisposedException or
        System.Runtime.InteropServices.COMException;

    private static class NativeMethods
    {
        [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod", ExactSpelling = true)]
        public static extern uint TimeBeginPeriod(uint periodMilliseconds);

        [DllImport("winmm.dll", EntryPoint = "timeEndPeriod", ExactSpelling = true)]
        public static extern uint TimeEndPeriod(uint periodMilliseconds);
    }
}
