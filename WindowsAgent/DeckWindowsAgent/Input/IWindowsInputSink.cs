namespace DeckWindowsAgent.Input;

public interface IWindowsInputSink
{
    bool IsAvailable { get; }
    ValueTask ApplyAsync(AgentInputCommand command, CancellationToken cancellationToken = default);
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

public sealed class InputInjectionException : Exception
{
    public InputInjectionException(string message) : base(message) { }
}
