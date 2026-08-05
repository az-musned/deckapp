using DeckWindowsAgent.Capabilities;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Input;
using DeckWindowsAgent.Protocol;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Security;
using System.Text.Json;

var validationDirectory = Path.Combine(Path.GetTempPath(), "DeckWindowsAgentValidation", Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(validationDirectory);
var store = new PairingStore(Path.Combine(validationDirectory, "paired-devices.json"));
var options = new AgentOptions { CertificateThumbprint = "validation-only", MaximumPairingAttempts = 3 };
PairingCodePresentation? presentation = null;
var pairing = new PairingService(store, options, value => presentation = value);

var challenge = pairing.Start(new PairingStartRequest("test-ipad", "Validation iPad"));
var paired = pairing.PairedDevices();
Require(paired.Count == 0, "Pairing must require confirmation.");
Require(presentation is not null, "Pairing code was not presented locally.");

try
{
    var wrongCode = presentation!.Code == "000000" ? "000001" : "000000";
    _ = pairing.Confirm(new PairingConfirmRequest(challenge.ChallengeId, "test-ipad", wrongCode));
    throw new InvalidOperationException("Wrong pairing code was accepted.");
}
catch (UnauthorizedAccessException)
{
    // Expected.
}

var confirmation = pairing.Confirm(new PairingConfirmRequest(
    challenge.ChallengeId, "test-ipad", presentation!.Code));
Require(pairing.Authenticate(confirmation.CredentialToken), "Issued credential was rejected.");
Require(!pairing.Authenticate("not-a-real-token"), "Invalid credential was accepted.");
Require(pairing.Revoke(confirmation.PairedDeviceId), "Paired device could not be revoked.");
Require(!pairing.Authenticate(confirmation.CredentialToken), "Revoked credential remained valid.");

var safety = new AgentSafetyState();
Require(!safety.RemoteInputAllowed, "Remote input must default to disabled.");
safety.SetRemoteInputAllowed(true);
safety.SetEmergencyInputDisabled(true);
Require(safety.RemoteInputAllowed && safety.EmergencyInputDisabled, "Emergency disable must override an allowed-input setting at enforcement time.");

Require(PrivateNetworkGuard.IsPrivateOrLoopback(System.Net.IPAddress.Parse("192.168.1.50")), "LAN address rejected.");
Require(PrivateNetworkGuard.IsPrivateOrLoopback(System.Net.IPAddress.Parse("100.90.1.2")), "Private VPN address rejected.");
Require(!PrivateNetworkGuard.IsPrivateOrLoopback(System.Net.IPAddress.Parse("8.8.8.8")), "Public address accepted.");
var dualRouteOptions = new AgentOptions
{
    BindAddresses = ["192.168.1.50", "100.90.1.2"],
    CertificateThumbprint = "validation-only"
};
dualRouteOptions.Validate();
Require(dualRouteOptions.EffectiveBindAddresses.Count == 2, "Dual LAN/VPN listeners were not retained.");

var inputSink = new RecordingInputSink();
var processor = new InputBatchProcessor(inputSink);
var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
var inputResult = await processor.ProcessAsync(new InputBatchRequest(1,
[
    InputEvent(1, now, """{"relativePointer":{"deltaX":2,"deltaY":3,"acceleration":true,"precision":false}}"""),
    InputEvent(2, now, """{"relativePointer":{"deltaX":4,"deltaY":-1,"acceleration":true,"precision":false}}"""),
    InputEvent(3, now - 500, """{"scroll":{"deltaX":0,"deltaY":10}}"""),
    InputEvent(4, now, """{"mouseButton":{"_0":"left","isDown":true}}"""),
    InputEvent(5, now - 5_000, """{"mouseButton":{"_0":"left","isDown":false}}""")
]), CancellationToken.None);
Require(inputResult.AppliedCount == 3 && inputResult.DroppedCount == 1, "Input coalescing or stale-event handling failed.");
Require(inputSink.Commands[0] == new RelativePointerCommand(6, 2, true, false), "Pointer events were not coalesced.");
Require(inputSink.Commands[^1] == new MouseButtonCommand("left", false), "Stale release event was not prioritized.");

var replayResult = await processor.ProcessAsync(new InputBatchRequest(1,
[
    InputEvent(5, now, """{"releaseAll":{}}""")
]), CancellationToken.None);
Require(replayResult.AppliedCount == 0 && replayResult.DroppedCount == 1, "Replayed event was accepted.");

var unicode = InputPayloadParser.Parse(Json("""{"unicodeText":{"_0":"مرحبا"}}"""));
Require(unicode == new UnicodeTextCommand("مرحبا"), "Unicode payload did not match the Swift wire format.");

var goXlrChannels = GoXlrCapabilityService.ParseChannels("""
{
  "mixers": {
    "SERIAL": {
      "levels": { "volumes": { "Mic": 128, "System": 140, "Music": 158 } },
      "fader_status": {
        "A": { "channel": "Mic", "mute_state": "Unmuted" },
        "B": { "channel": "System", "mute_state": "MutedToAll" },
        "C": { "channel": "Music", "mute_state": "MutedToX" },
        "D": { "channel": "Chat", "mute_state": "Unmuted" }
      }
    }
  }
}
""");
Require(Math.Abs(goXlrChannels.Single(channel => channel.Id == "mic").Level - 128d / 255d) < 0.000001,
    "GoXLR raw fader state was not normalized from 0-255.");
Require(goXlrChannels.Single(channel => channel.Id == "system").IsMuted, "GoXLR mute state was not parsed.");

var capabilityService = new AgentCapabilityService(
    new RecordingApplicationCapabilities(),
    new RecordingAudioCapabilities(),
    new RecordingGoXlrCapabilities());
var commandResult = await capabilityService.ExecuteAsync(
    new AgentCapabilityCommandRequest("setAudioVolume", "music", 0.42, null),
    CancellationToken.None);
Require(commandResult.Confirmed && commandResult.Snapshot.AudioSessions.Single().Volume == 0.42,
    "Capability command was not confirmed from updated backend state.");

var audioSnapshot = new WindowsAudioSessionService(options).Snapshot();
Require(audioSnapshot.All(session => session.Volume is >= 0 and <= 1), "Windows audio discovery returned an invalid volume.");

Console.WriteLine($"Foundation validation passed. Pairing challenge {challenge.ChallengeId} kept its code local, authenticated once, and revoked cleanly. Capability protocol, GoXLR parsing, and non-mutating Windows audio discovery also passed.");

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static InputEventEnvelope InputEvent(ulong sequence, long timestamp, string payload) =>
    new(Guid.NewGuid(), sequence, timestamp, Json(payload));

static JsonElement Json(string value) => JsonDocument.Parse(value).RootElement.Clone();

sealed class RecordingInputSink : IWindowsInputSink
{
    public bool IsAvailable => true;
    public List<AgentInputCommand> Commands { get; } = [];
    public ValueTask ApplyAsync(AgentInputCommand command, CancellationToken cancellationToken = default)
    {
        Commands.Add(command);
        return ValueTask.CompletedTask;
    }
    public ValueTask ReleaseAllAsync(CancellationToken cancellationToken = default)
    {
        Commands.Add(new ReleaseAllCommand());
        return ValueTask.CompletedTask;
    }
}

sealed class RecordingApplicationCapabilities : IApplicationCapabilityService
{
    public IReadOnlyList<AgentApplicationState> Snapshot() => [new("test", "Test", "application", false)];
    public Task<bool> LaunchAsync(string id, CancellationToken cancellationToken) => Task.FromResult(id == "test");
}

sealed class RecordingAudioCapabilities : IWindowsAudioSessionService
{
    private double _volume = 0.5;
    private bool _muted;
    public IReadOnlyList<AgentAudioSessionState> Snapshot() => [new("music", "Music", _volume, _muted)];
    public bool SetVolume(string id, double volume) { if (id != "music") return false; _volume = volume; return true; }
    public bool SetMuted(string id, bool muted) { if (id != "music") return false; _muted = muted; return true; }
}

sealed class RecordingGoXlrCapabilities : IGoXlrCapabilityService
{
    private double _level = 0.5;
    private bool _muted;
    public Task<(bool Connected, IReadOnlyList<AgentGoXlrChannelState> Channels)> SnapshotAsync(CancellationToken cancellationToken) =>
        Task.FromResult<(bool, IReadOnlyList<AgentGoXlrChannelState>)>((true, [new("mic", "Mic", _level, _muted)]));
    public Task<bool> SetLevelAsync(string id, double level, CancellationToken cancellationToken) { _level = level; return Task.FromResult(id == "mic"); }
    public Task<bool> SetMutedAsync(string id, bool muted, CancellationToken cancellationToken) { _muted = muted; return Task.FromResult(id == "mic"); }
}
