# PC keyboard and touchpad remote

## Current scope

DeckApp contains the iPhone/iPad Remote UI, input-event model, coalescing and safety logic, and a versioned `WindowsRemoteInputServing` boundary. Remote Settings can switch between the development mock and an optional live Windows PC transport. The live client pairs through HTTPS, stores its credential separately in Keychain, opens one authenticated `wss://` input session, measures acknowledgement latency, and monitors Windows security state while connected.

The live address must use `https://`; its certificate must be trusted by iOS/iPadOS and match the configured hostname or IP address. DeckApp uses normal system TLS validation and contains no trust-all delegate or certificate-validation bypass.

For the lowest-latency nearby route, connect the iPad to the PC's Mobile Hotspot and run `WindowsAgent/scripts/Configure-LocalConnection.ps1` on Windows. It creates a machine-local TLS identity for the selected hotspot/LAN IP, writes ignored local Agent settings, and adds a firewall rule limited to that address and the local subnet. After installing and explicitly trusting the exported public root certificate on the iPad, enter the printed `https://<hotspot-ip>:8732` address in Remote Settings. Tailscale remains an optional outside-home route, not part of this local data path.

Before applying an address, DeckApp rejects HTTP, loopback destinations, URLs containing username/password fields, query parameters, and fragments. The diagnostics label RFC1918, link-local, `.local`, Tailscale `100.64.0.0/10`, and `.ts.net` routes without exposing credentials. Contract validation also asserts the exact synthesized Swift enum JSON consumed by the Windows parser.

The mock now exercises an explicit pairing challenge, invalid-code rejection, a Keychain-stored credential, pairing revocation, the Windows-side Allow Remote Input permission, input-injection availability, and an emergency Disable Input state. Its development-only pairing code is `482913`. The production Agent must generate its own short-lived codes and credentials.

High-frequency input never uses Bitfocus Companion or Home Assistant. The production implementation belongs to the separately built Windows Control Agent.

## Transport contract

- One persistent authenticated connection over the home LAN, a private VPN, or a future secure authenticated relay.
- Pairing is required and Windows exposes a separate Allow Remote Input permission.
- Pointer movement and scrolling are coalesced at approximately 16 ms intervals; stale buffered events are discarded.
- Clicks and keyboard events are immediate. Key-up, button-up, and release-all events receive priority.
- Disconnecting, leaving the active app state, or encountering a transport error clears held modifiers/buttons and stops input.
- Typed and clipboard contents are never logged, analyzed, or persisted.

## Capability contract

The production Windows Agent and mock publish applications/games, Windows audio sessions, and GoXLR connection/channel state. The Remote Media screen can launch an allowlisted application, change per-session volume/mute, and change GoXLR level/mute. These controls expose pending and running feedback, then report confirmed only after the Agent returns updated state.

Capability commands require a paired client but remain independent from the separate Allow Remote Input permission. Disabling keyboard/touchpad access therefore does not disable non-input Agent capabilities. An accepted request is not sufficient evidence that an application launched, a mixer value changed, or a PC command completed.

## Windows Agent implementation

The Agent should use supported Windows input APIs such as `SendInput` for relative pointer motion, mouse buttons, vertical/horizontal scroll, virtual keys, Unicode text, function keys, and media keys. It must release all logical input on disconnect and clearly return an unavailable state when injection is blocked.

It must not attempt to bypass secure desktop, UAC, integrity-level restrictions, anti-cheat protections, the lock screen, or any other Windows security boundary.

The Agent must reject unpaired clients, support revocation, expose an independent Allow Remote Input permission, and include a local emergency Disable Input control.

The current Windows implementation handles relative pointer motion, scrolling, mouse buttons, virtual/control/function/media keys, modifiers, and Unicode text. It calibrates client/server clocks, rejects replays, drops stale motion, maintains causal down/up ordering, and releases all held input on disconnect or safety changes. It checks for the normal Windows `Default` input desktop and reports unavailable instead of attempting to bypass the lock screen, UAC, UIPI, secure desktop, elevated applications, or anti-cheat systems.

While connected, DeckApp checks session and Windows-owned safety state approximately every 750 ms. A closed WebSocket, emergency disable, revoked input permission, or unavailable input desktop pauses the controller and updates the visible connection state.

## Clipboard policy

Clipboard access is initiated only by the user selecting Send Clipboard Text or Send and Paste. DeckApp reads the pasteboard inside that action and immediately sends the selected request. Continuous synchronization and background clipboard monitoring are prohibited.
