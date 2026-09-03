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

        if (button.Targets.Count > 0)
        {
            var goveeTargets = button.Targets.Select(target => (target.GoveeSku, target.GoveeDevice)).ToList();
            if (action == "toggleBrightness")
                await goveeClient.ApplyBrightnessToggleAsync(goveeTargets, options.GoveeApiKey, cancellationToken);
            else
                await goveeClient.ApplyAsync(action, goveeTargets, options.GoveeApiKey, cancellationToken);
        }

        // toggleBrightness only applies to Govee targets above -- these lights' brightness DP
        // and scale vary per device/category and aren't wired up, so skip them for that action.
        if (button.TuyaLightTargets.Count > 0 && action != "toggleBrightness")
        {
            var tuyaTargets = button.TuyaLightTargets.Select(target => (target.DeviceId, target.PowerCode)).ToList();
            await tuyaLightClient.ApplyAsync(action, tuyaTargets, dataCenter, options.AccessId, options.AccessSecret, cancellationToken);
        }
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
