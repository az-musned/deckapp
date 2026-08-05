# Deck Windows Agent

This is the Windows-only Phase 7 Agent for DeckApp. It targets .NET 10 LTS and currently implements secure startup rules, private-network filtering, cryptographic pairing challenges, hashed credential storage, paired-device listing, independent Allow Remote Input and emergency-disable state, a persistent authenticated WebSocket, and ordinary keyboard/mouse injection through the supported Windows `SendInput` API.

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

## Home mesh and cellular access

For one private address that works on home Wi-Fi and 5G, install and sign in to Tailscale on the Windows PC and iPhone/iPad. Then run PowerShell as Administrator:

`powershell -ExecutionPolicy Bypass -File WindowsAgent\scripts\Configure-TailscaleConnection.ps1 -AllowCompanion`

The script selects the PC's active `100.64.0.0/10` Tailscale address, creates a TLS certificate for that exact IP, preserves existing Windows audio/GoXLR/application capability settings, and limits inbound firewall rules to the Tailscale interface and tailnet address range. It prints the Agent and optional Companion addresses to enter in DeckApp. Install and explicitly trust the exported public root certificate on each iPhone/iPad.

Enable Tailscale VPN On Demand for Wi-Fi and cellular on iOS so the private route remains available after path changes. For latency checks, run `tailscale ping <iphone-or-ipad-name>` on the PC. A `direct` path is preferred; a `DERP` path is encrypted but can have higher latency. DeckApp never requires an exit node for this connection.

Press `I` locally to enable/disable remote input, `E` for emergency disable, `P` to list paired devices, or `R` to revoke one. Keep the console visible during this development phase.

Do not create router port-forwarding rules. Outside-home access must use a private VPN such as Tailscale or a future authenticated relay.

`appsettings.Local.json`, private keys, and generated certificates are intentionally ignored by Git. The setup script exports only the public root certificate and restricts its firewall rule to the selected private interface and `LocalSubnet`.
