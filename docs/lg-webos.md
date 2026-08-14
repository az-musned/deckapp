# LG webOS local control

DeckApp can control supported LG webOS televisions directly on the same private network. It does not require Home Assistant or the Windows Agent for this integration.

## Setup

1. Put the iPhone or iPad and TV on the same main Wi-Fi/LAN. Guest networks and mesh client-isolation modes can block discovery and control.
2. In DeckApp, open **Settings → Direct Local TV Control**.
3. Use **Discover TVs**, or enter the TV's local IP address manually. Manual setup is always available because SSDP is not forwarded by every router or mesh.
4. Tap **Add and Pair** or select a discovered TV, then accept the connection prompt displayed on the television.
5. For power-on, add the television's wired or wireless MAC address and enable the TV's mobile/Wake-on-LAN standby option. Wake-on-LAN availability varies by model and TV power settings.
6. In the dashboard editor, configure a Television widget and choose the saved LG webOS TV as its source.

Each television has a stable DeckApp device ID. The client pairing key is stored under that ID in iOS Keychain. Names, addresses, model labels, MAC addresses, and the selected device ID are persisted; live volume, mute, app, input, and connection state are intentionally transient.

## Network and security behavior

- Port 3000 uses the television's normal local `ws://` SSAP endpoint. It is the compatibility default and must only be used on a trusted private LAN.
- Port 3001 uses `wss://`. Many TVs present an LG private-chain certificate that identifies the TV product rather than its changing private IP address. DeckApp validates the LG certificate chain and validity dates, pins the leaf certificate after the first approved pairing, and restricts the exception to that exact saved TV endpoint. A changed certificate is rejected until the TV is removed and paired again. This trust-on-first-use tradeoff does not modify global trust and does not affect Home Assistant, Govee, Companion, or Windows Agent sessions.
- No pairing key, request payload, or TV state is logged. Removing a saved TV deletes its Keychain client key.
- When a saved key is rejected, DeckApp deletes only that TV's stale key and starts explicit TV confirmation again.
- Unexpected socket closure uses bounded exponential reconnection while the app is active. Connections are closed while the app is inactive.

Because LG does not publish SSAP as a supported public consumer API, compatibility may differ between webOS releases. DeckApp keeps all URIs and payload encoding in the typed LG protocol layer so model-specific adjustments remain isolated.

## Recovery

- **Discovery finds nothing:** confirm both devices are on the same non-guest LAN, disable AP/client isolation, or enter the IP manually.
- **Pairing prompt never appears:** confirm the TV's mobile-app/remote-control setting is enabled, remove DeckApp from the TV's previously connected devices if present, then reconnect.
- **Paired TV rejects commands:** remove and re-add that TV to force a clean pairing key.
- **Power-on fails:** enable **TV On With Mobile → Turn On via Wi-Fi**, verify the MAC address, and confirm broadcast traffic is allowed on the local segment. DeckApp sends Wake-on-LAN to both the TV's directed `/24` broadcast and the global broadcast on UDP ports 9 and 7. Power-off uses the live connection; power-on uses Wake-on-LAN.
- **Secure connection fails:** remove and re-add the TV if its certificate legitimately changed after a TV repair or factory reset. Use compatibility port 3000 only when the TV exposes it and only on a trusted LAN.
