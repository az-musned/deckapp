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
/// The exact Tuya device-property (DP) code and value that mean "pressed" for this specific
/// button model aren't known yet -- every status message received for a configured device ID is
/// logged in full at Information level and unconditionally treated as a press. Zigbee scene
/// switches typically only report a status message when actually pressed (unlike a plug, which
/// reports ongoing telemetry), so "a message arrived for this device" is a reasonable starting
/// trigger; narrow this to a specific DP code/value once real press payloads are visible in the
/// log, if it turns out something else on the device also produces a status message.
public sealed class TuyaButtonBridgeService(
    BridgeOptions options,
    GoveeClient goveeClient,
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
                await HandleDecryptedMessageAsync(decrypted, buttonsByDeviceId, options.GoveeApiKey, stoppingToken);
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
        string goveeApiKey,
        CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(decrypted);
        var root = document.RootElement;
        if (!root.TryGetProperty("devId", out var devIdElement)) return;
        var deviceId = devIdElement.GetString();
        if (deviceId is null || !buttonsByDeviceId.TryGetValue(deviceId, out var button)) return;

        var statusJson = root.TryGetProperty("status", out var status) ? status.GetRawText() : "(none)";
        logger.LogInformation("Tuya button '{DeviceId}' reported status: {Status}", deviceId, statusJson);

        switch (button.Action)
        {
            case "turnOn":
                await goveeClient.TurnOnAsync(button.GoveeSku, button.GoveeDevice, goveeApiKey, cancellationToken);
                break;
            case "turnOff":
                await goveeClient.TurnOffAsync(button.GoveeSku, button.GoveeDevice, goveeApiKey, cancellationToken);
                break;
            default:
                await goveeClient.ToggleAsync(button.GoveeSku, button.GoveeDevice, goveeApiKey, cancellationToken);
                break;
        }
    }
}
