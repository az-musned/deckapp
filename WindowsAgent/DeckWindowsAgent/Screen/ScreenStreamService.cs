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

    /// Called by the WebSocket endpoint before subscribing a new client. Locks in the
    /// stream's active mode while any subscriber is connected; rejects a connection
    /// requesting a different mode than the one currently active.
    public bool TryReserveMode(ScreenStreamMode mode, out string? conflictReason)
    {
        lock (_modeGate)
        {
            if (broadcaster.SubscriberCount == 0 || _activeMode is null)
            {
                if (_activeMode != mode)
                {
                    _source?.Dispose();
                    _source = null;
                }
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

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.ScreenStream.Enabled)
        {
            logger.LogInformation("Screen mirroring is disabled by local configuration.");
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            var active = safety.ScreenShareAllowed && broadcaster.SubscriberCount > 0;
            if (active)
            {
                var source = EnsureSource();
                if (source is { IsAvailable: true })
                {
                    try
                    {
                        if (source.TryCaptureFrame(out var captured))
                        {
                            var jpegBytes = ScreenFrameEncoder.EncodeJpeg(captured, options.ScreenStream.MaxWidth, options.ScreenStream.JpegQuality);
                            var frame = new ScreenFrame(
                                sequence.Next(),
                                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                                Math.Min(captured.Width, options.ScreenStream.MaxWidth),
                                captured.Width > options.ScreenStream.MaxWidth
                                    ? (int)Math.Round(captured.Height * (options.ScreenStream.MaxWidth / (double)captured.Width))
                                    : captured.Height,
                                jpegBytes);
                            broadcaster.Publish(frame);
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
                lock (_modeGate)
                {
                    _source?.Dispose();
                    _source = null;
                }
            }

            var delay = active
                ? TimeSpan.FromSeconds(1d / options.ScreenStream.TargetFps)
                : TimeSpan.FromMilliseconds(500);
            await Task.Delay(delay, stoppingToken);
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        lock (_modeGate)
        {
            _source?.Dispose();
            _source = null;
        }
        await base.StopAsync(cancellationToken);
    }

    private IScreenCaptureSource? EnsureSource()
    {
        lock (_modeGate)
        {
            if (_source is not null) return _source;
            if (_activeMode is not { } mode) return null;
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
                return null;
            }
            return _source;
        }
    }

    private static bool IsRecoverableCaptureFailure(Exception error) => error is
        InvalidOperationException or
        ObjectDisposedException or
        System.Runtime.InteropServices.COMException;
}
