using DeckWindowsAgent.Audio.Models;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Audio;

public sealed class AudioMeterService(
    AgentOptions options,
    IAudioEndpointMeterSource source,
    AudioChannelMappingStore mappings,
    AudioMeterBroadcaster broadcaster,
    AudioMeterSequence sequence,
    ILogger<AudioMeterService> logger) : BackgroundService
{
    private readonly object _stateGate = new();
    private readonly Dictionary<string, AudioMeterProcessor> _processors = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string?> _processedEndpointIds = new(StringComparer.Ordinal);
    private IReadOnlyList<AudioEndpointInfo> _endpoints = [];
    private AudioMeterSnapshot _current = new("audio.meters", 0, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), [], PairingService.ProtocolVersion);
    private DateTimeOffset _nextEndpointRefresh = DateTimeOffset.MinValue;
    private DateTimeOffset _nextDiagnosticLog = DateTimeOffset.MinValue;

    public AudioMeterSnapshot CurrentSnapshot { get { lock (_stateGate) return _current; } }
    public IReadOnlyList<AudioEndpointInfo> Endpoints { get { lock (_stateGate) return _endpoints.ToArray(); } }
    public IReadOnlyList<AudioChannelMappingInfo> Channels => mappings.Snapshot(Endpoints);

    public bool TrySetMapping(string channelId, string? endpointId, out string error)
    {
        if (!mappings.ContainsChannel(channelId))
        {
            error = "Unknown logical audio channel.";
            return false;
        }
        if (endpointId is not null && !Endpoints.Any(endpoint => endpoint.Id == endpointId))
        {
            error = "The selected Windows audio endpoint is not currently active.";
            return false;
        }
        mappings.SetMapping(channelId, endpointId);
        error = string.Empty;
        return true;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.AudioMeters.Enabled)
        {
            logger.LogInformation("Audio metering is disabled by local configuration.");
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            var now = DateTimeOffset.UtcNow;
            if (now >= _nextEndpointRefresh)
            {
                RefreshEndpoints();
                _nextEndpointRefresh = now.AddSeconds(5);
            }

            var snapshot = Sample(now.ToUnixTimeMilliseconds());
            lock (_stateGate) _current = snapshot;
            if (broadcaster.SubscriberCount > 0) broadcaster.Publish(snapshot);
            WriteDiagnosticLogIfEnabled(now);

            var delay = broadcaster.SubscriberCount == 0
                ? TimeSpan.FromMilliseconds(500)
                : TimeSpan.FromSeconds(1d / (broadcaster.HasLocalSubscribers
                    ? options.AudioMeters.LocalUpdatesPerSecond
                    : options.AudioMeters.ReducedUpdatesPerSecond));
            await Task.Delay(delay, stoppingToken);
        }
    }

    internal void RefreshEndpoints()
    {
        try
        {
            var endpoints = source.RefreshEndpoints();
            lock (_stateGate) _endpoints = endpoints;
        }
        catch (Exception error) when (IsRecoverableAudioFailure(error))
        {
            logger.LogWarning("Windows audio endpoint discovery is temporarily unavailable; the Agent will retry: {Message}", error.Message);
        }
    }

    private static bool IsRecoverableAudioFailure(Exception error) => error is
        InvalidCastException or
        InvalidOperationException or
        ObjectDisposedException or
        System.Runtime.InteropServices.COMException;

    internal AudioMeterSnapshot Sample(long timestampMilliseconds)
    {
        var endpoints = Endpoints;
        var channels = mappings.Snapshot(endpoints);
        var states = new AudioMeterChannelState[channels.Count];
        for (var index = 0; index < channels.Count; index++)
        {
            var channel = channels[index];
            var linearPeak = 0f;
            var available = channel.EndpointId is not null && source.TryReadPeak(channel.EndpointId, out linearPeak);
            if (!available) linearPeak = 0;
            var processor = ProcessorFor(channel.Id, available ? channel.EndpointId : null);
            var processed = processor.Process(linearPeak, timestampMilliseconds);
            states[index] = new AudioMeterChannelState(
                channel.Id,
                channel.DisplayName,
                channel.EndpointId,
                available,
                processed.LinearPeak,
                processed.Decibels,
                processed.DisplayLevel,
                processed.PeakHold,
                processed.IsClipping);
        }
        return new AudioMeterSnapshot(
            "audio.meters",
            sequence.Next(),
            timestampMilliseconds,
            states,
            PairingService.ProtocolVersion);
    }

    private AudioMeterProcessor ProcessorFor(string channelId, string? endpointId)
    {
        if (!_processors.TryGetValue(channelId, out var processor))
        {
            processor = new AudioMeterProcessor();
            _processors[channelId] = processor;
        }
        if (!_processedEndpointIds.TryGetValue(channelId, out var previous) || previous != endpointId)
        {
            processor.Reset();
            _processedEndpointIds[channelId] = endpointId;
        }
        return processor;
    }

    private void WriteDiagnosticLogIfEnabled(DateTimeOffset now)
    {
        if (!options.AudioMeters.DiagnosticLoggingEnabled || now < _nextDiagnosticLog) return;
        _nextDiagnosticLog = now.AddSeconds(options.AudioMeters.DiagnosticLogIntervalSeconds);
        var snapshot = CurrentSnapshot;
        var endpointSummary = string.Join(", ", Endpoints.Select(endpoint => $"{endpoint.DisplayName} [{endpoint.DataFlow}]"));
        var peakSummary = string.Join(", ", snapshot.Channels.Select(channel => $"{channel.Id}={channel.LinearPeak:F3}"));
        logger.LogInformation("Audio meter diagnostic endpoints: {Endpoints}; current peaks: {Peaks}", endpointSummary, peakSummary);
    }
}
