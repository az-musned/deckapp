using System.Net.WebSockets;
using System.Text.Json;
using DeckWindowsAgent.Discord;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Transport;

public static class DiscordWebSocketEndpoint
{
    private const int MaximumMessageBytes = 4 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static void MapDiscordWebSocket(this WebApplication app)
    {
        app.Map("/api/v1/discord/ws", HandleAsync);
    }

    private static async Task HandleAsync(HttpContext context)
    {
        var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("DeckWindowsAgent.DiscordWebSocket");
        var pairing = context.RequestServices.GetRequiredService<PairingService>();
        var bridge = context.RequestServices.GetRequiredService<DiscordBridgeService>();

        if (!Authenticate(context, pairing)) { context.Response.StatusCode = StatusCodes.Status401Unauthorized; return; }
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = StatusCodes.Status400BadRequest; return; }

        using var socket = await context.WebSockets.AcceptWebSocketAsync();
        var sendGate = new SemaphoreSlim(1, 1);

        void OnStateChanged() => FireAndForgetStatus(socket, bridge, sendGate, logger, context.RequestAborted);
        bridge.StateChanged += OnStateChanged;

        try
        {
            await SendStatusAsync(socket, bridge, sendGate, context.RequestAborted);

            while (socket.State == WebSocketState.Open && !context.RequestAborted.IsCancellationRequested)
            {
                var message = await ReceiveMessageAsync(socket, context.RequestAborted);
                if (message is null) break;
                await HandleCommandAsync(socket, bridge, sendGate, message, context.RequestAborted);
            }

            if (socket.State == WebSocketState.CloseReceived)
                await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closed.", CancellationToken.None);
        }
        catch (WebSocketException error)
        {
            logger.LogInformation(error, "Discord bridge session ended after a peer transport reset.");
        }
        finally
        {
            bridge.StateChanged -= OnStateChanged;
        }
    }

    private static void FireAndForgetStatus(WebSocket socket, DiscordBridgeService bridge, SemaphoreSlim sendGate, ILogger logger, CancellationToken cancellationToken)
    {
        _ = Task.Run(async () =>
        {
            try { await SendStatusAsync(socket, bridge, sendGate, cancellationToken); }
            catch (Exception error) { logger.LogDebug(error, "Could not push a Discord status update; the session is likely closing."); }
        }, CancellationToken.None);
    }

    private static async Task HandleCommandAsync(WebSocket socket, DiscordBridgeService bridge, SemaphoreSlim sendGate, byte[] message, CancellationToken cancellationToken)
    {
        DiscordCommandRequest? request;
        try { request = JsonSerializer.Deserialize<DiscordCommandRequest>(message, JsonOptions); }
        catch (JsonException) { return; }

        var client = bridge.Client;
        if (request is null || client is null || client.State != DiscordBridgeState.Ready) return;

        try
        {
            switch (request.Command)
            {
                case "mute":
                    await client.SetMuteAsync(request.Value ?? true, cancellationToken);
                    break;
                case "deafen":
                    await client.SetDeafenAsync(request.Value ?? true, cancellationToken);
                    break;
                case "join" when request.ChannelId is not null:
                    await client.JoinVoiceChannelAsync(request.ChannelId, cancellationToken);
                    break;
                case "leave":
                    await client.LeaveVoiceChannelAsync(cancellationToken);
                    break;
                case "listGuilds":
                    var guilds = await client.ListGuildsAsync(cancellationToken);
                    await SendJsonAsync(socket, sendGate, new DiscordGuildListMessage(guilds), cancellationToken);
                    break;
                case "listChannels" when request.GuildId is not null:
                    var channels = await client.ListVoiceChannelsAsync(request.GuildId, cancellationToken);
                    await SendJsonAsync(socket, sendGate, new DiscordChannelListMessage(request.GuildId, channels), cancellationToken);
                    break;
            }
        }
        catch (Exception)
        {
            // Surfaced to the phone via the next status push (DiscordRpcClient.LastError); nothing more to do here.
        }
    }

    private static Task SendStatusAsync(WebSocket socket, DiscordBridgeService bridge, SemaphoreSlim sendGate, CancellationToken cancellationToken) =>
        SendJsonAsync(socket, sendGate, BuildStatusMessage(bridge), cancellationToken);

    private static DiscordStatusMessage BuildStatusMessage(DiscordBridgeService bridge)
    {
        if (!bridge.IsConfigured)
        {
            return new DiscordStatusMessage(
                DiscordBridgeState.NotConfigured.ToString(),
                DiscordVoiceChannelState.NotConnected,
                "Set Agent:DiscordClientId and Agent:DiscordClientSecret on the PC to enable the Discord widget.");
        }
        var client = bridge.Client;
        if (client is null)
        {
            return new DiscordStatusMessage(DiscordBridgeState.Disconnected.ToString(), DiscordVoiceChannelState.NotConnected, null);
        }
        return new DiscordStatusMessage(client.State.ToString(), client.Voice, client.LastError);
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
        var receiveBuffer = new byte[2 * 1024];
        using var message = new MemoryStream();
        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(receiveBuffer), cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close) return null;
            if (result.MessageType != WebSocketMessageType.Text) return [];
            if (message.Length + result.Count > MaximumMessageBytes) return [];
            await message.WriteAsync(receiveBuffer.AsMemory(0, result.Count), cancellationToken);
            if (result.EndOfMessage) return message.ToArray();
        }
    }

    private static async Task SendJsonAsync<T>(WebSocket socket, SemaphoreSlim sendGate, T value, CancellationToken cancellationToken)
    {
        if (socket.State != WebSocketState.Open) return;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        await sendGate.WaitAsync(cancellationToken);
        try
        {
            if (socket.State != WebSocketState.Open) return;
            await socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, cancellationToken);
        }
        finally { sendGate.Release(); }
    }
}
