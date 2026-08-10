namespace DeckWindowsAgent.Input;

public interface IWindowsInputSink
{
    bool IsAvailable { get; }
    ValueTask ApplyAsync(Guid sessionId, AgentInputCommand command, CancellationToken cancellationToken = default);
    ValueTask ReleaseSessionAsync(Guid sessionId, CancellationToken cancellationToken = default);
    ValueTask ReleaseAllAsync(CancellationToken cancellationToken = default);
}

public abstract record AgentInputCommand;
public sealed record RelativePointerCommand(double DeltaX, double DeltaY, bool Acceleration, bool Precision) : AgentInputCommand;
public sealed record ScrollCommand(double DeltaX, double DeltaY) : AgentInputCommand;
public sealed record MouseButtonCommand(string Button, bool IsDown) : AgentInputCommand;
public sealed record VirtualKeyCommand(string Key, bool IsDown, int Modifiers) : AgentInputCommand;
public sealed record ModifierCommand(int Modifiers, bool IsDown) : AgentInputCommand;
public sealed record UnicodeTextCommand(string Text) : AgentInputCommand;
public sealed record ClipboardTextCommand(string Text, bool PasteAfterCopy) : AgentInputCommand;
public sealed record ReleaseAllCommand : AgentInputCommand;

/// <summary>A one-shot press+release of a user-configured hotkey (e.g. a Vencord plugin trigger), distinct from
/// <see cref="VirtualKeyCommand"/>'s named-key allowlist so phone-configured chords can target ordinary letter/digit keys.</summary>
public sealed record KeyChordCommand(ushort KeyCode, int Modifiers) : AgentInputCommand;

public sealed class InputInjectionException : Exception
{
    public InputInjectionException(string message) : base(message) { }
}

/// <summary>Windows virtual-key codes remote hotkey chords are allowed to target. Kept narrow so a paired phone
/// can only replay ordinary printable/function keys, never OS-sensitive keys (Escape, Tab, Windows, etc.).</summary>
public static class HotkeyKeyAllowList
{
    public static bool IsAllowed(int virtualKeyCode) => virtualKeyCode is
        (>= 0x41 and <= 0x5A)  // A-Z
        or (>= 0x30 and <= 0x39)  // 0-9
        or (>= 0x70 and <= 0x87)  // F1-F24
        or 0x20  // Space
        or 0xBC or 0xBE or 0xBD or 0xBB  // , . - =
        or 0xBA or 0xDE or 0xDB or 0xDD or 0xDC or 0xBF; // ; ' [ ] \ /
}
