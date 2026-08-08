using System.Text.Json;
using DeckWindowsAgent.Audio.Models;
using DeckWindowsAgent.Configuration;

namespace DeckWindowsAgent.Audio;

public sealed class AudioChannelMappingStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string _path;
    private readonly object _gate = new();
    private readonly IReadOnlyList<AudioMeterChannelOptions> _channels;
    private Dictionary<string, string?> _mappings;
    private long _version;

    public AudioChannelMappingStore(string path, AgentOptions options)
    {
        _path = path;
        _channels = options.AudioMeters.Channels.ToArray();
        _mappings = _channels.ToDictionary(channel => channel.Id, channel => channel.EndpointId, StringComparer.Ordinal);
        foreach (var pair in Load(path))
            if (_mappings.ContainsKey(pair.Key)) _mappings[pair.Key] = pair.Value;
    }

    public long Version => Interlocked.Read(ref _version);

    public IReadOnlyList<AudioChannelMappingInfo> Snapshot(IReadOnlyCollection<AudioEndpointInfo> endpoints)
    {
        var availableIds = endpoints.Select(endpoint => endpoint.Id).ToHashSet(StringComparer.Ordinal);
        lock (_gate)
        {
            return _channels.Select(channel =>
            {
                var endpointId = _mappings[channel.Id];
                return new AudioChannelMappingInfo(
                    channel.Id,
                    channel.DisplayName,
                    endpointId,
                    endpointId is not null && availableIds.Contains(endpointId));
            }).ToArray();
        }
    }

    public bool ContainsChannel(string channelId) => _channels.Any(channel => channel.Id == channelId);

    public void SetMapping(string channelId, string? endpointId)
    {
        lock (_gate)
        {
            if (!_mappings.ContainsKey(channelId)) throw new KeyNotFoundException("Unknown logical audio channel.");
            _mappings[channelId] = endpointId;
            Save();
            Interlocked.Increment(ref _version);
        }
    }

    private void Save()
    {
        var directory = Path.GetDirectoryName(_path) ?? throw new InvalidOperationException("Audio mapping path has no directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = _path + ".new";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(_mappings, JsonOptions));
        File.Move(temporaryPath, _path, overwrite: true);
    }

    private static Dictionary<string, string?> Load(string path)
    {
        if (!File.Exists(path)) return new(StringComparer.Ordinal);
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string?>>(File.ReadAllText(path), JsonOptions)
                ?? new(StringComparer.Ordinal);
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException("The audio channel mapping database is invalid; refusing to discard it automatically.", error);
        }
    }
}
