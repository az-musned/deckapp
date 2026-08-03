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
2. Set `Agent:CertificateThumbprint` and a specific private `Agent:BindAddress` in `DeckWindowsAgent/appsettings.json`.
3. Run `dotnet build WindowsAgent/DeckWindowsAgent/DeckWindowsAgent.csproj`.
4. Run `dotnet run --project WindowsAgent/DeckWindowsAgent.Validation/DeckWindowsAgent.Validation.csproj`.
5. Run the Agent from a visible local console during development.

Press `I` locally to enable/disable remote input, `E` for emergency disable, `P` to list paired devices, or `R` to revoke one. Keep the console visible during this development phase.

Do not create router port-forwarding rules. Outside-home access must use a private VPN such as Tailscale or a future authenticated relay.
