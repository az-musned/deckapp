using System.Net.Http.Json;
using System.Text.Json;

namespace TuyaGoveeBridge.Govee;

/// Minimal Govee cloud client, mirroring the shape (and exact request bodies) of the iOS app's
/// GoveeClient.swift -- just enough to turn lights on/off and set brightness from the bridge,
/// for the Tuya button automation. Not a full port: no device discovery or state polling beyond
/// what these actions need.
public sealed class GoveeClient(IHttpClientFactory httpClientFactory, ILogger<GoveeClient> logger)
{
    private static readonly Uri BaseUri = new("https://openapi.api.govee.com");

    // Bounds every outgoing request so one slow/hung call to Govee can't stall the bridge's
    // single-threaded button-press loop for the .NET default HttpClient timeout (100s) --
    // observed in practice: a status read for one light hung long enough that every other
    // button press appeared completely unresponsive until it finally gave up.
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);

    public Task TurnOnAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        SetOnOffAsync(sku, device, apiKey, powerOn: true, cancellationToken);

    public Task TurnOffAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        SetOnOffAsync(sku, device, apiKey, powerOn: false, cancellationToken);

    /// Govee's control endpoint is set-only (no toggle), so a toggle first reads current state.
    /// If the state read fails, defaults to turning on -- a light that's already on staying on
    /// is a much smaller surprise than a "toggle" that silently does nothing.
    public async Task ToggleAsync(string sku, string device, string apiKey, CancellationToken cancellationToken)
    {
        var isOn = await TryGetPowerStateAsync(sku, device, apiKey, cancellationToken);
        await SetOnOffAsync(sku, device, apiKey, powerOn: !(isOn ?? false), cancellationToken);
    }

    /// Applies one on/off action to several lights as a single group (e.g. one button
    /// controlling multiple bulbs). For "toggle", the direction is decided once from the first
    /// target's current state and then applied identically to every target -- each light
    /// toggling independently would let repeated presses drift them out of sync with each
    /// other, since they'd diverge the moment any one of them was already in a different state
    /// than the rest. A failure on one target (including a timeout) is logged and skipped
    /// rather than aborting the remaining targets.
    ///
    /// This only decides direction from Govee lights -- when a button also has non-Govee
    /// targets (e.g. a Tuya-native light), call GetPowerStateAsync once against a single shared
    /// reference light and pass the resolved "turnOn"/"turnOff" to every provider's Apply call
    /// instead of "toggle", so they can't independently read different states and disagree on
    /// which direction to go.
    public async Task ApplyAsync(string action, IReadOnlyList<(string Sku, string Device)> targets, string apiKey, CancellationToken cancellationToken)
    {
        if (targets.Count == 0) return;

        var powerOn = action switch
        {
            "turnOn" => true,
            "turnOff" => false,
            _ => !(await TryGetPowerStateAsync(targets[0].Sku, targets[0].Device, apiKey, cancellationToken) ?? false)
        };

        foreach (var target in targets)
            await SetOnOffAsync(target.Sku, target.Device, apiKey, powerOn, cancellationToken);
    }

    /// Reads a light's current on/off state -- exposed so callers coordinating several
    /// providers (Govee + Tuya-native) can decide one shared toggle direction from a single
    /// reference light rather than letting each provider decide independently.
    public Task<bool?> GetPowerStateAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        TryGetPowerStateAsync(sku, device, apiKey, cancellationToken);

    /// Flips every target between 1% and 100% brightness together (e.g. a button's long press),
    /// using the same "decide once from the first target, apply to all" approach as ApplyAsync
    /// so the lights can't drift out of sync with each other across repeated presses. A light
    /// that's off stays off -- setting brightness doesn't turn a light on, matching how the
    /// physical dimmer on most lights behaves.
    ///
    /// This only decides direction from Govee lights -- when a button also has non-Govee
    /// brightness targets, use GetBrightnessPercentAsync/ApplyBrightnessDirectionAsync instead
    /// so the direction can be resolved once and shared with the other provider (mirrors
    /// ApplyAsync's "toggle" split for the same reason).
    public async Task ApplyBrightnessToggleAsync(
        IReadOnlyList<(string Sku, string Device)> targets, string apiKey, CancellationToken cancellationToken,
        int lowPercent = 1, int highPercent = 100, int midpoint = 50)
    {
        if (targets.Count == 0) return;

        var current = await TryGetBrightnessAsync(targets[0].Sku, targets[0].Device, apiKey, cancellationToken);
        var dim = (current ?? 0) >= midpoint;
        await ApplyBrightnessDirectionAsync(dim, targets, apiKey, cancellationToken, lowPercent, highPercent);
    }

    /// Reads a light's current brightness (0-100%) -- exposed for the same cross-provider
    /// direction-resolution reason as GetPowerStateAsync.
    public Task<int?> GetBrightnessPercentAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        TryGetBrightnessAsync(sku, device, apiKey, cancellationToken);

    /// Sets every target to lowPercent (if dim) or highPercent (if not), with no state read of
    /// its own -- the direction must already be decided by the caller. A light that's off stays
    /// off, same as ApplyBrightnessToggleAsync.
    public async Task ApplyBrightnessDirectionAsync(
        bool dim, IReadOnlyList<(string Sku, string Device)> targets, string apiKey, CancellationToken cancellationToken,
        int lowPercent = 1, int highPercent = 100)
    {
        var target = dim ? lowPercent : highPercent;
        foreach (var device in targets)
            await SetBrightnessAsync(device.Sku, device.Device, apiKey, target, cancellationToken);
    }

    private Task SetOnOffAsync(string sku, string device, string apiKey, bool powerOn, CancellationToken cancellationToken) =>
        ControlAsync(sku, device, apiKey, "devices.capabilities.on_off", "powerSwitch", powerOn ? 1 : 0, cancellationToken);

    private Task SetBrightnessAsync(string sku, string device, string apiKey, int percent, CancellationToken cancellationToken) =>
        ControlAsync(sku, device, apiKey, "devices.capabilities.range", "brightness", percent, cancellationToken);

    private async Task ControlAsync(string sku, string device, string apiKey, string type, string instance, int value, CancellationToken cancellationToken)
    {
        try
        {
            using var client = httpClientFactory.CreateClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseUri, "router/api/v1/device/control"));
            request.Headers.Add("Govee-API-Key", apiKey);
            request.Content = JsonContent.Create(new
            {
                requestId = Guid.NewGuid().ToString(),
                payload = new { sku, device, capability = new { type, instance, value } }
            });

            using var response = await SendWithTimeoutAsync(client, request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken);
                logger.LogWarning("Govee control request for {Device} ({Instance}) failed ({Status}): {Body}", device, instance, response.StatusCode, body);
            }
        }
        catch (Exception error)
        {
            logger.LogWarning(error, "Govee control request for {Device} ({Instance}) failed.", device, instance);
        }
    }

    private Task<bool?> TryGetPowerStateAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        TryGetCapabilityValueAsync<bool>(sku, device, apiKey, "powerSwitch", value => value.ValueKind == JsonValueKind.Number && value.GetInt32() != 0, cancellationToken);

    private Task<int?> TryGetBrightnessAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        TryGetCapabilityValueAsync<int>(sku, device, apiKey, "brightness", value => value.ValueKind == JsonValueKind.Number ? value.GetInt32() : (int?)null, cancellationToken);

    private async Task<T?> TryGetCapabilityValueAsync<T>(
        string sku, string device, string apiKey, string instance, Func<JsonElement, T?> extract, CancellationToken cancellationToken)
        where T : struct
    {
        try
        {
            using var client = httpClientFactory.CreateClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseUri, "router/api/v1/device/state"));
            request.Headers.Add("Govee-API-Key", apiKey);
            request.Content = JsonContent.Create(new { requestId = Guid.NewGuid().ToString(), payload = new { sku, device } });

            using var response = await SendWithTimeoutAsync(client, request, cancellationToken);
            if (!response.IsSuccessStatusCode) return default;

            using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            if (!document.RootElement.TryGetProperty("payload", out var payload)
                || !payload.TryGetProperty("capabilities", out var capabilities))
                return default;

            foreach (var capability in capabilities.EnumerateArray())
            {
                if (capability.GetProperty("instance").GetString() != instance) continue;
                return extract(capability.GetProperty("state").GetProperty("value"));
            }
            return default;
        }
        catch (Exception error)
        {
            logger.LogWarning("Govee state request for {Device} ({Instance}) failed: {Message}", device, instance, error.Message);
            return default;
        }
    }

    private static async Task<HttpResponseMessage> SendWithTimeoutAsync(HttpClient client, HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(RequestTimeout);
        return await client.SendAsync(request, timeoutCts.Token);
    }
}
