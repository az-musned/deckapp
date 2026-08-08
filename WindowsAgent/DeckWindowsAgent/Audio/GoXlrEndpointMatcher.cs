using DeckWindowsAgent.Audio.Models;

namespace DeckWindowsAgent.Audio;

public static class GoXlrEndpointMatcher
{
    private static readonly (string Channel, string[] Tokens)[] ChannelTokens =
    [
        ("mic", ["mic", "microphone"]),
        ("chat", ["chat"]),
        ("music", ["music"]),
        ("game", ["game"]),
        ("system", ["system"]),
        ("sample", ["sample", "samples", "sampler"]),
        ("lineIn", ["linein", "line input"])
    ];

    public static AudioEndpointInfo Describe(string id, string displayName, string dataFlow)
    {
        var normalized = Normalize(displayName);
        var isCandidate = normalized.Contains("goxlr", StringComparison.Ordinal)
            || normalized.Contains("tc helicon", StringComparison.Ordinal)
            || normalized.Contains("broadcast stream mix", StringComparison.Ordinal);
        var suggestions = isCandidate
            ? ChannelTokens.Where(item => item.Tokens.Any(normalized.Contains)).Select(item => item.Channel).Distinct().ToArray()
            : [];
        return new AudioEndpointInfo(id, displayName, dataFlow, isCandidate, suggestions);
    }

    private static string Normalize(string value)
    {
        var characters = value.ToLowerInvariant().Select(character => char.IsLetterOrDigit(character) ? character : ' ').ToArray();
        return string.Join(' ', new string(characters).Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }
}
