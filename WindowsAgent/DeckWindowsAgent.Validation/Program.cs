using DeckWindowsAgent.Audio;
using DeckWindowsAgent.Audio.Models;
using DeckWindowsAgent.Capabilities;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Input;
using DeckWindowsAgent.Protocol;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Security;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;

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

var safety = new AgentSafetyState(remoteInputAllowed: false);
Require(!safety.RemoteInputAllowed, "Remote input must honor an explicitly disabled startup setting.");
safety.SetRemoteInputAllowed(true);
safety.SetEmergencyInputDisabled(true);
Require(safety.RemoteInputAllowed && safety.EmergencyInputDisabled, "Emergency disable must override an allowed-input setting at enforcement time.");
Require(new AgentSafetyState().RemoteInputAllowed, "Remote input must default to enabled.");

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

var sessionRegistry = new InputSessionRegistry(2);
Require(sessionRegistry.TryReserve(out var firstSession), "First input session was rejected.");
Require(sessionRegistry.TryReserve(out var secondSession), "Second input session was rejected.");
Require(firstSession != secondSession, "Concurrent input sessions received the same ID.");
Require(!sessionRegistry.TryReserve(out _), "Input session limit was not enforced.");
sessionRegistry.End(firstSession);
Require(sessionRegistry.TryReserve(out _), "A disconnected input session did not release its slot.");

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

Require(Math.Abs(AudioMeterProcessor.LinearToDecibels(0.1f) - -20f) < 0.001f,
    "Linear amplitude to decibel conversion is incorrect.");
Require(AudioMeterProcessor.LinearToDecibels(0) == -60f,
    "Silent audio did not clamp to the meter floor.");
Require(Math.Abs(AudioMeterProcessor.NormalizeDisplayLevel(-30) - 0.5f) < 0.001f,
    "Decibel display normalization is incorrect.");

var meterProcessor = new AudioMeterProcessor();
var attacked = meterProcessor.Process(1, 0);
var decayed = meterProcessor.Process(0, 100);
Require(attacked.DisplayLevel - 0 > attacked.DisplayLevel - decayed.DisplayLevel,
    "Meter attack is not faster than decay.");
var held = meterProcessor.Process(0, 500);
Require(Math.Abs(held.PeakHold - attacked.PeakHold) < 0.001f, "Peak hold expired too early.");
var expired = meterProcessor.Process(0, 800);
Require(expired.PeakHold < held.PeakHold, "Peak hold did not expire.");
Require(new AudioMeterProcessor().Process(0.99f, 0).IsClipping, "Near-zero-dB audio did not report clipping.");
Require(!new AudioMeterProcessor().Process(0.9f, 0).IsClipping, "Non-clipping audio reported clipping.");

var mappingPath = Path.Combine(validationDirectory, "audio-channel-mappings.json");
var meterOptions = new AgentOptions
{
    CertificateThumbprint = "validation-only",
    AudioMeters = new AudioMeterOptions
    {
        Channels = [new AudioMeterChannelOptions { Id = "music", DisplayName = "Music" }]
    }
};
var mappingStore = new AudioChannelMappingStore(mappingPath, meterOptions);
mappingStore.SetMapping("music", "endpoint-1");
var reloadedMappings = new AudioChannelMappingStore(mappingPath, meterOptions);
Require(reloadedMappings.Snapshot([new("endpoint-1", "GoXLR Music", "render", true, ["music"])])
        .Single().EndpointId == "endpoint-1",
    "Audio channel mapping did not persist.");
reloadedMappings.SetMapping("music", null);
Require(new AudioChannelMappingStore(mappingPath, meterOptions).Snapshot([]).Single().EndpointId is null,
    "Clearing an audio channel mapping did not persist.");
reloadedMappings.SetMapping("music", "endpoint-1");

var fakeSource = new RecordingAudioEndpointMeterSource([], new Dictionary<string, float>());
var meterService = new AudioMeterService(
    meterOptions,
    fakeSource,
    reloadedMappings,
    new AudioMeterBroadcaster(meterOptions),
    new AudioMeterSequence(),
    NullLogger<AudioMeterService>.Instance);
meterService.RefreshEndpoints();
var unavailableSnapshot = meterService.Sample(1_000);
Require(!unavailableSnapshot.Channels.Single().Available && unavailableSnapshot.Channels.Single().LinearPeak == 0,
    "A missing mapped endpoint did not report unavailable with zero peak.");
var failingMeterService = new AudioMeterService(
    meterOptions,
    new FailingAudioEndpointMeterSource(),
    reloadedMappings,
    new AudioMeterBroadcaster(meterOptions),
    new AudioMeterSequence(),
    NullLogger<AudioMeterService>.Instance);
failingMeterService.RefreshEndpoints();
var sequence = new AudioMeterSequence();
Require(sequence.Next() == 1 && sequence.Next() == 2, "Audio meter sequence did not progress monotonically.");

var broadcaster = new AudioMeterBroadcaster(meterOptions);
using var reducedSubscription = broadcaster.Subscribe(reducedBandwidth: true);
broadcaster.Publish(new("audio.meters", 1, 1_000, [], 1));
Require(reducedSubscription.Reader.TryRead(out var firstPublished) && firstPublished.Sequence == 1,
    "Reduced-bandwidth subscriber did not receive its first snapshot.");
broadcaster.Publish(new("audio.meters", 2, 1_010, [], 1));
Require(!reducedSubscription.Reader.TryRead(out _), "Reduced-bandwidth subscriber exceeded its configured rate.");
broadcaster.Publish(new("audio.meters", 3, 1_100, [], 1));
Require(reducedSubscription.Reader.TryRead(out var nextPublished) && nextPublished.Sequence == 3,
    "Reduced-bandwidth subscriber did not resume after its interval.");

using var realMeterSource = new WindowsAudioEndpointMeterSource();
var discoveredEndpoints = realMeterSource.RefreshEndpoints();
foreach (var endpoint in discoveredEndpoints)
    if (realMeterSource.TryReadPeak(endpoint.Id, out var peak))
        Require(peak is >= 0 and <= 1, "Windows endpoint returned an invalid live peak.");
var goXlrEndpointNames = discoveredEndpoints.Where(endpoint => endpoint.IsGoXlrCandidate).Select(endpoint => endpoint.DisplayName).ToArray();
if (args.Contains("--audio-diagnostics", StringComparer.Ordinal))
{
    Console.WriteLine("Active Windows audio endpoints (single non-mutating sample):");
    foreach (var endpoint in discoveredEndpoints)
    {
        var hasPeak = realMeterSource.TryReadPeak(endpoint.Id, out var peak);
        Console.WriteLine($"- {endpoint.DataFlow}: {endpoint.DisplayName}; id={endpoint.Id}; GoXLR candidate={endpoint.IsGoXlrCandidate}; suggestions={string.Join(',', endpoint.SuggestedChannelIds)}; peak={(hasPeak ? peak.ToString("F3", System.Globalization.CultureInfo.InvariantCulture) : "unavailable")}");
    }
}

Console.WriteLine($"Foundation validation passed. Pairing challenge {challenge.ChallengeId} kept its code local, authenticated once, and revoked cleanly. Capability protocol, GoXLR parsing, meter processing/mapping/sequence tests, and non-mutating Windows audio discovery passed. Discovered {discoveredEndpoints.Count} active endpoints and {goXlrEndpointNames.Length} GoXLR candidates.");

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
    public ValueTask ApplyAsync(Guid sessionId, AgentInputCommand command, CancellationToken cancellationToken = default)
    {
        Commands.Add(command);
        return ValueTask.CompletedTask;
    }
    public ValueTask ReleaseSessionAsync(Guid sessionId, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    public ValueTask ReleaseAllAsync(CancellationToken cancellationToken = default)
    {
        Commands.Add(new ReleaseAllCommand());
        return ValueTask.CompletedTask;
    }
}

sealed class FailingAudioEndpointMeterSource : IAudioEndpointMeterSource
{
    public IReadOnlyList<AudioEndpointInfo> RefreshEndpoints() =>
        throw new InvalidCastException("Simulated transient Core Audio COM activation failure.");
    public bool TryReadPeak(string endpointId, out float linearPeak) { linearPeak = 0; return false; }
    public void Dispose() { }
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

sealed class RecordingAudioEndpointMeterSource(
    IReadOnlyList<AudioEndpointInfo> endpoints,
    IReadOnlyDictionary<string, float> peaks) : IAudioEndpointMeterSource
{
    public IReadOnlyList<AudioEndpointInfo> RefreshEndpoints() => endpoints;
    public bool TryReadPeak(string endpointId, out float linearPeak) => peaks.TryGetValue(endpointId, out linearPeak);
    public void Dispose() { }
}
