using System.Text.Json;
using DeckWindowsAgent.Input;

namespace DeckWindowsAgent.Protocol;

public sealed record InputBatchRequest(int ProtocolVersion, List<InputEventEnvelope> Events);
public sealed record InputEventEnvelope(Guid Id, ulong Sequence, long TimestampMilliseconds, JsonElement Payload);
public sealed record InputBatchResult(ulong LastAcceptedSequence, int AppliedCount, int DroppedCount, string Status, long ServerTimestampMilliseconds);
public sealed record InputSessionHello(Guid SessionId, int ProtocolVersion, string Status, long ServerTimestampMilliseconds);
public sealed record InputProtocolError(string Status, string Message);

public static class InputPayloadParser
{
    public static AgentInputCommand Parse(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object) throw new JsonException("Payload must be an object.");
        using var enumerator = payload.EnumerateObject();
        if (!enumerator.MoveNext()) throw new JsonException("Payload has no command.");
        var property = enumerator.Current;
        if (enumerator.MoveNext()) throw new JsonException("Payload must contain exactly one command.");
        var value = property.Value;

        return property.Name switch
        {
            "relativePointer" => new RelativePointerCommand(
                Number(value, "deltaX"), Number(value, "deltaY"), Boolean(value, "acceleration"), Boolean(value, "precision")),
            "scroll" => new ScrollCommand(Number(value, "deltaX"), Number(value, "deltaY")),
            "mouseButton" => new MouseButtonCommand(String(value, "_0"), Boolean(value, "isDown")),
            "virtualKey" => new VirtualKeyCommand(String(value, "_0"), Boolean(value, "isDown"), Modifiers(value, "modifiers")),
            "modifier" => new ModifierCommand(Modifiers(value, "_0"), Boolean(value, "isDown")),
            "unicodeText" => new UnicodeTextCommand(String(value, "_0", 4_096)),
            "clipboardText" => new ClipboardTextCommand(String(value, "_0", 8_192), Boolean(value, "pasteAfterCopy")),
            "releaseAll" => new ReleaseAllCommand(),
            "keyChord" => new KeyChordCommand((ushort)UInt16Range(value, "keyCode"), Modifiers(value, "modifiers")),
            _ => throw new JsonException("Unknown input command.")
        };
    }

    public static bool IsReleasePriority(AgentInputCommand command) => command switch
    {
        MouseButtonCommand { IsDown: false } => true,
        VirtualKeyCommand { IsDown: false } => true,
        ModifierCommand { IsDown: false } => true,
        ReleaseAllCommand => true,
        _ => false
    };

    private static int UInt16Range(JsonElement value, string name)
    {
        var number = value.GetProperty(name).GetInt32();
        if (number is < 0 or > 65_535) throw new JsonException($"{name} is outside its allowed range.");
        return number;
    }
    private static double Number(JsonElement value, string name)
    {
        var number = value.GetProperty(name).GetDouble();
        if (!double.IsFinite(number) || Math.Abs(number) > 10_000) throw new JsonException($"{name} is outside its allowed range.");
        return number;
    }
    private static int Modifiers(JsonElement value, string name)
    {
        var modifiers = value.GetProperty(name).GetInt32();
        if (modifiers is < 0 or > 15) throw new JsonException("Modifier mask is invalid.");
        return modifiers;
    }
    private static bool Boolean(JsonElement value, string name) => value.GetProperty(name).GetBoolean();
    private static string String(JsonElement value, string name, int maximumLength = 80)
    {
        var text = value.GetProperty(name).GetString() ?? throw new JsonException($"{name} is required.");
        if (text.Length > maximumLength) throw new JsonException($"{name} is too long.");
        return text;
    }
}
