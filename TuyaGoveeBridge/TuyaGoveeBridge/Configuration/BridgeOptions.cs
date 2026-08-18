namespace TuyaGoveeBridge.Configuration;

/// Everything the bridge needs: which Tuya cloud project/region to authenticate against, and
/// which button device IDs map to which Govee light + action. Ported unchanged from
/// DeckWindowsAgent.Configuration.TuyaButtonAutomationOptions -- this used to live on the
/// Windows Agent, but a physical button needs to work even when the gaming PC it was hosted
/// on is off, so it moved to its own always-on host.
public sealed class BridgeOptions
{
    public string AccessId { get; init; } = string.Empty;
    public string AccessSecret { get; init; } = string.Empty;
    public string DataCenter { get; init; } = "centralEurope";
    public string GoveeApiKey { get; init; } = string.Empty;
    public List<ButtonMapping> Buttons { get; init; } = [];

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(AccessId) && !string.IsNullOrWhiteSpace(AccessSecret)
        && !string.IsNullOrWhiteSpace(GoveeApiKey) && Buttons.Count > 0;

    public void Validate()
    {
        if (!IsConfigured) return;

        if (!TuyaGoveeBridge.Tuya.TuyaDataCenterExtensions.TryParse(DataCenter, out _))
            throw new InvalidOperationException($"Bridge:DataCenter '{DataCenter}' is not a recognized Tuya data center.");

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var button in Buttons)
        {
            if (string.IsNullOrWhiteSpace(button.DeviceId))
                throw new InvalidOperationException("Bridge:Buttons entries need a DeviceId.");
            if (!ids.Add(button.DeviceId))
                throw new InvalidOperationException($"Duplicate Tuya button DeviceId '{button.DeviceId}'.");
            if (string.IsNullOrWhiteSpace(button.GoveeSku) || string.IsNullOrWhiteSpace(button.GoveeDevice))
                throw new InvalidOperationException($"Tuya button '{button.DeviceId}' needs a Govee Sku and Device.");
            if (button.Action is not ("turnOn" or "turnOff" or "toggle"))
                throw new InvalidOperationException($"Tuya button '{button.DeviceId}' Action must be turnOn, turnOff, or toggle.");
        }
    }
}

public sealed class ButtonMapping
{
    public string DeviceId { get; init; } = string.Empty;
    public string GoveeSku { get; init; } = string.Empty;
    public string GoveeDevice { get; init; } = string.Empty;
    /// turnOn, turnOff, or toggle. Defaults to toggle since a single scene-switch button is
    /// often used as a plain on/off flip; set explicitly per button if each of your two buttons
    /// is dedicated to one direction instead.
    public string Action { get; init; } = "toggle";
}
