namespace DeckWindowsAgent.Protocol;

public sealed record AgentApplicationState(string Id, string Name, string Kind, bool IsRunning);
public sealed record AgentAudioSessionState(string Id, string Name, double Volume, bool IsMuted);
public sealed record AgentGoXlrChannelState(string Id, string Name, double Level, bool IsMuted);

public sealed record AgentCapabilitySnapshot(
    IReadOnlyList<AgentApplicationState> Applications,
    IReadOnlyList<AgentAudioSessionState> AudioSessions,
    IReadOnlyList<AgentGoXlrChannelState> GoXlrChannels,
    bool GoXlrConnected,
    int ProtocolVersion);

public sealed record AgentCapabilityCommandRequest(string Command, string Id, double? Value, bool? Muted);

public sealed record AgentCapabilityCommandResult(
    bool Confirmed,
    string Message,
    AgentCapabilitySnapshot Snapshot,
    int ProtocolVersion);

public sealed class CapabilityUnavailableException(string message) : Exception(message);
