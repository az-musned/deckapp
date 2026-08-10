namespace DeckWindowsAgent.Discord;

public enum DiscordBridgeState
{
    NotConfigured,
    Disconnected,
    ConnectingToClient,
    AwaitingAuthorization,
    Authenticating,
    Ready
}

public sealed record DiscordVoiceParticipant(string Id, string Username, bool Mute, bool Deaf, bool SelfMute, bool SelfDeaf);

public sealed record DiscordVoiceChannelState(
    string? ChannelId,
    string? ChannelName,
    string? GuildId,
    bool SelfMute,
    bool SelfDeaf,
    IReadOnlyList<DiscordVoiceParticipant> Participants)
{
    public static readonly DiscordVoiceChannelState NotConnected = new(null, null, null, false, false, []);
}

public sealed record DiscordGuildSummary(string Id, string Name);
public sealed record DiscordChannelSummary(string Id, string Name);

public sealed record DiscordStoredToken(string RefreshToken);

/// <summary>Pushed to the phone over the Discord WebSocket whenever the bridge's state or voice snapshot changes.</summary>
public sealed record DiscordStatusMessage(string BridgeState, DiscordVoiceChannelState Voice, string? Error)
{
    public string Type => "status";
}

public sealed record DiscordGuildListMessage(IReadOnlyList<DiscordGuildSummary> Guilds)
{
    public string Type => "guilds";
}

public sealed record DiscordChannelListMessage(string GuildId, IReadOnlyList<DiscordChannelSummary> Channels)
{
    public string Type => "channels";
}

/// <summary>A command frame sent by the phone over the Discord WebSocket.</summary>
public sealed record DiscordCommandRequest(string Command, bool? Value, string? ChannelId, string? GuildId);
