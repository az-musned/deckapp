using System.Net.WebSockets;
using System.Text.Json;
using DeckWindowsAgent.Input;
using DeckWindowsAgent.Protocol;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Transport;

public static class InputWebSocketEndpoint
{
    private const int MaximumMessageBytes = 16 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static void MapInputWebSocket(this WebApplication app)
    {
        app.Map("/api/v1/agent/input", HandleAsync);
    }

    private static async Task HandleAsync(HttpContext context)
    {
        var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("DeckWindowsAgent.InputWebSocket");
        var pairing = context.RequestServices.GetRequiredService<PairingService>();
        var safety = context.RequestServices.GetRequiredService<AgentSafetyState>();
        var sink = context.RequestServices.GetRequiredService<IWindowsInputSink>();
        var sessions = context.RequestServices.GetRequiredService<InputSessionRegistry>();

        if (!Authenticate(context, pairing)) { context.Response.StatusCode = StatusCodes.Status401Unauthorized; return; }
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = StatusCodes.Status400BadRequest; return; }
        if (!safety.RemoteInputAllowed || safety.EmergencyInputDisabled || !sink.IsAvailable)
        {
            context.Response.StatusCode = StatusCodes.Status409Conflict;
            await context.Response.WriteAsJsonAsync(new InputProtocolError("unavailable", "Input injection is unavailable."));
            return;
        }
        if (!sessions.TryReserve(out var sessionId))
        {
            context.Response.StatusCode = StatusCodes.Status409Conflict;
            await context.Response.WriteAsJsonAsync(new InputProtocolError("busy", "Another input session is active."));
            return;
        }

        WebSocket? socket = null;
        var endReason = "request ended";
        try
        {
            socket = await context.WebSockets.AcceptWebSocketAsync();
            sessions.Attach(sessionId, socket);
            logger.LogInformation("Input session {SessionId} opened.", sessionId);
            var processor = new InputBatchProcessor(sink);
            await SendJsonAsync(socket, new InputSessionHello(
                sessionId,
                PairingService.ProtocolVersion,
                "ready",
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()), context.RequestAborted);

            while (socket.State == WebSocketState.Open && !context.RequestAborted.IsCancellationRequested)
            {
                if (!safety.RemoteInputAllowed || safety.EmergencyInputDisabled)
                {
                    endReason = "Windows safety state disabled input";
                    await socket.CloseOutputAsync(WebSocketCloseStatus.PolicyViolation, "Input disabled on Windows.", CancellationToken.None);
                    break;
                }

                var message = await ReceiveMessageAsync(socket, context.RequestAborted);
                if (message is null)
                {
                    endReason = "client sent a WebSocket close frame";
                    break;
                }

                try
                {
                    var batch = JsonSerializer.Deserialize<InputBatchRequest>(message, JsonOptions)
                        ?? throw new JsonException("Missing input batch.");
                    var result = await processor.ProcessAsync(batch, context.RequestAborted);
                    await SendJsonAsync(socket, result, context.RequestAborted);
                }
                catch (InputInjectionException)
                {
                    endReason = "Windows rejected input injection";
                    await SendJsonAsync(socket, new InputProtocolError("unavailable", "Windows rejected input injection."), CancellationToken.None);
                    await socket.CloseOutputAsync(WebSocketCloseStatus.InternalServerError, "Input unavailable.", CancellationToken.None);
                    break;
                }
                catch (JsonException)
                {
                    endReason = "client sent invalid JSON input";
                    await SendJsonAsync(socket, new InputProtocolError("failed", "Invalid input message."), CancellationToken.None);
                    await socket.CloseOutputAsync(WebSocketCloseStatus.InvalidPayloadData, "Invalid input message.", CancellationToken.None);
                    break;
                }
                catch (InvalidOperationException)
                {
                    endReason = "client violated the input protocol";
                    await SendJsonAsync(socket, new InputProtocolError("failed", "Input protocol violation."), CancellationToken.None);
                    await socket.CloseOutputAsync(WebSocketCloseStatus.PolicyViolation, "Protocol violation.", CancellationToken.None);
                    break;
                }
            }

            if (socket.State == WebSocketState.CloseReceived)
                await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closed.", CancellationToken.None);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            endReason = "HTTP request was aborted";
        }
        catch (WebSocketException error)
        {
            endReason = "peer reset the WebSocket transport";
            logger.LogInformation(error, "Input session {SessionId} ended after a peer transport reset.", sessionId);
        }
        finally
        {
            await sink.ReleaseAllAsync(CancellationToken.None);
            sessions.End(sessionId);
            socket?.Dispose();
            logger.LogInformation("Input session {SessionId} ended: {EndReason}. Held input was released.", sessionId, endReason);
        }
    }

    private static bool Authenticate(HttpContext context, PairingService pairing)
    {
        var authorization = context.Request.Headers["Authorization"].ToString();
        const string prefix = "Bearer ";
        return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && pairing.Authenticate(authorization[prefix.Length..].Trim());
    }

    private static async Task<byte[]?> ReceiveMessageAsync(WebSocket socket, CancellationToken cancellationToken)
    {
        var receiveBuffer = new byte[4 * 1024];
        using var message = new MemoryStream();
        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(receiveBuffer), cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close) return null;
            if (result.MessageType != WebSocketMessageType.Text)
                throw new JsonException("Only text messages are allowed.");
            if (message.Length + result.Count > MaximumMessageBytes)
                throw new InvalidOperationException("Input message is too large.");
            await message.WriteAsync(receiveBuffer.AsMemory(0, result.Count), cancellationToken);
            if (result.EndOfMessage) return message.ToArray();
        }
    }

    private static Task SendJsonAsync<T>(WebSocket socket, T value, CancellationToken cancellationToken)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        return socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, cancellationToken).AsTask();
    }
}
