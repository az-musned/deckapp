using DeckWindowsAgent.Protocol;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Capabilities;

public interface IAgentCapabilityService
{
    Task<AgentCapabilitySnapshot> SnapshotAsync(CancellationToken cancellationToken);
    Task<AgentCapabilityCommandResult> ExecuteAsync(AgentCapabilityCommandRequest request, CancellationToken cancellationToken);
}

public sealed class AgentCapabilityService(
    IApplicationCapabilityService applications,
    IWindowsAudioSessionService audio,
    IGoXlrCapabilityService goXlr) : IAgentCapabilityService
{
    private readonly SemaphoreSlim _commands = new(1, 1);

    public async Task<AgentCapabilitySnapshot> SnapshotAsync(CancellationToken cancellationToken)
    {
        var goXlrSnapshot = await goXlr.SnapshotAsync(cancellationToken);
        return new AgentCapabilitySnapshot(
            applications.Snapshot(),
            audio.Snapshot(),
            goXlrSnapshot.Channels,
            goXlrSnapshot.Connected,
            PairingService.ProtocolVersion);
    }

    public async Task<AgentCapabilityCommandResult> ExecuteAsync(AgentCapabilityCommandRequest request, CancellationToken cancellationToken)
    {
        ValidateRequest(request);
        if (!await _commands.WaitAsync(TimeSpan.FromSeconds(2), cancellationToken))
            throw new CapabilityUnavailableException("Another capability command is still running.");
        try
        {
            var confirmed = request.Command switch
            {
                "launchApplication" => await applications.LaunchAsync(request.Id, cancellationToken),
                "setAudioVolume" => audio.SetVolume(request.Id, RequiredLevel(request)),
                "setAudioMuted" => audio.SetMuted(request.Id, RequiredMuted(request)),
                "setGoXlrLevel" => await goXlr.SetLevelAsync(request.Id, RequiredLevel(request), cancellationToken),
                "setGoXlrMuted" => await goXlr.SetMutedAsync(request.Id, RequiredMuted(request), cancellationToken),
                _ => throw new CapabilityUnavailableException("Unknown capability command.")
            };
            var snapshot = await SnapshotAsync(cancellationToken);
            confirmed = confirmed && ConfirmedBySnapshot(request, snapshot);
            var message = confirmed ? "Confirmed by Windows Agent state." : "The requested state could not be confirmed.";
            return new AgentCapabilityCommandResult(confirmed, message, snapshot, PairingService.ProtocolVersion);
        }
        finally { _commands.Release(); }
    }

    private static void ValidateRequest(AgentCapabilityCommandRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Command) || request.Command.Length > 32 ||
            string.IsNullOrWhiteSpace(request.Id) || request.Id.Length > 128)
            throw new CapabilityUnavailableException("Invalid capability command.");
    }

    private static double RequiredLevel(AgentCapabilityCommandRequest request) =>
        request.Value is { } value && double.IsFinite(value) && value is >= 0 and <= 1
            ? value
            : throw new CapabilityUnavailableException("Volume and level values must be between 0 and 1.");

    private static bool RequiredMuted(AgentCapabilityCommandRequest request) =>
        request.Muted ?? throw new CapabilityUnavailableException("The mute command requires a Boolean muted value.");

    private static bool ConfirmedBySnapshot(AgentCapabilityCommandRequest request, AgentCapabilitySnapshot snapshot) =>
        request.Command switch
        {
            "launchApplication" => snapshot.Applications.Any(item => item.Id == request.Id && item.IsRunning),
            "setAudioVolume" => snapshot.AudioSessions.Any(item => item.Id == request.Id &&
                request.Value is { } value && Math.Abs(item.Volume - value) <= 0.011),
            "setAudioMuted" => snapshot.AudioSessions.Any(item => item.Id == request.Id && item.IsMuted == request.Muted),
            "setGoXlrLevel" => snapshot.GoXlrChannels.Any(item => item.Id == request.Id &&
                request.Value is { } value && Math.Abs(item.Level - value) <= 0.011),
            "setGoXlrMuted" => snapshot.GoXlrChannels.Any(item => item.Id == request.Id && item.IsMuted == request.Muted),
            _ => false
        };
}
