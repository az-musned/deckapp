# Windows Agent capabilities: Mac/iOS handoff

This is the implementation handoff for the Mac-side DeckApp agent. The Windows branch adds real application/game, Windows audio-session, and GoXLR controls to the existing paired HTTPS transport. Remote keyboard and pointer input continues over its authenticated WebSocket and is not routed through Companion or Home Assistant.

## iOS integration points

- `DeckApp/Services/WindowsAgentClient.swift` implements the production capability GET/POST calls and maps the JSON DTOs into the existing `WindowsAgentCapabilitySnapshot` models.
- `DeckApp/Services/RemoteInputController.swift` already refreshes a snapshot and exposes application launch, audio volume/mute, and GoXLR level/mute actions.
- `DeckApp/Features/Remote/RemoteControlView.swift` already renders the live controls and command progress.
- `DeckApp/Models/RemoteInputModels.swift` is the domain model. Keep its `goXLR` spelling; the private wire DTO deliberately maps the protocol's `goXlr` spelling.
- `WindowsAgent/protocol-v1.md` is authoritative for endpoint paths, payloads, errors, authentication, and confirmation semantics.

The Mac agent should build the iOS target, resolve any Swift compiler issues, and test against a paired Windows Agent. No TLS delegate, trust-all callback, HTTP fallback, Companion route, or Home Assistant route is needed or permitted.

## Live meter contract for a future Swift slice

The Windows backend now exposes GoXLR virtual-endpoint signal meters, but this branch deliberately does not modify Swift. The Mac-side implementation should:

1. Fetch `GET /api/v1/audio/endpoints` and present `suggestedChannelIds` as suggestions, never silently accepted mappings.
2. Fetch `GET /api/v1/audio/channels` and explicitly map each logical channel with `PUT /api/v1/audio/channels/{channelId}/mapping`.
3. Open authenticated `wss://<agent>/api/v1/audio/meters/ws` for 30 Hz locally, or append `?mode=reduced` for approximately 18 Hz.
4. Apply a frame only when its `sequence` exceeds the last applied sequence.
5. Treat GoXLR fader `level` and live `linearPeak`/`displayLevel` as different values.
6. Display silence as zero while `available` remains true, and show unavailable only when the mapped endpoint cannot be sampled.

The complete schema and errors are in `WindowsAgent/protocol-v1.md`. Normal URLSession certificate validation and the existing paired bearer credential apply to REST and WebSocket requests.

## Windows implementation points

- `Capabilities/AgentCapabilityService.cs` serializes commands and returns a fresh snapshot.
- `Capabilities/ApplicationCapabilityService.cs` launches only exact locally allowlisted executable paths, with no caller-supplied path, arguments, or shell.
- `Capabilities/WindowsAudioSessionService.cs` uses Windows Core Audio for sessions on the default multimedia render endpoint. IDs are opaque SHA-256-derived values; commands read state back before reporting confirmation.
- `Capabilities/GoXlrCapabilityService.cs` calls `goxlr-client.exe` with fixed structured arguments, a three-second timeout, and bounded output. It never starts the daemon.
- `Protocol/CapabilityProtocol.cs` contains the wire records.

The endpoints are:

- `GET /api/v1/agent/capabilities`
- `POST /api/v1/agent/commands`

Both require `Authorization: Bearer <paired credential>`. They remain usable when Allow Remote Input is off. That separation is intentional.

## Windows-local configuration

Keep machine paths in ignored `WindowsAgent/DeckWindowsAgent/appsettings.Local.json`:

```json
{
  "Agent": {
    "BindAddress": "192.168.137.1",
    "Port": 8732,
    "CertificateThumbprint": "CURRENT_USER_MY_THUMBPRINT",
    "Capabilities": {
      "WindowsAudioEnabled": true,
      "GoXlrEnabled": true,
      "GoXlrClientPath": "",
      "Applications": [
        {
          "Id": "obs",
          "Name": "OBS Studio",
          "Kind": "application",
          "ExecutablePath": "C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe"
        },
        {
          "Id": "example-game",
          "Name": "Example Game",
          "Kind": "game",
          "ExecutablePath": "D:\\Games\\Example\\Game.exe"
        }
      ]
    }
  }
}
```

Application IDs are stable ASCII identifiers containing letters, digits, `.`, `_`, or `-`. Paths must be absolute `.exe` paths. Do not commit this file. The hotspot configuration script preserves an existing `Capabilities` section.

## GoXLR operational constraint

The integration targets the community [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) CLI/API. Automatic discovery checks `C:\Program Files\GoXLR Utility\goxlr-client.exe`; otherwise configure its exact absolute path. `goXlrConnected` becomes true only when the Utility daemon is already running and returns mixer status.

The official GoXLR app currently owns this development PC's device, while GoXLR Utility 1.2.3 is installed but its daemon is not running. Do not start the Utility daemon or change managers automatically. The owner must make that explicit operational choice first. Until then, the correct result is `goXlrConnected: false`, not a claim that control succeeded.

Mute control is limited to channels assigned to physical faders because that is the state the Utility exposes safely. Level control uses normalized channel IDs and is confirmed from a new status snapshot.

## Verification checklist

1. Build `WindowsAgent/DeckWindowsAgent/DeckWindowsAgent.csproj`.
2. Run `WindowsAgent/DeckWindowsAgent.Validation/DeckWindowsAgent.Validation.csproj`. This uses fake command sinks and read-only Windows audio discovery; it does not call `SendInput` or mutate a real mixer.
3. Build DeckApp on the Mac and install it on the iPhone/iPad.
4. Pair through strict HTTPS using the already trusted local root certificate.
5. Confirm application entries reflect the local allowlist and Windows audio sessions appear.
6. Test each command and require both `confirmed: true` and matching returned state.
7. Test GoXLR only after the user has deliberately selected GoXLR Utility as the active device manager.
8. Verify turning Allow Remote Input off blocks keyboard/pointer input but does not silently change capability authorization.
9. Verify revoking the paired device causes capability calls to return `401`.

Do not claim real application/audio/GoXLR success from an accepted HTTP request alone. Report the state observed after the command.
