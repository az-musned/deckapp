namespace DeckWindowsAgent.Audio.Models;

public sealed record AudioEndpointInfo(
    string Id,
    string DisplayName,
    string DataFlow,
    bool IsGoXlrCandidate,
    IReadOnlyList<string> SuggestedChannelIds);

public sealed record AudioChannelMappingInfo(
    string Id,
    string DisplayName,
    string? EndpointId,
    bool IsAvailable);

public sealed record AudioMeterChannelState(
    string Id,
    string DisplayName,
    string? EndpointId,
    bool Available,
    float LinearPeak,
    float Decibels,
    float DisplayLevel,
    float PeakHold,
    bool Clipping);

public sealed record AudioMeterSnapshot(
    string Type,
    ulong Sequence,
    long Timestamp,
    IReadOnlyList<AudioMeterChannelState> Channels,
    int ProtocolVersion);

public sealed record AudioChannelMappingRequest(string? EndpointId);
