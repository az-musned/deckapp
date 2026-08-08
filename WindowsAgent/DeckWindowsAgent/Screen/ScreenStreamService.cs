using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Screen.Models;

namespace DeckWindowsAgent.Screen;

public sealed class ScreenStreamService(
    AgentOptions options,
    IScreenCaptureSource source,
    AgentSafetyState safety,
    ScreenStreamBroadcaster broadcaster,
    ScreenStreamSequence sequence,
    ILogger<ScreenStreamService> logger) : BackgroundService
{
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
            if (active && source.IsAvailable)
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

            var delay = active
                ? TimeSpan.FromSeconds(1d / options.ScreenStream.TargetFps)
                : TimeSpan.FromMilliseconds(500);
            await Task.Delay(delay, stoppingToken);
        }
    }

    private static bool IsRecoverableCaptureFailure(Exception error) => error is
        InvalidOperationException or
        ObjectDisposedException or
        System.Runtime.InteropServices.COMException;
}
