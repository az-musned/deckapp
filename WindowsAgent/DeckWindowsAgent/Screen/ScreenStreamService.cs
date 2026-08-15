using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Screen.Models;

namespace DeckWindowsAgent.Screen;

public sealed class ScreenStreamService(
    AgentOptions options,
    IScreenCaptureSourceFactory sourceFactory,
    VirtualDisplayDriverLocator extendMonitorLocator,
    VirtualDisplayAttachment virtualDisplay,
    AgentSafetyState safety,
    ScreenStreamBroadcaster broadcaster,
    ILogger<ScreenStreamService> logger) : BackgroundService
{
    private readonly object _modeGate = new();

    // Connects the capture loop to the encode loop. Capacity 1 + DropOldest: only the
    // newest frame is ever worth encoding, and a full channel must never make the capture
    // loop block -- that would reintroduce exactly the capture-blocked-on-encode jitter
    // this split exists to remove. Single reader/writer since each loop owns exactly one side.
    private readonly Channel<CapturedFrame> _captureChannel = Channel.CreateBounded<CapturedFrame>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true,
        });

    private ScreenStreamMode? _activeMode;
    private IScreenCaptureSource? _source;
    private H264Encoder? _encoder;
    private int _lastSubscriberCount;

    /// RTP timestamps for video advance on a fixed 90kHz clock regardless of codec.
    private uint RtpDurationUnits => (uint)(90_000 / Math.Max(1, options.ScreenStream.TargetFps));

    /// Called by the WebSocket endpoint before subscribing a new client. Locks in the
    /// stream's active mode while any subscriber is connected; rejects a connection
    /// requesting a different mode than the one currently active.
    public bool TryReserveMode(ScreenStreamMode mode, out string? conflictReason)
    {
        ScreenStreamMode? previousMode;
        bool reserved;
        lock (_modeGate)
        {
            if (broadcaster.SubscriberCount == 0 || _activeMode is null)
            {
                previousMode = _activeMode;
                if (_activeMode != mode) TearDownCaptureLocked();
                _activeMode = mode;
                conflictReason = null;
                reserved = true;
            }
            else if (_activeMode == mode)
            {
                previousMode = _activeMode;
                conflictReason = null;
                reserved = true;
            }
            else
            {
                previousMode = null;
                conflictReason = $"Screen streaming is currently active in {_activeMode} mode.";
                reserved = false;
            }
        }

        // Attach/detach the virtual display outside _modeGate: both can block for up to ~1s
        // confirming the Windows topology change actually took effect (see
        // VirtualDisplayAttachment), and holding _modeGate that long would stall the
        // capture/encode loops, which both need it briefly on every tick. Best-effort: extend
        // mode still runs even if there's no virtual display to attach (falls back to whatever
        // ExtendMonitorDeviceName/auto-detect resolves, same as before this existed), it just
        // won't have a real second monitor to capture.
        if (reserved)
        {
            if (mode == ScreenStreamMode.Extend) virtualDisplay.TryAttach();
            else if (previousMode == ScreenStreamMode.Extend) virtualDisplay.Detach();
        }

        return reserved;
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
            // Capture and encode run as independent loops joined only by _captureChannel:
            // a slow encode (scene complexity, system load) must never delay the next
            // capture tick, or the same jitter this split exists to remove just reappears
            // one layer downstream of the fixed-rate pacing loop below.
            //
            // Both loops share loopFailureCts rather than stoppingToken directly: if either
            // one faults on an unexpected exception, the other must stop too. Plain
            // Task.WhenAll(captureTask, encodeTask) doesn't do that -- it was confirmed to
            // silently hang the entire pipeline forever (agent stays up, screen mirror goes to
            // a permanent black screen, no error ever logged) the one time this actually
            // happened, because WhenAll only completes once *both* tasks reach a terminal
            // state, and a healthy loop with no reason to stop just runs forever alongside a
            // dead one.
            using var loopFailureCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
            var captureTask = RunCaptureLoopAsync(loopFailureCts.Token);
            var encodeTask = RunEncodeLoopAsync(loopFailureCts.Token);
            var firstCompleted = await Task.WhenAny(captureTask, encodeTask);
            if (firstCompleted.IsFaulted) loopFailureCts.Cancel();
            await Task.WhenAll(captureTask, encodeTask);
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

                var source = EnsureCaptureSource();
                if (source is { IsAvailable: true })
                {
                    try
                    {
                        if (source.TryCaptureFrame(out var captured))
                        {
                            _captureChannel.Writer.TryWrite(captured);
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
                TearDownCaptureAndDetachIfNeeded();
            }

            // Fixed-rate scheduling, not sleep-after-work: capture time varies frame to
            // frame (system load, driver hiccups), so sleeping a constant interval after
            // variable-length work produces a variable total period between frames -- i.e.
            // jitter baked in before the client ever sees a byte, which client-side
            // display-timing fixes can't undo. Target a fixed wall-clock tick instead:
            // subtract the work just done from the interval, clamped at zero if a frame
            // overran its budget (no negative delay, no busy-loop catch-up).
            var targetInterval = active
                ? TimeSpan.FromSeconds(1d / options.ScreenStream.TargetFps)
                : TimeSpan.FromMilliseconds(500);
            var remaining = targetInterval - tickStopwatch.Elapsed;
            if (remaining > TimeSpan.Zero) await Task.Delay(remaining, stoppingToken);
        }
    }

    private async Task RunEncodeLoopAsync(CancellationToken stoppingToken)
    {
        await foreach (var captured in _captureChannel.Reader.ReadAllAsync(stoppingToken))
        {
            // Encode() must run *inside* this lock, not just the EnsureEncoderLocked lookup
            // that used to precede it: capture and encode are separate threads now (unlike the
            // single serialized loop this was split from), so TearDownCaptureLocked/
            // RequestKeyframe on the capture thread can otherwise Dispose() the encoder's
            // native Media Foundation transform while this thread is still inside a call on
            // it -- an access violation, not a managed exception, confirmed by a crash here
            // the instant the last subscriber disconnected (capture loop saw active=false and
            // tore down the encoder while this loop's last Encode() call was still in flight).
            EncodedFrame? encoded;
            lock (_modeGate)
            {
                if (_activeMode is null) continue;
                var encoder = EnsureEncoderLocked(captured.Width, captured.Height);
                if (encoder is null) continue;

                try
                {
                    encoded = encoder.Encode(captured);
                }
                catch (Exception error) when (IsRecoverableCaptureFailure(error))
                {
                    logger.LogWarning("The H.264 encoder failed on a frame; the Agent will retry: {Message}", error.Message);
                    _encoder?.Dispose();
                    _encoder = null;
                    encoded = null;
                }
            }

            if (encoded is { } result) broadcaster.Publish(result, RtpDurationUnits);
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        TearDownCaptureAndDetachIfNeeded();
        await base.StopAsync(cancellationToken);
    }

    private IScreenCaptureSource? EnsureCaptureSource()
    {
        lock (_modeGate)
        {
            if (_activeMode is not { } mode) return null;
            if (_source is not null) return _source;

            // The hardware-ID-based lookup (device ID prefix "Root\MttVDD") is deterministic and
            // tried first; it's what VirtualDisplayAttachment already used to attach the display
            // above, so if that succeeded this will find the same monitor. The resolution-matching
            // heuristic in extendMonitorLocator is only a fallback for a differently-built driver
            // that doesn't use that device ID prefix.
            var deviceName = mode == ScreenStreamMode.Mirror
                ? options.ScreenStream.MirrorMonitorDeviceName
                : options.ScreenStream.ExtendMonitorDeviceName
                    ?? VirtualDisplayAttachment.FindVirtualDisplayDeviceName()
                    ?? extendMonitorLocator.TryResolveDeviceName();
            try
            {
                _source = sourceFactory.Create(deviceName);
                return _source;
            }
            catch (Exception error) when (IsRecoverableCaptureFailure(error))
            {
                logger.LogWarning("Failed to start screen capture for {Mode} mode: {Message}", mode, error.Message);
                return null;
            }
        }
    }

    /// Must be called while holding _modeGate. Sizes the encoder off the dimensions of
    /// whichever captured frame the encode loop is about to encode -- the first frame that
    /// flows through the channel doubles as the sizing probe, so there's no separate
    /// probe-then-discard capture the way there was before capture/encode were split.
    private H264Encoder? EnsureEncoderLocked(int capturedWidth, int capturedHeight)
    {
        if (_encoder is not null) return _encoder;

        try
        {
            var scale = Math.Min(1.0, options.ScreenStream.MaxWidth / (double)capturedWidth);
            var width = EvenDimension((int)Math.Round(capturedWidth * scale));
            var height = EvenDimension((int)Math.Round(capturedHeight * scale));
            _encoder = new H264Encoder(width, height, options.ScreenStream.TargetFps, options.ScreenStream.BitrateKbps * 1000);
            return _encoder;
        }
        catch (Exception error) when (IsRecoverableCaptureFailure(error))
        {
            logger.LogWarning("Failed to start the H.264 encoder: {Message}", error.Message);
            return null;
        }
    }

    /// Wraps TearDownCaptureLocked for call sites that mean "extend mode may be ending"
    /// (subscriber count hitting zero, service shutdown) but aren't already inside a
    /// TryReserveMode call that handles the attach/detach transition itself. Detach happens
    /// after releasing _modeGate, same reasoning as TryReserveMode: it can block for up to
    /// ~1s and must not stall the capture/encode loops.
    private void TearDownCaptureAndDetachIfNeeded()
    {
        bool wasExtend;
        lock (_modeGate)
        {
            wasExtend = _activeMode == ScreenStreamMode.Extend;
            TearDownCaptureLocked();
        }
        if (wasExtend) virtualDisplay.Detach();
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
