using System.Diagnostics;
using System.Text.Json;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Protocol;

namespace DeckWindowsAgent.Capabilities;

public interface IGoXlrCapabilityService
{
    Task<(bool Connected, IReadOnlyList<AgentGoXlrChannelState> Channels)> SnapshotAsync(CancellationToken cancellationToken);
    Task<bool> SetLevelAsync(string id, double level, CancellationToken cancellationToken);
    Task<bool> SetMutedAsync(string id, bool muted, CancellationToken cancellationToken);
}

public sealed class GoXlrCapabilityService(AgentOptions options) : IGoXlrCapabilityService
{
    private readonly bool _enabled = options.Capabilities.GoXlrEnabled;
    private readonly string? _clientPath = ResolveClientPath(options.Capabilities.GoXlrClientPath);

    public async Task<(bool Connected, IReadOnlyList<AgentGoXlrChannelState> Channels)> SnapshotAsync(CancellationToken cancellationToken)
    {
        if (!_enabled || _clientPath is null) return (false, []);
        var result = await RunAsync(["--status-json"], cancellationToken);
        if (!result.Success) return (false, []);
        try { return (true, ParseChannels(result.Output)); }
        catch (JsonException) { return (false, []); }
        catch (InvalidOperationException) { return (false, []); }
    }

    public async Task<bool> SetLevelAsync(string id, double level, CancellationToken cancellationToken)
    {
        if (!_enabled || _clientPath is null || !double.IsFinite(level) || level is < 0 or > 1) return false;
        var channel = NormalizeChannel(id);
        var percent = (int)Math.Round(level * 100, MidpointRounding.AwayFromZero);
        var command = await RunAsync(["volume", channel, percent.ToString(System.Globalization.CultureInfo.InvariantCulture)], cancellationToken);
        if (!command.Success) return false;
        var snapshot = await SnapshotAsync(cancellationToken);
        return snapshot.Channels.Any(item => item.Id == channel && Math.Abs(item.Level - percent / 100d) <= 0.011);
    }

    public async Task<bool> SetMutedAsync(string id, bool muted, CancellationToken cancellationToken)
    {
        if (!_enabled || _clientPath is null) return false;
        var channel = NormalizeChannel(id);
        var status = await RunAsync(["--status-json"], cancellationToken);
        if (!status.Success) return false;
        var fader = FindFader(status.Output, channel)
            ?? throw new CapabilityUnavailableException("The GoXLR channel is not assigned to a physical fader, so its mute state cannot be controlled safely.");
        var command = await RunAsync(["faders", "mute-state", fader, muted ? "muted-to-all" : "unmuted"], cancellationToken);
        if (!command.Success) return false;
        var snapshot = await SnapshotAsync(cancellationToken);
        return snapshot.Channels.Any(item => item.Id == channel && item.IsMuted == muted);
    }

    internal static IReadOnlyList<AgentGoXlrChannelState> ParseChannels(string json)
    {
        using var document = JsonDocument.Parse(json);
        var mixer = FirstMixer(document.RootElement);
        var volumes = mixer.GetProperty("levels").GetProperty("volumes");
        var muteStates = FaderMuteStates(mixer);
        return volumes.EnumerateObject()
            .Select(volume =>
            {
                var id = NormalizeChannel(volume.Name);
                var level = volume.Value.GetDouble() / 100d;
                return new AgentGoXlrChannelState(id, DisplayChannel(volume.Name), Math.Clamp(level, 0, 1), muteStates.TryGetValue(id, out var muted) && muted);
            })
            .OrderBy(channel => channel.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string? FindFader(string json, string channel)
    {
        using var document = JsonDocument.Parse(json);
        var mixer = FirstMixer(document.RootElement);
        foreach (var fader in mixer.GetProperty("fader_status").EnumerateObject())
            if (NormalizeChannel(fader.Value.GetProperty("channel").GetString() ?? string.Empty) == channel)
                return fader.Name.ToLowerInvariant();
        return null;
    }

    private static Dictionary<string, bool> FaderMuteStates(JsonElement mixer)
    {
        var result = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var fader in mixer.GetProperty("fader_status").EnumerateObject())
        {
            var channel = NormalizeChannel(fader.Value.GetProperty("channel").GetString() ?? string.Empty);
            var state = fader.Value.GetProperty("mute_state").GetString();
            result[channel] = !string.Equals(state, "Unmuted", StringComparison.OrdinalIgnoreCase);
        }
        return result;
    }

    private static JsonElement FirstMixer(JsonElement root)
    {
        var mixers = root.GetProperty("mixers");
        using var enumerator = mixers.EnumerateObject();
        if (!enumerator.MoveNext()) throw new InvalidOperationException("No GoXLR mixer is connected.");
        return enumerator.Current.Value;
    }

    private async Task<(bool Success, string Output)> RunAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo
        {
            FileName = _clientPath!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start);
        if (process is null) return (false, string.Empty);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(3));
        try
        {
            var outputTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
            var errorTask = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            var output = await outputTask;
            _ = await errorTask;
            return process.ExitCode == 0 && output.Length <= 1024 * 1024 ? (true, output) : (false, string.Empty);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            return (false, string.Empty);
        }
    }

    private static string? ResolveClientPath(string configured)
    {
        var candidates = string.IsNullOrWhiteSpace(configured)
            ? new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "GoXLR Utility", "goxlr-client.exe") }
            : new[] { Path.GetFullPath(configured) };
        return candidates.FirstOrDefault(File.Exists);
    }

    private static string NormalizeChannel(string value)
    {
        var normalized = new string(value.Where(char.IsAsciiLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
        var allowed = new[] { "mic", "linein", "console", "system", "game", "chat", "sample", "music", "headphones", "micmonitor", "lineout" };
        if (!allowed.Contains(normalized, StringComparer.Ordinal)) throw new CapabilityUnavailableException("Unknown GoXLR channel.");
        return normalized;
    }

    private static string DisplayChannel(string value) => NormalizeChannel(value) switch
    {
        "linein" => "Line In", "micmonitor" => "Mic Monitor", "lineout" => "Line Out",
        var id => char.ToUpperInvariant(id[0]) + id[1..]
    };
}
