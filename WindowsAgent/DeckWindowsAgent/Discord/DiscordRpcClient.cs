using System.Collections.Concurrent;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;

namespace DeckWindowsAgent.Discord;

/// <summary>Maintains a connection to the local Discord client over its RPC named pipe: authorizes once via
/// Discord's native consent dialog, authenticates on every reconnect using the stored refresh token, tracks the
/// caller's current voice channel, and exposes mute/deafen/join/leave plus guild and channel lookups.</summary>
public sealed class DiscordRpcClient : IAsyncDisposable
{
    private readonly string _clientId;
    private readonly string _clientSecret;
    private readonly DiscordTokenStore _tokenStore;
    private readonly HttpClient _http;
    private readonly ILogger<DiscordRpcClient> _logger;
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> _pending = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _sendGate = new(1, 1);

    private DiscordIpcTransport? _transport;
    private Task? _receiveLoopTask;
    private TaskCompletionSource<JsonElement>? _readyTcs;
    private string? _authenticatedUserId;
    private string? _voiceStateSubscribedChannelId;

    public DiscordBridgeState State { get; private set; } = DiscordBridgeState.Disconnected;
    public DiscordVoiceChannelState Voice { get; private set; } = DiscordVoiceChannelState.NotConnected;
    public string? LastError { get; private set; }

    public event Action? StateChanged;

    public DiscordRpcClient(
        string clientId,
        string clientSecret,
        DiscordTokenStore tokenStore,
        HttpClient http,
        ILogger<DiscordRpcClient> logger)
    {
        _clientId = clientId;
        _clientSecret = clientSecret;
        _tokenStore = tokenStore;
        _http = http;
        _logger = logger;
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var receiveLoop = await ConnectAndAuthenticateAsync(cancellationToken);
                await receiveLoop;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error)
            {
                LastError = error.Message;
                _logger.LogWarning(error, "Discord RPC connection ended.");
            }
            SetState(DiscordBridgeState.Disconnected);
            await CleanupAsync();
            try { await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken); }
            catch (OperationCanceledException) { break; }
        }
    }

    public Task SetMuteAsync(bool mute, CancellationToken cancellationToken) => SendVoiceSettingsAsync(mute, null, cancellationToken);

    public Task SetDeafenAsync(bool deafen, CancellationToken cancellationToken) => SendVoiceSettingsAsync(null, deafen, cancellationToken);

    public async Task JoinVoiceChannelAsync(string channelId, CancellationToken cancellationToken)
    {
        await SendCommandAsync("SELECT_VOICE_CHANNEL", new JsonObject { ["channel_id"] = channelId, ["force"] = true }, cancellationToken);
        await RefreshVoiceStateAsync(cancellationToken);
    }

    public async Task LeaveVoiceChannelAsync(CancellationToken cancellationToken)
    {
        await SendCommandAsync("SELECT_VOICE_CHANNEL", new JsonObject { ["channel_id"] = null, ["force"] = true }, cancellationToken);
        await RefreshVoiceStateAsync(cancellationToken);
    }

    public async Task<IReadOnlyList<DiscordGuildSummary>> ListGuildsAsync(CancellationToken cancellationToken)
    {
        var response = await SendCommandAsync("GET_GUILDS", null, cancellationToken);
        var guilds = new List<DiscordGuildSummary>();
        foreach (var guild in response.GetProperty("data").GetProperty("guilds").EnumerateArray())
        {
            guilds.Add(new DiscordGuildSummary(guild.GetProperty("id").GetString() ?? "", guild.GetProperty("name").GetString() ?? "Unknown"));
        }
        return guilds;
    }

    public async Task<IReadOnlyList<DiscordChannelSummary>> ListVoiceChannelsAsync(string guildId, CancellationToken cancellationToken)
    {
        var response = await SendCommandAsync("GET_CHANNELS", new JsonObject { ["guild_id"] = guildId }, cancellationToken);
        var channels = new List<DiscordChannelSummary>();
        foreach (var channel in response.GetProperty("data").GetProperty("channels").EnumerateArray())
        {
            const int guildVoiceChannelType = 2;
            if (channel.GetProperty("type").GetInt32() != guildVoiceChannelType) continue;
            channels.Add(new DiscordChannelSummary(channel.GetProperty("id").GetString() ?? "", channel.GetProperty("name").GetString() ?? "Unknown"));
        }
        return channels;
    }

    private async Task<Task> ConnectAndAuthenticateAsync(CancellationToken cancellationToken)
    {
        SetState(DiscordBridgeState.ConnectingToClient);
        var transport = new DiscordIpcTransport();
        if (!await transport.TryConnectAsync(cancellationToken))
            throw new IOException("The Discord desktop client is not running, or its IPC pipe could not be reached.");
        _transport = transport;

        _readyTcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var receiveLoop = Task.Run(() => ReceiveLoopAsync(cancellationToken), CancellationToken.None);
        _receiveLoopTask = receiveLoop;

        await transport.SendAsync(DiscordIpcTransport.OpcodeHandshake, JsonSerializer.Serialize(new { v = 1, client_id = _clientId }), cancellationToken);
        await AwaitWithTimeoutAsync(_readyTcs.Task, TimeSpan.FromSeconds(10), cancellationToken);

        var accessToken = await ObtainAccessTokenAsync(cancellationToken);
        SetState(DiscordBridgeState.Authenticating);
        var authenticateResponse = await SendCommandAsync("AUTHENTICATE", new JsonObject { ["access_token"] = accessToken }, cancellationToken);
        _authenticatedUserId = authenticateResponse.GetProperty("data").GetProperty("user").GetProperty("id").GetString();

        await SendCommandAsync("SUBSCRIBE", new JsonObject(), cancellationToken, evt: "VOICE_CHANNEL_SELECT");
        await SendCommandAsync("SUBSCRIBE", new JsonObject(), cancellationToken, evt: "VOICE_SETTINGS_UPDATE");

        SetState(DiscordBridgeState.Ready);
        await RefreshVoiceStateAsync(cancellationToken);
        return receiveLoop;
    }

    private async Task SendVoiceSettingsAsync(bool? mute, bool? deafen, CancellationToken cancellationToken)
    {
        var args = new JsonObject();
        if (mute is not null) args["mute"] = mute.Value;
        if (deafen is not null) args["deaf"] = deafen.Value;
        await SendCommandAsync("SET_VOICE_SETTINGS", args, cancellationToken);
        await RefreshVoiceStateAsync(cancellationToken);
    }

    private async Task RefreshVoiceStateAsync(CancellationToken cancellationToken)
    {
        try
        {
            var response = await SendCommandAsync("GET_SELECTED_VOICE_CHANNEL", null, cancellationToken);
            var data = response.GetProperty("data");
            Voice = data.ValueKind == JsonValueKind.Null ? DiscordVoiceChannelState.NotConnected : ParseVoiceChannel(data);
            await SyncVoiceStateSubscriptionAsync(cancellationToken);
        }
        catch (Exception error)
        {
            LastError = error.Message;
        }
        StateChanged?.Invoke();
    }

    private DiscordVoiceChannelState ParseVoiceChannel(JsonElement data)
    {
        var channelId = data.GetProperty("id").GetString();
        var channelName = data.TryGetProperty("name", out var nameElement) ? nameElement.GetString() : null;
        var guildId = data.TryGetProperty("guild_id", out var guildElement) && guildElement.ValueKind == JsonValueKind.String
            ? guildElement.GetString()
            : null;

        var participants = new List<DiscordVoiceParticipant>();
        var selfMute = false;
        var selfDeaf = false;
        if (data.TryGetProperty("voice_states", out var states) && states.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in states.EnumerateArray())
            {
                var user = entry.GetProperty("user");
                var id = user.GetProperty("id").GetString() ?? "";
                var username = user.TryGetProperty("username", out var usernameElement) ? usernameElement.GetString() ?? "Unknown" : "Unknown";
                var voiceState = entry.GetProperty("voice_state");
                var mute = voiceState.TryGetProperty("mute", out var muteElement) && muteElement.GetBoolean();
                var deaf = voiceState.TryGetProperty("deaf", out var deafElement) && deafElement.GetBoolean();
                var participantSelfMute = voiceState.TryGetProperty("self_mute", out var selfMuteElement) && selfMuteElement.GetBoolean();
                var participantSelfDeaf = voiceState.TryGetProperty("self_deaf", out var selfDeafElement) && selfDeafElement.GetBoolean();
                participants.Add(new DiscordVoiceParticipant(id, username, mute, deaf, participantSelfMute, participantSelfDeaf));
                if (id == _authenticatedUserId)
                {
                    selfMute = mute || participantSelfMute;
                    selfDeaf = deaf || participantSelfDeaf;
                }
            }
        }
        return new DiscordVoiceChannelState(channelId, channelName, guildId, selfMute, selfDeaf, participants);
    }

    private async Task SyncVoiceStateSubscriptionAsync(CancellationToken cancellationToken)
    {
        var currentChannelId = Voice.ChannelId;
        if (currentChannelId == _voiceStateSubscribedChannelId) return;

        if (_voiceStateSubscribedChannelId is not null)
        {
            await TrySendAsync("UNSUBSCRIBE", new JsonObject { ["channel_id"] = _voiceStateSubscribedChannelId }, "VOICE_STATE_UPDATE", cancellationToken);
        }
        if (currentChannelId is not null)
        {
            await TrySendAsync("SUBSCRIBE", new JsonObject { ["channel_id"] = currentChannelId }, "VOICE_STATE_UPDATE", cancellationToken);
        }
        _voiceStateSubscribedChannelId = currentChannelId;
    }

    private async Task TrySendAsync(string cmd, JsonNode? args, string evt, CancellationToken cancellationToken)
    {
        try { await SendCommandAsync(cmd, args, cancellationToken, evt: evt); }
        catch (Exception error) { _logger.LogDebug(error, "Discord RPC {Command} for {Event} did not complete.", cmd, evt); }
    }

    private void HandleEvent(string evt, JsonElement root, CancellationToken cancellationToken)
    {
        switch (evt)
        {
            case "READY":
                _readyTcs?.TrySetResult(root);
                break;
            case "VOICE_CHANNEL_SELECT":
            case "VOICE_SETTINGS_UPDATE":
            case "VOICE_STATE_UPDATE":
            case "VOICE_STATE_CREATE":
            case "VOICE_STATE_DELETE":
                // Refresh on a separate task: this handler runs inline on the receive loop, and
                // RefreshVoiceStateAsync awaits a command reply that only that same loop can deliver.
                // Awaiting it here would deadlock the loop against itself.
                _ = Task.Run(() => RefreshVoiceStateAsync(cancellationToken), cancellationToken);
                break;
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var (opcode, json) = await _transport!.ReceiveAsync(cancellationToken);
                if (opcode == DiscordIpcTransport.OpcodeClose) throw new IOException("Discord closed the IPC connection.");
                if (opcode != DiscordIpcTransport.OpcodeFrame) continue;

                using var document = JsonDocument.Parse(json);
                var root = document.RootElement.Clone();

                if (root.TryGetProperty("nonce", out var nonceElement)
                    && nonceElement.ValueKind == JsonValueKind.String
                    && nonceElement.GetString() is { } nonce
                    && _pending.TryRemove(nonce, out var tcs))
                {
                    if (root.TryGetProperty("evt", out var errorEvent) && errorEvent.ValueKind == JsonValueKind.String && errorEvent.GetString() == "ERROR")
                        tcs.TrySetException(new InvalidOperationException(DescribeError(root)));
                    else
                        tcs.TrySetResult(root);
                    continue;
                }

                if (root.TryGetProperty("evt", out var evtElement) && evtElement.ValueKind == JsonValueKind.String && evtElement.GetString() is { } evtName)
                {
                    HandleEvent(evtName, root, cancellationToken);
                }
            }
        }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested)
        {
            LastError = error.Message;
            FailAllPending(error);
            throw;
        }
    }

    private async Task<JsonElement> SendCommandAsync(string cmd, JsonNode? args, CancellationToken cancellationToken, string? evt = null, TimeSpan? timeout = null)
    {
        if (_transport is null) throw new InvalidOperationException("The Discord IPC transport is not connected.");
        var nonce = Guid.NewGuid().ToString("N");
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[nonce] = tcs;

        var frame = new JsonObject
        {
            ["cmd"] = cmd,
            ["args"] = args ?? new JsonObject(),
            ["nonce"] = nonce
        };
        if (evt is not null) frame["evt"] = evt;

        await _sendGate.WaitAsync(cancellationToken);
        try { await _transport.SendAsync(DiscordIpcTransport.OpcodeFrame, frame.ToJsonString(), cancellationToken); }
        finally { _sendGate.Release(); }

        try { return await AwaitWithTimeoutAsync(tcs.Task, timeout ?? TimeSpan.FromSeconds(10), cancellationToken); }
        finally { _pending.TryRemove(nonce, out _); }
    }

    private static async Task<JsonElement> AwaitWithTimeoutAsync(Task<JsonElement> task, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        try
        {
            var delay = Task.Delay(Timeout.Infinite, linked.Token);
            var completed = await Task.WhenAny(task, delay);
            if (completed != task)
            {
                if (cancellationToken.IsCancellationRequested) throw new OperationCanceledException(cancellationToken);
                throw new TimeoutException("Discord RPC did not respond in time.");
            }
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("Discord RPC did not respond in time.");
        }
        return await task;
    }

    private static string DescribeError(JsonElement root) =>
        root.TryGetProperty("data", out var data) && data.TryGetProperty("message", out var message)
            ? message.GetString() ?? "Discord RPC returned an error."
            : "Discord RPC returned an error.";

    private void FailAllPending(Exception error)
    {
        foreach (var key in _pending.Keys.ToArray())
        {
            if (_pending.TryRemove(key, out var tcs)) tcs.TrySetException(error);
        }
    }

    private async Task<string> ObtainAccessTokenAsync(CancellationToken cancellationToken)
    {
        var stored = _tokenStore.Load();
        if (stored is not null)
        {
            try { return await RefreshAccessTokenAsync(stored.RefreshToken, cancellationToken); }
            catch (Exception error)
            {
                _logger.LogWarning(error, "The stored Discord refresh token was rejected; re-authorizing.");
                _tokenStore.Clear();
            }
        }

        SetState(DiscordBridgeState.AwaitingAuthorization);
        var authorizeArgs = new JsonObject { ["client_id"] = _clientId, ["scopes"] = new JsonArray(JsonValue.Create("rpc")) };
        var authorizeResponse = await SendCommandAsync("AUTHORIZE", authorizeArgs, cancellationToken, timeout: TimeSpan.FromMinutes(2));
        var code = authorizeResponse.GetProperty("data").GetProperty("code").GetString()
            ?? throw new InvalidOperationException("Discord did not return an authorization code.");
        return await ExchangeCodeAsync(code, cancellationToken);
    }

    private Task<string> ExchangeCodeAsync(string code, CancellationToken cancellationToken) => PostTokenAsync(new Dictionary<string, string>
    {
        ["client_id"] = _clientId,
        ["client_secret"] = _clientSecret,
        ["grant_type"] = "authorization_code",
        ["code"] = code
    }, cancellationToken);

    private Task<string> RefreshAccessTokenAsync(string refreshToken, CancellationToken cancellationToken) => PostTokenAsync(new Dictionary<string, string>
    {
        ["client_id"] = _clientId,
        ["client_secret"] = _clientSecret,
        ["grant_type"] = "refresh_token",
        ["refresh_token"] = refreshToken
    }, cancellationToken);

    private async Task<string> PostTokenAsync(Dictionary<string, string> form, CancellationToken cancellationToken)
    {
        using var response = await _http.PostAsync("https://discord.com/api/oauth2/token", new FormUrlEncodedContent(form), cancellationToken);
        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken: cancellationToken);
        var accessToken = json.GetProperty("access_token").GetString() ?? throw new InvalidOperationException("Discord's token response was missing an access token.");
        var refreshToken = json.GetProperty("refresh_token").GetString() ?? throw new InvalidOperationException("Discord's token response was missing a refresh token.");
        _tokenStore.Save(new DiscordStoredToken(refreshToken));
        return accessToken;
    }

    private void SetState(DiscordBridgeState state)
    {
        State = state;
        StateChanged?.Invoke();
    }

    private async Task CleanupAsync()
    {
        FailAllPending(new IOException("The Discord RPC connection was reset."));
        if (_transport is not null)
        {
            await _transport.DisposeAsync();
            _transport = null;
        }
        if (_receiveLoopTask is { } receiveLoopTask)
        {
            // The loop may still be unwinding after the transport above was disposed; observe its
            // fault instead of awaiting it so a slow pipe teardown can't block reconnection.
            _ = receiveLoopTask.ContinueWith(
                task => { _ = task.Exception; },
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            _receiveLoopTask = null;
        }
        _voiceStateSubscribedChannelId = null;
        _authenticatedUserId = null;
        Voice = DiscordVoiceChannelState.NotConnected;
    }

    public async ValueTask DisposeAsync()
    {
        if (_transport is not null) await _transport.DisposeAsync();
    }
}
