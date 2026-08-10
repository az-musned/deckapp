namespace DeckWindowsAgent.Screen.Models;

public enum ScreenStreamMode
{
    Mirror,
    Extend
}

public sealed record ScreenFrame(
    uint Sequence,
    long TimestampMilliseconds,
    int Width,
    int Height,
    bool IsKeyframe,
    byte[] Payload);

public sealed record ScreenStreamHello(
    string Type,
    int Width,
    int Height,
    int Fps,
    string Format,
    int ProtocolVersion,
    string Mode);
