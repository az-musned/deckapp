using System.Net.Http.Json;
using System.Text.Json;

namespace TuyaGoveeBridge.Govee;

/// Minimal Govee cloud client, mirroring the shape (and exact request bodies) of the iOS app's
/// GoveeClient.swift -- just enough to turn a light on/off from the bridge, for the Tuya button
/// automation. Not a full port: no device discovery or state polling beyond what toggling needs.
public sealed class GoveeClient(IHttpClientFactory httpClientFactory, ILogger<GoveeClient> logger)
{
    private static readonly Uri BaseUri = new("https://openapi.api.govee.com");

    public Task TurnOnAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        ControlAsync(sku, device, apiKey, powerOn: true, cancellationToken);

    public Task TurnOffAsync(string sku, string device, string apiKey, CancellationToken cancellationToken) =>
        ControlAsync(sku, device, apiKey, powerOn: false, cancellationToken);

    /// Govee's control endpoint is set-only (no toggle), so a toggle first reads current state.
    /// If the state read fails, defaults to turning on -- a light that's already on staying on
    /// is a much smaller surprise than a "toggle" that silently does nothing.
    public async Task ToggleAsync(string sku, string device, string apiKey, CancellationToken cancellationToken)
    {
        var isOn = await TryGetPowerStateAsync(sku, device, apiKey, cancellationToken);
        await ControlAsync(sku, device, apiKey, powerOn: !(isOn ?? false), cancellationToken);
    }

    private async Task ControlAsync(string sku, string device, string apiKey, bool powerOn, CancellationToken cancellationToken)
    {
        using var client = httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseUri, "router/api/v1/device/control"));
        request.Headers.Add("Govee-API-Key", apiKey);
        request.Content = JsonContent.Create(new
        {
            requestId = Guid.NewGuid().ToString(),
            payload = new
            {
                sku,
                device,
                capability = new
                {
                    type = "devices.capabilities.on_off",
                    instance = "powerSwitch",
                    value = powerOn ? 1 : 0
                }
            }
        });

        using var response = await client.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            logger.LogWarning("Govee control request for {Device} failed ({Status}): {Body}", device, response.StatusCode, body);
        }
    }

    private async Task<bool?> TryGetPowerStateAsync(string sku, string device, string apiKey, CancellationToken cancellationToken)
    {
        try
        {
            using var client = httpClientFactory.CreateClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseUri, "router/api/v1/device/state"));
            request.Headers.Add("Govee-API-Key", apiKey);
            request.Content = JsonContent.Create(new { requestId = Guid.NewGuid().ToString(), payload = new { sku, device } });

            using var response = await client.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode) return null;

            using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            if (!document.RootElement.TryGetProperty("payload", out var payload)
                || !payload.TryGetProperty("capabilities", out var capabilities))
                return null;

            foreach (var capability in capabilities.EnumerateArray())
            {
                if (capability.GetProperty("instance").GetString() != "powerSwitch") continue;
                var value = capability.GetProperty("state").GetProperty("value");
                return value.ValueKind == JsonValueKind.Number && value.GetInt32() != 0;
            }
            return null;
        }
        catch (Exception error)
        {
            logger.LogWarning("Govee state request for {Device} failed: {Message}", device, error.Message);
            return null;
        }
    }
}
