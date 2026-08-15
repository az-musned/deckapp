namespace DeckWindowsAgent.Screen;

public readonly record struct MonitorDescriptor(string DeviceName, bool IsPrimary, int Left, int Top, int Width, int Height);
