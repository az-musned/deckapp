# DeckApp

DeckApp is a native SwiftUI personal control layer for iPhone and iPad. Phases 1 and 2 provide capability-oriented, customizable widgets; Phase 3 adds a secure Home Assistant foundation. The working private-network Bitfocus Companion integration remains preserved, while the future Windows Control Agent stays behind an explicit architectural boundary.

## Open and run

Open `DeckApp.xcodeproj` in Xcode 26 or newer, select the `DeckApp` scheme, and run on an iOS 18+ iPhone or iPad simulator. iOS 26 uses native Liquid Glass. Earlier supported versions use the design system’s SwiftUI material fallback.

## Current scope

- Feature-oriented app architecture and folder structure
- Dashboard and command data models
- Capability descriptions, responsive widget definitions, and a default Room Control template
- Mock dashboard and command services
- Mock light, climate, LG TV remote, guarded PC-power, and GoXLR mixer widgets
- Accessibility-aware Liquid Glass design system
- Adaptive iPhone and iPad navigation
- Responsive four-column iPad and two-column iPhone widget layouts
- SwiftData-backed widget gallery, configuration, resizing, and reordering
- Independent iPhone and iPad widget-size overrides
- Customizable Companion actions and folders
- Versioned mock Windows Agent protocol with pairing, Keychain credential storage, revocation, permission/emergency states, and keyboard/touchpad Remote foundation
- Mock Windows application/game, audio-session, and GoXLR capability inventory
- State-confirmed mock application launch, per-session audio, and GoXLR channel controls with visible command lifecycle
- Live GoXLR channel controls, transient audio meters, adaptive mixer UI, and Windows endpoint mapping through the paired Agent
- Phase 7 Windows-only .NET 10 Agent with HTTPS-only startup, private-network enforcement, cryptographic pairing, credential revocation, local safety controls, authenticated WebSocket input, and guarded `SendInput` injection
- Optional live iOS Windows Agent transport with REST pairing, separate Keychain credential, authenticated `wss://` input batches, acknowledgements, latency measurement, and automatic safety-state monitoring
- Strict Windows Agent endpoint diagnostics that reject HTTP, loopback, embedded credentials, query data, and fragments while identifying Local, VPN, and Remote routes
- Agent-only TLS sessions anchored to the bundled public `DeckAgent-Local-Root.cer`, with normal hostname/IP SAN and certificate-validity checks preserved
- Local, Remote, and Offline connection presentation
- Settings placeholders for Home Assistant and private-VPN PC control
- Validated LAN/private-VPN Bitfocus Companion connection testing
- Local-first Home Assistant connection with secure HTTPS remote fallback
- Home Assistant access-token storage in Keychain
- REST entity discovery and authenticated WebSocket live-state subscription
- `NWPathMonitor` reconnect and subscription restoration
- Discovered Home Assistant light mapping with state-confirmed power and brightness commands
- Capability-driven Home Assistant climate, media-player, and smart-switch mapping
- Optional Home Assistant `remote.*` mapping for LG navigation and capability-gated TV source/media controls
- Home Assistant-backed PC online sensor, Wake-on-LAN, timeout, and queued Launch Game workflow
- Home Assistant script routing for Launch Game/Sleep PC and sanitized integration-health diagnostics
- Adaptive Home Assistant Scenes screen with favorites and observable orchestration progress

Unmapped device widgets are intentionally labeled `MOCK`. Mapped light, climate, TV, and smart-plug widgets are labeled `LIVE` and use Home Assistant. GoXLR widgets can use either mock data or the paired Windows Agent, while Remote Settings selects the live Agent for keyboard, pointer, controls, and metering. The development pairing code is `482913`; it is only for the in-app mock and is not used by the real Agent.

The Windows project and PC-side setup notes are in [WindowsAgent](WindowsAgent/README.md).

See [the architecture](docs/architecture.md), [the product specification](docs/product-spec.md), and [GoXLR live audio meters](docs/goxlr-live-meters.md) for details.

For PC setup, see [Connecting Bitfocus Companion](docs/companion-setup.md).
