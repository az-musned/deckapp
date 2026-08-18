# TuyaGoveeBridge

Standalone, cross-platform .NET service that bridges Tuya Zigbee button presses to Govee
light actions. Extracted from the Windows Agent so it can run on an always-on host that
isn't the gaming PC (which is sometimes off) -- see `docs/oracle-vm-deployment.md` for
deploying it to a free Oracle Cloud VM.

It subscribes to Tuya's Pulsar message service for a configured list of button device IDs,
and calls Govee's cloud API (turn on / off / toggle) whenever a status message arrives for
one of them.

## Configuration

Copy `appsettings.Local.json.example` to `appsettings.Local.json` (gitignored) and fill in:

```json
{
  "Bridge": {
    "AccessId": "your-tuya-access-id",
    "AccessSecret": "your-tuya-access-secret",
    "DataCenter": "centralEurope",
    "GoveeApiKey": "your-govee-api-key",
    "Buttons": [
      { "DeviceId": "first-button-device-id", "GoveeSku": "H61xx", "GoveeDevice": "AA:BB:CC:...", "Action": "toggle" },
      { "DeviceId": "second-button-device-id", "GoveeSku": "H61xx", "GoveeDevice": "AA:BB:CC:...", "Action": "toggle" }
    ]
  }
}
```

`DataCenter` is one of `westAmerica`, `eastAmerica`, `centralEurope`, `westEurope`, `china`,
`india` -- match whatever your Tuya Cloud Project uses. `Action` is `turnOn`, `turnOff`, or
`toggle`.

The exact Tuya device-property meaning "pressed" for your button model isn't known yet --
every status message for a configured device is logged in full at Information level and
unconditionally treated as a press. Watch the logs after a real press and narrow the trigger
in `TuyaButtonBridgeService.HandleDecryptedMessageAsync` if something else on the device also
produces a status message.

## Run locally

```bash
dotnet run --project TuyaGoveeBridge
```

## Publish for Linux (Oracle VM)

```bash
dotnet publish TuyaGoveeBridge -c Release -r linux-arm64 --self-contained false -o publish
```

Use `linux-x64` instead of `linux-arm64` if your VM is an AMD/Intel shape rather than Ampere.
