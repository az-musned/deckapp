using System.Buffers;
using System.Text.Json;
using DotPulsar;
using DotPulsar.Abstractions;
using DotPulsar.Extensions;
using TuyaGoveeBridge.Configuration;
using TuyaGoveeBridge.Govee;

namespace TuyaGoveeBridge.Tuya;

/// Subscribes to Tuya's message service for the configured Zigbee button devices and turns the
/// mapped Govee light on/off when a press comes in. Runs for this service's whole lifetime,
/// independent of any phone or PC -- that's the entire point: a physical button press is an
/// event that can happen at any time, and only something always-on can react to it reliably.
///
/// Confirmed from a live press: this button model reports its click type as a DP named
/// "switch_type_1" with value "single_click" (also expect "double_click"/"long_press") inside a
/// devicePropertyMessage -- there's no persistent on/off state to report, so any
/// devicePropertyMessage for a configured device ID is treated as a press.
public sealed class TuyaButtonBridgeService(
    BridgeOptions options,
    GoveeClient goveeClient,
    TuyaLightClient tuyaLightClient,
    ILogger<TuyaButtonBridgeService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.IsConfigured)
        {
            logger.LogInformation("Tuya button bridge is not configured (Bridge:* in appsettings.Local.json); staying inactive.");
            return;
        }

        TuyaDataCenterExtensions.TryParse(options.DataCenter, out var dataCenter);
        var buttonsByDeviceId = options.Buttons.ToDictionary(button => button.DeviceId, StringComparer.Ordinal);

        var attempt = 0;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunOnceAsync(dataCenter, buttonsByDeviceId, stoppingToken);
                attempt = 0;
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error)
            {
                attempt++;
                var delaySeconds = Math.Min(60, 2 * attempt);
                logger.LogWarning(error, "Tuya button Pulsar subscription dropped; reconnecting in {Delay}s.", delaySeconds);
                try { await Task.Delay(TimeSpan.FromSeconds(delaySeconds), stoppingToken); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    private async Task RunOnceAsync(
        TuyaDataCenter dataCenter,
        Dictionary<string, ButtonMapping> buttonsByDeviceId,
        CancellationToken stoppingToken)
    {
        var topic = $"persistent://{options.AccessId}/out/event";
        var subscriptionName = $"{options.AccessId}-sub";
        IAuthentication authentication = new TuyaPulsarAuthentication(options.AccessId, options.AccessSecret);

        await using var client = PulsarClient.Builder()
            .ServiceUrl(new Uri(dataCenter.PulsarServiceUrl()))
            .Authentication(authentication)
            .Build();

        await using var consumer = client.NewConsumer()
            .SubscriptionName(subscriptionName)
            .Topic(topic)
            .SubscriptionType(SubscriptionType.Failover)
            .Create();

        logger.LogInformation("Tuya button bridge connected ({DataCenter}); watching {Count} device(s).", dataCenter, buttonsByDeviceId.Count);

        await foreach (var message in consumer.Messages(stoppingToken))
        {
            try
            {
                message.Properties.TryGetValue("em", out var encryptionMode);
                var decrypted = TuyaMessageDecryptor.Decrypt(encryptionMode, message.Data.ToArray(), options.AccessSecret);
                await HandleDecryptedMessageAsync(decrypted, buttonsByDeviceId, dataCenter, stoppingToken);
            }
            catch (Exception error)
            {
                logger.LogWarning(error, "Failed to handle a Tuya Pulsar message; skipping it.");
            }
            await consumer.Acknowledge(message);
        }
    }

    private async Task HandleDecryptedMessageAsync(
        string decrypted,
        Dictionary<string, ButtonMapping> buttonsByDeviceId,
        TuyaDataCenter dataCenter,
        CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(decrypted);
        var root = document.RootElement;

        // Real message shape (confirmed from a live button press), unlike the flatter shape
        // assumed before any press had been observed: the device ID and DP payload are nested
        // under "bizData", e.g. {"bizCode":"devicePropertyMessage","bizData":{"devId":"...",
        // "properties":[{"code":"switch_type_1","value":"single_click",...}]}}. The DP named
        // "switch_type_1" carries the click type (single_click confirmed live; double_click and
        // long_press are Tuya's documented naming for this DP but not yet observed from this
        // specific button).
        if (!root.TryGetProperty("bizData", out var bizData) || !bizData.TryGetProperty("devId", out var devIdElement)) return;
        var deviceId = devIdElement.GetString();
        if (deviceId is null || !buttonsByDeviceId.TryGetValue(deviceId, out var button)) return;

        var clickType = FindSwitchTypeValue(bizData);
        logger.LogInformation("Tuya button '{DeviceId}' click type: {ClickType}", deviceId, clickType ?? "(none)");

        if (clickType is null || !button.ClickActions.TryGetValue(clickType, out var action))
        {
            logger.LogInformation("Tuya button '{DeviceId}' click type '{ClickType}' has no configured action; ignoring.", deviceId, clickType ?? "(none)");
            return;
        }

        var goveeTargets = button.Targets.Select(target => (target.GoveeSku, target.GoveeDevice)).ToList();
        var tuyaTargets = button.TuyaLightTargets.Select(target => (target.DeviceId, target.PowerCode)).ToList();

        if (action == "toggleBrightness")
        {
            // Only Tuya targets with a BrightnessCode configured participate -- a light with no
            // brightness capability, or one not wired up with its DP code/range, is skipped.
            var tuyaBrightnessTargets = button.TuyaLightTargets
                .Where(target => !string.IsNullOrWhiteSpace(target.BrightnessCode))
                .Select(target => (target.DeviceId, BrightnessCode: target.BrightnessCode!, target.BrightnessLow, target.BrightnessHigh))
                .ToList();
            if (goveeTargets.Count == 0 && tuyaBrightnessTargets.Count == 0) return;

            // Resolve one shared dim direction, same reasoning as the "toggle" resolution below:
            // each provider reading its own current brightness independently could disagree
            // about which direction to go.
            bool dim;
            if (goveeTargets.Count > 0)
            {
                var currentPercent = await goveeClient.GetBrightnessPercentAsync(goveeTargets[0].GoveeSku, goveeTargets[0].GoveeDevice, options.GoveeApiKey, cancellationToken);
                dim = (currentPercent ?? 0) >= 50;
            }
            else
            {
                var reference = tuyaBrightnessTargets[0];
                var currentValue = await tuyaLightClient.GetBrightnessAsync(reference.DeviceId, reference.BrightnessCode, dataCenter, options.AccessId, options.AccessSecret, cancellationToken);
                var midpoint = (reference.BrightnessLow + reference.BrightnessHigh) / 2;
                dim = (currentValue ?? 0) >= midpoint;
            }

            var brightnessTasks = new List<Task>();
            if (goveeTargets.Count > 0)
                brightnessTasks.Add(goveeClient.ApplyBrightnessDirectionAsync(dim, goveeTargets, options.GoveeApiKey, cancellationToken));
            if (tuyaBrightnessTargets.Count > 0)
                brightnessTasks.Add(tuyaLightClient.ApplyBrightnessDirectionAsync(dim, tuyaBrightnessTargets, dataCenter, options.AccessId, options.AccessSecret, cancellationToken));
            await Task.WhenAll(brightnessTasks);
            return;
        }

        // "toggle" must resolve to one shared direction before touching either provider: each
        // provider's own ApplyAsync would otherwise read its own targets' current state
        // independently, and if a Govee light and the Tuya light ever end up in different
        // states (e.g. one missed an earlier command), that produces two different toggle
        // decisions -- observed live as the Tuya light flipping the opposite way from the rest.
        // turnOn/turnOff need no resolution since they're already an explicit direction.
        var resolvedAction = action == "toggle"
            ? (await ResolveToggleDirectionAsync(goveeTargets, tuyaTargets, dataCenter, cancellationToken) ? "turnOff" : "turnOn")
            : action;

        var applyTasks = new List<Task>();
        if (goveeTargets.Count > 0)
            applyTasks.Add(goveeClient.ApplyAsync(resolvedAction, goveeTargets, options.GoveeApiKey, cancellationToken));
        if (tuyaTargets.Count > 0)
            applyTasks.Add(tuyaLightClient.ApplyAsync(resolvedAction, tuyaTargets, dataCenter, options.AccessId, options.AccessSecret, cancellationToken));
        await Task.WhenAll(applyTasks);
    }

    /// Reads current power state from a single reference light -- prefers the first Govee
    /// target if there is one, otherwise the first Tuya light -- so every target this button
    /// controls moves the same direction together instead of each provider deciding from its
    /// own (possibly out-of-sync) targets. Defaults to "was off" (so the resolved action turns
    /// everything on) if the read fails, matching GoveeClient/TuyaLightClient's own fallback.
    private async Task<bool> ResolveToggleDirectionAsync(
        List<(string GoveeSku, string GoveeDevice)> goveeTargets,
        List<(string DeviceId, string PowerCode)> tuyaTargets,
        TuyaDataCenter dataCenter,
        CancellationToken cancellationToken)
    {
        if (goveeTargets.Count > 0)
            return await goveeClient.GetPowerStateAsync(goveeTargets[0].GoveeSku, goveeTargets[0].GoveeDevice, options.GoveeApiKey, cancellationToken) ?? false;
        if (tuyaTargets.Count > 0)
            return await tuyaLightClient.GetPowerStateAsync(tuyaTargets[0].DeviceId, tuyaTargets[0].PowerCode, dataCenter, options.AccessId, options.AccessSecret, cancellationToken) ?? false;
        return false;
    }

    private static string? FindSwitchTypeValue(JsonElement bizData)
    {
        if (!bizData.TryGetProperty("properties", out var properties)) return null;
        foreach (var property in properties.EnumerateArray())
        {
            if (property.TryGetProperty("code", out var code) && code.GetString() == "switch_type_1"
                && property.TryGetProperty("value", out var value))
                return value.GetString();
        }
        return null;
    }
}
