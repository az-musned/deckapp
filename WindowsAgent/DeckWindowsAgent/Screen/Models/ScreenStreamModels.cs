namespace DeckWindowsAgent.Screen.Models;

public sealed record ScreenFrame(
    uint Sequence,
    long TimestampMilliseconds,
    int Width,
    int Height,
    byte[] JpegBytes);

public sealed record ScreenStreamHello(
    string Type,
    int Width,
    int Height,
    int Fps,
    string Format,
    int ProtocolVersion);
