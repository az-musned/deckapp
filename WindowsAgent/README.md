# Deck Windows Agent

This is the Windows-only Phase 7 Agent for DeckApp. It targets .NET 10 LTS and implements secure startup rules, private-network filtering, cryptographic pairing challenges, hashed credential storage, paired-device listing, independent Allow Remote Input and emergency-disable state, a persistent authenticated WebSocket, ordinary keyboard/mouse injection through `SendInput`, and paired HTTPS capabilities for an application allowlist, Windows audio sessions, and GoXLR Utility.

The iOS app can now select this live transport from Remote Settings, pair through HTTPS, and open the authenticated input WebSocket. Clipboard transfer remains disabled.

## Secure defaults

- HTTPS is mandatory; startup fails without a valid certificate in `CurrentUser/My`.
- The default bind address is `127.0.0.1`. Configure one explicit LAN or private-VPN address—never `0.0.0.0` or a public address.
- Remote clients are accepted only from loopback, RFC1918 LAN, link-local, IPv6 unique-local, or `100.64.0.0/10` private-VPN/CGNAT space.
- Remote input starts disabled and can be enabled only from the local Windows console.
- Pairing codes are random, short-lived, attempt-limited, and displayed only in the local console.
- Only SHA-256 credential hashes are stored. Plaintext credentials are returned once to the paired client and are never logged.
- Only one input WebSocket may be active. Messages are limited to 16 KiB and 64 events.
- Pointer/scroll events are coalesced, stale events and sequence replays are dropped, and releases are still accepted when their original press has become stale.
- Every disconnect, local disable, emergency disable, and injection failure releases all logically held keys and mouse buttons.
- Input is refused outside the normal `Default` Windows input desktop. The Agent does not bypass UAC, the lock screen, UIPI, secure desktop, elevated applications, or anti-cheat protections.
- Application launch is limited to exact absolute `.exe` paths configured locally; requests cannot supply paths, arguments, or shell commands.
- Capability commands require pairing but do not depend on Allow Remote Input. They are serialized and return confirmed only after state is read back.
- GoXLR integration invokes only `goxlr-client.exe` when its daemon is already available. The Agent never starts or replaces the GoXLR device manager.

## Build on Windows

1. Install the latest patched [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).
2. For a nearby iPad on the PC hotspot or home LAN, open PowerShell as Administrator and run:
   `powershell -ExecutionPolicy Bypass -File WindowsAgent\scripts\Configure-LocalConnection.ps1 -BindAddress 192.168.137.1`
   Omit `-BindAddress` only when the PC has exactly one private address; the script prefers the standard Windows hotspot address when present.
3. Copy the generated `WindowsAgent\DeckAgent-Local-Root.cer` public certificate to the iPad. Install it, then enable it under Settings > General > About > Certificate Trust Settings.
4. In DeckApp Remote Settings, use the address printed by the script, such as `https://192.168.137.1:8732`. This route stays directly on the PC hotspot and does not use Tailscale.
5. For manual configuration instead, set `Agent:CertificateThumbprint` and one explicit private `Agent:BindAddress` in `DeckWindowsAgent/appsettings.Local.json`.
6. Run `dotnet build WindowsAgent/DeckWindowsAgent/DeckWindowsAgent.csproj`.
7. Run `dotnet run --project WindowsAgent/DeckWindowsAgent.Validation/DeckWindowsAgent.Validation.csproj`.
8. Run the Agent from a visible local console during development.

Press `I` locally to enable/disable remote input, `E` for emergency disable, `P` to list paired devices, or `R` to revoke one. Keep the console visible during this development phase.

## PC capabilities

Windows audio discovery reads the active sessions on the default multimedia output endpoint. The returned IDs are opaque hashes and the Agent supports per-session volume and mute with state readback.

GoXLR support uses the community [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) client/API. If `C:\Program Files\GoXLR Utility\goxlr-client.exe` exists it is discovered automatically, or set an absolute `GoXlrClientPath`. The GoXLR Utility daemon must already be managing the device. Do not run it alongside another manager that owns the GoXLR; when unavailable, the Agent reports `goXlrConnected: false` and makes no device change. Channel levels are 0–1 on the Deck protocol. GoXLR Utility status reports raw 0–255 fader values while its CLI accepts 0–100 percentages. Mute is exposed only for a channel assigned to a physical fader.

Applications and games must be explicitly allowlisted in ignored `appsettings.Local.json`:

```json
{
  "Agent": {
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
        }
      ]
    }
  }
}
```

`Kind` is `application` or `game`. Re-running `Configure-LocalConnection.ps1` preserves an existing `Agent:Capabilities` section. See [protocol-v1.md](protocol-v1.md) for the wire format and [windows-agent-capabilities.md](../docs/windows-agent-capabilities.md) for the Mac/iOS handoff.

Do not create router port-forwarding rules. Outside-home access must use a private VPN such as Tailscale or a future authenticated relay.

`appsettings.Local.json`, private keys, and generated certificates are intentionally ignored by Git. The setup script exports only the public root certificate, trusts that root for the current Windows user so the Agent's strict certificate lookup succeeds, verifies the server IP SAN and non-exportable private keys, and restricts its firewall rule to the selected private address, its exact Windows interface, and `LocalSubnet`. Windows Mobile Hotspot interfaces do not expose a normal NLA profile, so the rule applies across profiles but cannot match another interface or address; it does not create router forwarding or allow non-local peers.
