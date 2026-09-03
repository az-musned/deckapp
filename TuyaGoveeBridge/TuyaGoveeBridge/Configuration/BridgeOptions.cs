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
            if (button.Targets.Count == 0 && button.TuyaLightTargets.Count == 0)
                throw new InvalidOperationException($"Tuya button '{button.DeviceId}' needs at least one Govee or Tuya light target.");
            foreach (var target in button.Targets)
            {
                if (string.IsNullOrWhiteSpace(target.GoveeSku) || string.IsNullOrWhiteSpace(target.GoveeDevice))
                    throw new InvalidOperationException($"Tuya button '{button.DeviceId}' has a target missing a Govee Sku/Device.");
            }
            foreach (var target in button.TuyaLightTargets)
            {
                if (string.IsNullOrWhiteSpace(target.DeviceId))
                    throw new InvalidOperationException($"Tuya button '{button.DeviceId}' has a Tuya light target missing a DeviceId.");
                if (string.IsNullOrWhiteSpace(target.PowerCode))
                    throw new InvalidOperationException($"Tuya button '{button.DeviceId}' Tuya light target '{target.DeviceId}' needs a PowerCode.");
            }
            if (button.ClickActions.Count == 0)
                throw new InvalidOperationException($"Tuya button '{button.DeviceId}' needs at least one entry in ClickActions.");
            foreach (var action in button.ClickActions.Values)
            {
                if (action is not ("turnOn" or "turnOff" or "toggle" or "toggleBrightness"))
                    throw new InvalidOperationException(
                        $"Tuya button '{button.DeviceId}' has an unrecognized action '{action}' -- must be turnOn, turnOff, toggle, or toggleBrightness.");
            }
        }
    }
}

public sealed class ButtonMapping
{
    public string DeviceId { get; init; } = string.Empty;
    /// One or more Govee lights this button controls together -- an action moves all of them
    /// the same way at once (see GoveeClient.ApplyAsync/ApplyBrightnessToggleAsync), rather than
    /// each reacting independently, so repeated presses can't drift them out of sync with
    /// each other.
    public List<GoveeTarget> Targets { get; init; } = [];
    /// Tuya-native lights this button controls together, alongside (or instead of) the Govee
    /// Targets above -- a different cloud/API than Govee's, controlled via
    /// TuyaLightClient.ApplyAsync using the same Bridge:AccessId/AccessSecret/DataCenter as the
    /// button subscription itself. Only turnOn/turnOff/toggle apply here (not
    /// toggleBrightness -- these lights' brightness DP and scale vary per device/category and
    /// aren't wired up yet).
    public List<TuyaLightTarget> TuyaLightTargets { get; init; } = [];
    /// Maps the button's click type (the value of its "switch_type_1" data point) to what to
    /// do: turnOn, turnOff, toggle, or toggleBrightness (flips the Govee Targets between 1% and
    /// 100% brightness together; TuyaLightTargets are unaffected by toggleBrightness). A click
    /// type with no entry here is ignored. "single_click", "double_click", and "long_press" are
    /// all confirmed live from this button model (matches Tuya's documented range for DP
    /// switch_mode1/switch_type_1 on category "wxkg" scene switches: click/double_click/press).
    public Dictionary<string, string> ClickActions { get; init; } = new(StringComparer.OrdinalIgnoreCase)
    {
        ["single_click"] = "toggle"
    };
}

public sealed class GoveeTarget
{
    public string GoveeSku { get; init; } = string.Empty;
    public string GoveeDevice { get; init; } = string.Empty;
}

public sealed class TuyaLightTarget
{
    public string DeviceId { get; init; } = string.Empty;
    /// The device's on/off data-point code, e.g. "switch_led" or "switch_1" -- varies by device
    /// category; check the device's specification (GET /v1.0/devices/{id}/specifications) if
    /// unsure.
    public string PowerCode { get; init; } = string.Empty;
}
