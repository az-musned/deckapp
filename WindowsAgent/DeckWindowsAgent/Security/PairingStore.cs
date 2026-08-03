using System.Text.Json;

namespace DeckWindowsAgent.Security;

public sealed class PairingStore
{
    private readonly string _path;
    private readonly object _gate = new();
    private List<PairedDevice> _devices;

    public PairingStore(string path)
    {
        _path = path;
        _devices = Load(path);
    }

    public IReadOnlyList<PairedDevice> Snapshot()
    {
        lock (_gate) return _devices.ToArray();
    }

    public void Upsert(PairedDevice device)
    {
        lock (_gate)
        {
            _devices.RemoveAll(item => item.ClientDeviceId == device.ClientDeviceId);
            _devices.Add(device);
            Save();
        }
    }

    public bool Revoke(Guid id)
    {
        lock (_gate)
        {
            var removed = _devices.RemoveAll(item => item.Id == id) > 0;
            if (removed) Save();
            return removed;
        }
    }

    private void Save()
    {
        var directory = Path.GetDirectoryName(_path) ?? throw new InvalidOperationException("Pairing path has no directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = _path + ".new";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(_devices));
        File.Move(temporaryPath, _path, overwrite: true);
    }

    private static List<PairedDevice> Load(string path)
    {
        if (!File.Exists(path)) return [];
        try
        {
            return JsonSerializer.Deserialize<List<PairedDevice>>(File.ReadAllText(path)) ?? [];
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException("The pairing database is invalid; refusing to discard trust state automatically.", error);
        }
    }
}
