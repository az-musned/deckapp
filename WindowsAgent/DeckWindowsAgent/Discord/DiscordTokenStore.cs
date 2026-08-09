using System.Text.Json;

namespace DeckWindowsAgent.Discord;

/// <summary>Persists the Discord OAuth2 refresh token so the agent doesn't need to re-prompt the native
/// Discord authorization dialog on every restart. Mirrors <c>PairingStore</c>'s atomic-write pattern.</summary>
public sealed class DiscordTokenStore
{
    private readonly string _path;
    private readonly object _gate = new();

    public DiscordTokenStore(string path)
    {
        _path = path;
    }

    public DiscordStoredToken? Load()
    {
        lock (_gate)
        {
            if (!File.Exists(_path)) return null;
            try { return JsonSerializer.Deserialize<DiscordStoredToken>(File.ReadAllText(_path)); }
            catch (JsonException) { return null; }
        }
    }

    public void Save(DiscordStoredToken token)
    {
        lock (_gate)
        {
            var directory = Path.GetDirectoryName(_path) ?? throw new InvalidOperationException("The Discord token path has no directory.");
            Directory.CreateDirectory(directory);
            var temporaryPath = _path + ".new";
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(token));
            File.Move(temporaryPath, _path, overwrite: true);
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            if (File.Exists(_path)) File.Delete(_path);
        }
    }
}
