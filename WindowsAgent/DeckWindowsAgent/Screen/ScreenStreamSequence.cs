namespace DeckWindowsAgent.Screen;

public sealed class ScreenStreamSequence
{
    private long _value;
    public uint Next() => unchecked((uint)Interlocked.Increment(ref _value));
}
