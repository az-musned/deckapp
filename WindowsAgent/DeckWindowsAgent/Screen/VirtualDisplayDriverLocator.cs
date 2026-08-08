using System.Xml.Linq;

namespace DeckWindowsAgent.Screen;

/// Best-effort detection of the monitor created by the third-party Virtual-Display-Driver
/// (https://github.com/VirtualDrivers/Virtual-Display-Driver). That driver exposes no
/// programmatic identity API, so this heuristically matches its configured resolution
/// against currently-attached non-primary monitors. Explicit ExtendMonitorDeviceName
/// configuration is the reliable fallback when this can't confidently resolve one.
public sealed class VirtualDisplayDriverLocator(ILogger<VirtualDisplayDriverLocator> logger)
{
    private const string SettingsPath = @"C:\VirtualDisplayDriver\vdd_settings.xml";

    public string? TryResolveDeviceName()
    {
        if (!File.Exists(SettingsPath))
        {
            logger.LogWarning(
                "Virtual Display Driver settings file not found at {Path}; extend mode requires Agent:ScreenStream:ExtendMonitorDeviceName to be configured explicitly.",
                SettingsPath);
            return null;
        }

        (int Width, int Height)? configuredResolution;
        try
        {
            configuredResolution = ReadConfiguredResolution(SettingsPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Xml.XmlException)
        {
            logger.LogWarning("Could not read Virtual Display Driver settings: {Message}", error.Message);
            return null;
        }

        var candidates = MonitorEnumerator.EnumerateAll().Where(monitor => !monitor.IsPrimary).ToArray();

        if (configuredResolution is { } resolution)
        {
            var match = candidates.FirstOrDefault(monitor => monitor.Width == resolution.Width && monitor.Height == resolution.Height);
            if (match.DeviceName is not null)
            {
                logger.LogInformation(
                    "Auto-detected the Virtual Display Driver monitor as {Device} by matching configured resolution {Width}x{Height}.",
                    match.DeviceName, resolution.Width, resolution.Height);
                return match.DeviceName;
            }
        }

        if (candidates.Length == 1)
        {
            logger.LogInformation(
                "Auto-detected the Virtual Display Driver monitor as {Device} (the only non-primary monitor attached). Set Agent:ScreenStream:ExtendMonitorDeviceName explicitly if this is wrong.",
                candidates[0].DeviceName);
            return candidates[0].DeviceName;
        }

        logger.LogWarning(
            "Could not confidently auto-detect the Virtual Display Driver monitor among {Count} non-primary monitors. Set Agent:ScreenStream:ExtendMonitorDeviceName explicitly.",
            candidates.Length);
        return null;
    }

    private static (int Width, int Height)? ReadConfiguredResolution(string path)
    {
        var document = XDocument.Load(path);

        foreach (var element in document.Descendants())
        {
            var widthAttribute = element.Attributes()
                .FirstOrDefault(attribute => attribute.Name.LocalName.Contains("width", StringComparison.OrdinalIgnoreCase));
            var heightAttribute = element.Attributes()
                .FirstOrDefault(attribute => attribute.Name.LocalName.Contains("height", StringComparison.OrdinalIgnoreCase));
            if (widthAttribute is not null && heightAttribute is not null
                && int.TryParse(widthAttribute.Value, out var width)
                && int.TryParse(heightAttribute.Value, out var height))
            {
                return (width, height);
            }
        }

        foreach (var element in document.Descendants())
        {
            if (!element.Name.LocalName.Contains("width", StringComparison.OrdinalIgnoreCase)
                || !int.TryParse(element.Value, out var elementWidth)) continue;

            var heightElement = element.ElementsAfterSelf()
                .FirstOrDefault(sibling => sibling.Name.LocalName.Contains("height", StringComparison.OrdinalIgnoreCase));
            if (heightElement is not null && int.TryParse(heightElement.Value, out var elementHeight))
                return (elementWidth, elementHeight);
        }

        return null;
    }
}
