namespace DeckWindowsAgent.Audio;

public sealed class AudioMeterSequence
{
    private long _value;
    public ulong Next() => unchecked((ulong)Interlocked.Increment(ref _value));
}
