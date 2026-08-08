namespace DeckWindowsAgent.Screen;

public interface IScreenCaptureSourceFactory
{
    IScreenCaptureSource Create(string? deviceName);
}

public sealed class WindowsGraphicsCaptureSourceFactory(ILoggerFactory loggerFactory) : IScreenCaptureSourceFactory
{
    public IScreenCaptureSource Create(string? deviceName) =>
        new WindowsGraphicsCaptureSource(deviceName, loggerFactory.CreateLogger<WindowsGraphicsCaptureSource>());
}
