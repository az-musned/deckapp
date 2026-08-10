using System.Buffers.Binary;
using System.Net.WebSockets;
using System.Text.Json;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Screen.Models;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Screen;

public static class ScreenStreamWebSocketEndpoint
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private const byte FullFrameType = 1;

    public static void MapScreenStreamWebSocket(this WebApplication app) =>
        app.Map("/api/v1/screen/mirror/ws", HandleAsync);

    private static async Task HandleAsync(HttpContext context)
    {
        var pairing = context.RequestServices.GetRequiredService<PairingService>();
        var safety = context.RequestServices.GetRequiredService<AgentSafetyState>();
        var options = context.RequestServices.GetRequiredService<AgentOptions>();
        var broadcaster = context.RequestServices.GetRequiredService<ScreenStreamBroadcaster>();
        var streamService = context.RequestServices.GetRequiredService<ScreenStreamService>();
        var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("DeckWindowsAgent.ScreenStreamWebSocket");

        if (!Authenticate(context, pairing)) { context.Response.StatusCode = StatusCodes.Status401Unauthorized; return; }
        if (!safety.ScreenShareAllowed) { context.Response.StatusCode = StatusCodes.Status403Forbidden; return; }
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = StatusCodes.Status400BadRequest; return; }

        var mode = string.Equals(context.Request.Query["mode"], "extend", StringComparison.OrdinalIgnoreCase)
            ? ScreenStreamMode.Extend
            : ScreenStreamMode.Mirror;

        if (!streamService.TryReserveMode(mode, out var conflictReason))
        {
            context.Response.StatusCode = StatusCodes.Status409Conflict;
            await context.Response.WriteAsJsonAsync(new { error = conflictReason });
            return;
        }

        ScreenStreamSubscription subscription;
        try { subscription = broadcaster.Subscribe(); }
        catch (InvalidOperationException error)
        {
            context.Response.StatusCode = StatusCodes.Status429TooManyRequests;
            await context.Response.WriteAsJsonAsync(new { error = error.Message });
            return;
        }

        using (subscription)
        using (var socket = await context.WebSockets.AcceptWebSocketAsync())
        using (var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted))
        {
            logger.LogInformation("Authenticated screen mirror client connected in {Mode} mode.", mode);
            var receiveTask = ReceiveControlMessagesAsync(socket, streamService, linkedCts.Token);
            try
            {
                var expectedHeight = ExpectedHeight(mode, options);
                var hello = new ScreenStreamHello(
                    "screen.hello",
                    options.ScreenStream.MaxWidth,
                    expectedHeight,
                    options.ScreenStream.TargetFps,
                    "h264",
                    PairingService.ProtocolVersion,
                    mode == ScreenStreamMode.Extend ? "extend" : "mirror");
                var helloBytes = JsonSerializer.SerializeToUtf8Bytes(hello, JsonOptions);
                await socket.SendAsync(helloBytes, WebSocketMessageType.Text, true, linkedCts.Token);

                await foreach (var frame in subscription.Reader.ReadAllAsync(linkedCts.Token))
                {
                    if (!safety.ScreenShareAllowed || socket.State != WebSocketState.Open) break;
                    await SendFrameAsync(socket, frame, linkedCts.Token);
                }
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
            {
                // The HTTP request or application is shutting down.
            }
            catch (WebSocketException)
            {
                // The peer disconnected between video frames.
            }
            finally
            {
                linkedCts.Cancel();
                try { await receiveTask; } catch (OperationCanceledException) { }
                if (socket.State == WebSocketState.CloseReceived)
                    await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closed.", CancellationToken.None);
                logger.LogInformation("Screen mirror client disconnected.");
            }
        }
    }

    private static async Task ReceiveControlMessagesAsync(WebSocket socket, ScreenStreamService streamService, CancellationToken cancellationToken)
    {
        var buffer = new byte[1024];
        try
        {
            while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                using var messageStream = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(buffer, cancellationToken);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    messageStream.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text || messageStream.Length == 0) continue;
                HandleControlMessage(messageStream.ToArray(), streamService);
            }
        }
        catch (OperationCanceledException)
        {
            // Connection is closing.
        }
        catch (WebSocketException)
        {
            // The peer disconnected.
        }
    }

    private static void HandleControlMessage(byte[] payload, ScreenStreamService streamService)
    {
        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.TryGetProperty("type", out var typeElement)
                && typeElement.GetString() == "screen.requestKeyframe")
            {
                streamService.RequestKeyframe();
            }
        }
        catch (JsonException)
        {
            // Ignore malformed control messages.
        }
    }

    private static int ExpectedHeight(ScreenStreamMode mode, AgentOptions options)
    {
        var deviceName = mode == ScreenStreamMode.Extend
            ? options.ScreenStream.ExtendMonitorDeviceName
            : options.ScreenStream.MirrorMonitorDeviceName;

        var target = string.IsNullOrWhiteSpace(deviceName)
            ? MonitorEnumerator.EnumerateAll().FirstOrDefault(monitor => monitor.IsPrimary)
            : MonitorEnumerator.EnumerateAll().FirstOrDefault(monitor => monitor.DeviceName == deviceName);

        if (target.Width <= 0) return 0;
        var scale = Math.Min(1.0, options.ScreenStream.MaxWidth / (double)target.Width);
        return (int)Math.Round(target.Height * scale);
    }

    private const byte KeyframeFlag = 0x01;

    private static Task SendFrameAsync(WebSocket socket, ScreenFrame frame, CancellationToken cancellationToken)
    {
        var buffer = new byte[26 + frame.Payload.Length];
        var span = buffer.AsSpan();
        span[0] = FullFrameType;
        span[1] = frame.IsKeyframe ? KeyframeFlag : (byte)0;
        BinaryPrimitives.WriteUInt32LittleEndian(span[2..], frame.Sequence);
        BinaryPrimitives.WriteInt64LittleEndian(span[6..], frame.TimestampMilliseconds);
        BinaryPrimitives.WriteUInt32LittleEndian(span[14..], (uint)frame.Width);
        BinaryPrimitives.WriteUInt32LittleEndian(span[18..], (uint)frame.Height);
        BinaryPrimitives.WriteUInt32LittleEndian(span[22..], (uint)frame.Payload.Length);
        frame.Payload.CopyTo(span[26..]);
        return socket.SendAsync(buffer, WebSocketMessageType.Binary, true, cancellationToken);
    }

    private static bool Authenticate(HttpContext context, PairingService pairing)
    {
        var authorization = context.Request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && pairing.Authenticate(authorization[prefix.Length..].Trim());
    }
}
