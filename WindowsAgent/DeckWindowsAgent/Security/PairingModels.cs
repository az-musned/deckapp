namespace DeckWindowsAgent.Security;

public sealed record PairingStartRequest(string ClientDeviceId, string DeviceName);
public sealed record PairingChallengeResponse(Guid ChallengeId, DateTimeOffset ExpiresAt, string AgentDisplayName);
public sealed record PairingConfirmRequest(Guid ChallengeId, string ClientDeviceId, string Code);
public sealed record PairingConfirmResponse(Guid PairedDeviceId, string CredentialToken, int ProtocolVersion);
public sealed record PairedDevice(Guid Id, string ClientDeviceId, string DeviceName, DateTimeOffset PairedAt, string TokenHash);
public sealed record PairingCodePresentation(string DeviceName, string Code, DateTimeOffset ExpiresAt);

internal sealed class ActivePairingChallenge
{
    public required Guid Id { get; init; }
    public required string ClientDeviceId { get; init; }
    public required string DeviceName { get; init; }
    public required string Code { get; init; }
    public required DateTimeOffset ExpiresAt { get; init; }
    public int Attempts { get; set; }
}
