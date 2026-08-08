using System.Net.WebSockets;
using System.Text.Json;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Audio;

public static class AudioMeterWebSocketEndpoint
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static void MapAudioMeterWebSocket(this WebApplication app) =>
        app.Map("/api/v1/audio/meters/ws", HandleAsync);

    private static async Task HandleAsync(HttpContext context)
    {
        var pairing = context.RequestServices.GetRequiredService<PairingService>();
        var meters = context.RequestServices.GetRequiredService<AudioMeterService>();
        var broadcaster = context.RequestServices.GetRequiredService<AudioMeterBroadcaster>();
        var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("DeckWindowsAgent.AudioMeterWebSocket");

        if (!Authenticate(context, pairing)) { context.Response.StatusCode = StatusCodes.Status401Unauthorized; return; }
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = StatusCodes.Status400BadRequest; return; }

        var reducedBandwidth = string.Equals(context.Request.Query["mode"], "remote", StringComparison.OrdinalIgnoreCase)
            || string.Equals(context.Request.Query["mode"], "reduced", StringComparison.OrdinalIgnoreCase);
        AudioMeterSubscription subscription;
        try { subscription = broadcaster.Subscribe(reducedBandwidth); }
        catch (InvalidOperationException error)
        {
            context.Response.StatusCode = StatusCodes.Status429TooManyRequests;
            await context.Response.WriteAsJsonAsync(new { error = error.Message });
            return;
        }

        using (subscription)
        using (var socket = await context.WebSockets.AcceptWebSocketAsync())
        {
            ulong connectionSequence = 0;
            logger.LogInformation("Authenticated audio meter client connected in {Mode} mode.", reducedBandwidth ? "reduced" : "local");
            try
            {
                await SendAsync(socket, meters.CurrentSnapshot with { Sequence = ++connectionSequence }, context.RequestAborted);
                await foreach (var snapshot in subscription.Reader.ReadAllAsync(context.RequestAborted))
                {
                    if (socket.State != WebSocketState.Open) break;
                    await SendAsync(socket, snapshot with { Sequence = ++connectionSequence }, context.RequestAborted);
                }
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
            {
                // The HTTP request or application is shutting down.
            }
            catch (WebSocketException)
            {
                // The peer disconnected between meter frames.
            }
            finally
            {
                if (socket.State == WebSocketState.CloseReceived)
                    await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closed.", CancellationToken.None);
                logger.LogInformation("Audio meter client disconnected.");
            }
        }
    }

    private static Task SendAsync(WebSocket socket, object value, CancellationToken cancellationToken)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        return socket.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken);
    }

    private static bool Authenticate(HttpContext context, PairingService pairing)
    {
        var authorization = context.Request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && pairing.Authenticate(authorization[prefix.Length..].Trim());
    }
}
