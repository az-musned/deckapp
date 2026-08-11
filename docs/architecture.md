# DeckApp unified architecture

## 1. Current architecture summary

DeckApp is a native SwiftUI iPhone/iPad application with a single `@MainActor` observable `AppState` as its composition and runtime store. The project is organized into App, Features, DesignSystem, Models, Services, and Supporting layers. Feature views receive state through SwiftUI environment injection. Service dependencies are injected into `AppState`, with mock dashboard/command services and a real Bitfocus Companion client.

The design system centralizes spacing, color, corner radius, motion, and glass surface behavior. Native iOS 26 Liquid Glass availability checks and accessibility fallbacks remain inside the design-system layer.

## 2. Existing dashboard analysis

The original dashboard is a responsive scroll view with fixed light, climate, TV, scene, PC, and media sections. It switches at a 680-point breakpoint and the root navigation switches between an iPad sidebar and iPhone tab bar at 760 points. Device state currently comes from `RoomDashboard.preview` through `MockDashboardService`.

The Control Deck is already customizable and persists Companion buttons, folders, and PC widgets. The remaining fixed smart-device cards are presentation-specific and do not yet share capability descriptions. Phase 1 replaces that fixed composition with a default Room Control template rendered by a responsive widget grid.

## 3. Existing Bitfocus Companion integration analysis

The working Companion integration is preserved. `CompanionEndpoint` accepts only home-LAN, `.local`, loopback/link-local/private IPv4/IPv6, Tailscale CGNAT, and `.ts.net` addresses. Public addresses and embedded credentials are rejected. `CompanionClient` tests the web endpoint and presses configured locations using `POST /api/location/{page}/{row}/{column}/press`.

Dashboard actions expose queued, running, failed, and unavailable feedback. An accepted HTTP response remains running while awaiting external state confirmation; it is not treated as completed. Destructive custom actions can require confirmation. Companion remains an integration for existing actions/macros rather than the model for stateful controls.

## 4. Existing networking and persistence analysis

Companion uses `URLSession` with normal TLS validation and local-network permission. Its address, button mappings, and Control Deck JSON are stored in UserDefaults. No Companion secret is currently stored.

Home Assistant now has separate local and remote URL settings. Its access token is stored only in Keychain; non-secret URL and entity mappings use UserDefaults. The client prefers the local URL, permits remote fallback only over HTTPS, uses normal system TLS validation, loads entity state through REST, and subscribes to `state_changed` events through an authenticated WebSocket. `NWPathMonitor` triggers local/remote reselection, reconnect, and resubscription after path changes.

## 5. Proposed capability model

`DeviceCapabilityKind` describes common controls such as power, brightness, color, temperature, HVAC mode, volume, media playback, selection, and actions. Strong descriptors such as `NumericRangeCapability` carry bounds, step, unit, current value, writability, and availability. Widgets receive capability collections and render only supported controls.

Backends normalize vendor/entity details into these descriptors. Feature views never require types such as `GoveeBrightnessWidget` or `GreeTemperatureWidget`; the Phase 1 names describe mock presentations, while their inputs remain generic light, climate, media, switch, mixer, and action state.

## 6. Proposed widget model

`RoomWidgetDefinition` contains stable identity, display metadata, widget kind, preferred size, capability descriptions, and an optional backend reference. `RoomControlTemplate` is an ordered list of widget definitions. `RoomWidgetSize` maps to responsive column spans and visual heights.

The default Room Control template includes a light, climate, television, guarded PC-power workflow, audio mixer, PC Remote launcher, and existing Companion Control Deck.

Phase 2 now persists the ordered widget definitions in SwiftData. The dashboard editor provides a widget gallery, configuration, deletion safeguards, drag reordering, default sizing, and independent iPhone/iPad size overrides. Existing Companion mappings remain in their established store and are not deleted when a dashboard widget is removed or the layout is reset.

## 7. Proposed Home Assistant integration boundaries

`HomeAssistantServiceProtocol` owns connection testing, entity-state loading, and service calls. `HomeAssistantWebSocketClient` owns the authenticated live-state subscription. Phase 3 maps one discovered `light.*` entity into the existing Room Lights widget and waits for a matching state event before marking commands confirmed. Phase 4 now discovers light, climate, media-player, and switch attributes and converts their reported ranges, modes, options, writability, and availability into widget capabilities. Each mapping is explicit and unmapped widgets remain mocked.

Media-player actions are gated by the entity's `supported_features` bit field. TV source options come from `source_list`. Directional navigation requires a separately mapped `remote.*` entity and uses `remote.send_command`; because that service has no reliable resulting device state, HTTP acceptance remains a running/unconfirmed result rather than being presented as completion.

Phase 5 begins with the guarded PC wake workflow. A mapped binary sensor is the authoritative online state. The workflow can enable a mapped smart plug, send `wake_on_lan.send_magic_packet` through Home Assistant, and wait up to the configured timeout for that sensor. Launch Game is queued until the sensor reports online; it is cancelled on timeout. Existing Companion actions are not intercepted until both an online sensor and a wake method are configured.

Launch Game and Sleep PC can now be mapped to Home Assistant `script.*` entities. Those mappings take precedence over Companion, which keeps remote PC commands behind Home Assistant rather than exposing Companion publicly. Script execution observes the entity transition through its running lifecycle; a completed script is reported separately from independently verified PC state. Sleep additionally waits for the mapped PC sensor to report offline. Integration-health diagnostics expose only sanitized route, latency, subscription, mapping-count, PC, and Companion status—never tokens, URLs, entity identifiers, or raw backend errors.

The adaptive Scenes feature discovers Home Assistant `scene.*` and `script.*` entities and stores only the user's favorite identifiers. Each activation exposes secure-route, dispatch, and backend-confirmation steps. Stateless scenes are confirmed only after Home Assistant records a changed activation timestamp; scripts are confirmed after their observed running lifecycle completes. HTTP acceptance alone never completes the orchestration.

Home Assistant is the primary backend for Smart Life/Tuya, LG webOS, and smart-room scenes. It is not Apple Home or HomeKit. No direct vendor cloud API belongs in the initial implementation for those integrations.

Govee and Gree are deliberate exceptions: both connect directly to their vendor cloud APIs from Swift, bypassing Home Assistant entirely. `GoveeClient` is an actor-based direct client against `openapi.api.govee.com`. `GreeCloudClimateClient` is the same shape against Gree's regional cloud login/device endpoints and its MQTT broker, adopted after live protocol testing showed the AC's local LAN protocol (UDP/7000) does not respond on this unit's firmware, while the cloud path (login, state reads, and writes) was proven to work end-to-end. Because control is already cloud-mediated, no backend service is structurally required for a single-user single-device app; the iOS client talks to Gree's cloud directly, the same way it already does for Govee. The accepted tradeoff is that live climate state only refreshes while DeckApp is foregrounded, since iOS does not keep a background MQTT socket alive indefinitely — backgrounded state is represented as stale/unknown via `GreeStateConfidence` rather than presented as current, reusing the same pending/running/confirmed/failed command-confidence idiom used elsewhere in the app (see `WindowsAgentCommandResult`/`CommandStatus` and `GreeClimateCommandExecution`).

## 8. Proposed future Windows Agent boundaries

`WindowsAgentServiceProtocol` will expose pairing/connection state, PC state, applications/games, Windows audio devices and sessions, GoXLR channels, media sessions, system telemetry, and discrete commands. Configuration/query operations use authenticated request-response calls; live state uses one authenticated event channel.

The Windows Agent exposes capabilities and confirmed state rather than virtual Companion coordinates. Companion continues handling existing macros, scripts, OBS workflows, and already-configured multi-actions until deliberately migrated.

The iOS Remote foundation now defines `WindowsRemoteInputServing`, versioned authenticated session state, explicit pairing challenges, Keychain credential restoration and revocation, coalesced relative-pointer/scroll events, immediate keyboard/button events, held-input safety state, and an authenticated mock transport. Windows-owned Allow Remote Input, injection availability, and emergency Disable Input states are represented but cannot be overridden by iOS. A mock capability snapshot and command contract establish application/game, Windows audio-session, and GoXLR channel controls. Each command progresses through pending/running and becomes confirmed only after the Agent returns updated state. Capability commands require pairing but remain independent from the remote-input permission. The production Agent remains a separate implementation and must use supported Windows input APIs without bypassing Windows security boundaries. See [PC keyboard and touchpad remote](remote-input.md).

## 9. Proposed folder structure

```text
DeckApp/
├── App/                         composition root and AppState
├── DesignSystem/                tokens, glass surfaces, shared controls
├── Features/
│   ├── Dashboard/               Room Control grid and widget rendering
│   ├── ControlDeck/             future extracted editor/gallery
│   ├── IntegrationHealth/       future diagnostics
│   └── Settings/                connection and entity mapping
├── Models/
│   ├── Capabilities/            normalized capability descriptions
│   ├── Widgets/                 definitions, sizes, templates
│   ├── HomeAssistant/           future HA transport/domain models
│   ├── WindowsAgent/            future agent models
│   └── Companion/               existing location/action models
├── Services/
│   ├── HomeAssistant/           future REST/WebSocket coordinator
│   ├── WindowsAgent/            future authenticated client
│   ├── Companion/               existing client
│   └── Mock/                    deterministic Phase 1 runtime
└── Supporting/                  Info.plist and future assets
```

The physical project can migrate toward this layout incrementally; file-system-synchronized Xcode groups make moves low-risk.

## 10. Migration plan

1. Preserve Companion models, endpoint validation, client, mappings, and persisted Control Deck.
2. Add capability, widget-definition, template, and mock runtime models alongside `RoomDashboard`.
3. Render the new Room Control template through a responsive grid.
4. Adapt the existing Control Deck as the Companion-action widget.
5. Keep legacy room models temporarily for navigation/header/media compatibility.
6. In Phase 2, persist widget definitions in SwiftData and migrate existing UserDefaults Control Deck content without data loss.
7. In Phase 3, replace mock state sources with normalized Home Assistant state while keeping widget rendering unchanged.

## 11. Phased implementation plan

- Phase 1: capability-oriented models, responsive Room Control grid, deterministic mock widgets, default template, design foundation, and previews.
- Phase 2: edit mode, widget gallery/configuration, resizing/reordering, SwiftData, and device-specific layouts.
- Phase 3: secure Home Assistant REST/WebSocket foundation and local/remote connection selection.
- Phase 4: capability discovery and Home Assistant-backed light, climate, switch, and LG webOS controls.
- Phase 5: scene orchestration, PC boot workflow, and sanitized integration health.
- Phase 6: Windows Agent protocol, pairing design, and rich PC/audio/GoXLR mocks.
- Phase 7: separately implemented Windows Agent and stateful PC integrations.
- Phase 8: App Intents, Siri, Shortcuts, Control Center, and system widgets.

Phase 7 has begun with a separate .NET 10 Windows project. It enforces HTTPS and explicit private-interface binding, generates short-lived attempt-limited pairing challenges, stores only credential hashes, supports local and authenticated self-revocation, and defaults Allow Remote Input to off. Its authenticated single-client WebSocket accepts bounded Swift-compatible event batches, rejects sequence replays, calibrates clock offset, coalesces motion, drops stale input safely, and guarantees held-input cleanup. Ordinary keyboard, Unicode, relative pointer, button, and scroll injection uses `SendInput` only on the normal Windows `Default` input desktop.

The iOS production transport now implements HTTPS pairing/security requests, separate live/mock Keychain accounts, authenticated WSS input batches, acknowledgement latency, and connected-session safety polling. The development mock remains selectable. Explicit clipboard transfer and real application/audio/GoXLR endpoints remain future Phase 7 slices.

## 12. Risks and missing information

- Home Assistant URL, version, entity inventory, supported feature flags, and long-lived token are not yet available.
- Actual Govee, Gree, LG webOS, and Tuya entity capabilities depend on their Home Assistant integrations and device models.
- The Smart Life plug boot delay, PC reachability signal, and safe administrative power-off policy need configuration.
- The LG television wake method and remote/entity arrangement are model-specific.
- GoXLR and Windows audio schemas depend on the future Agent protocol.
- HTTP acceptance from Companion cannot prove macro completion without a separate state source.
- Phase 1 mock controls demonstrate lifecycle and layout, but must not be presented as real device state.
