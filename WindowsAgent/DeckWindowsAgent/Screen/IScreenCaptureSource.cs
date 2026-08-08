namespace DeckWindowsAgent.Screen;

public readonly record struct CapturedFrame(int Width, int Height, int Stride, byte[] Bgra);

public interface IScreenCaptureSource : IDisposable
{
    bool IsAvailable { get; }

    bool TryCaptureFrame(out CapturedFrame frame);
}
