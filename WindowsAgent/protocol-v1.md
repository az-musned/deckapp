# Deck Windows Agent protocol v1

Phase 7 starts with an HTTPS-only request/response foundation. All payloads are JSON, all responses use `Cache-Control: no-store`, request bodies are limited to 16 KiB, and the server accepts only private-network peers.

## Pairing

`POST /api/v1/pairing/start`

```json
{
  "clientDeviceId": "stable-random-app-install-id",
  "deviceName": "Abdulaziz's iPad"
}
```

The response contains `challengeId`, `expiresAt`, and `agentDisplayName`. It never contains the six-digit code. The Agent displays that code locally on Windows.

`POST /api/v1/pairing/confirm`

```json
{
  "challengeId": "uuid",
  "clientDeviceId": "stable-random-app-install-id",
  "code": "123456"
}
```

A successful response contains a paired-device ID, a one-time credential token, and `protocolVersion: 1`. DeckApp must store the token only in Keychain. The Agent stores only its SHA-256 hash. Codes expire after two minutes by default, have a strict attempt limit, and are invalidated after success.

## Authentication

Authenticated requests use `Authorization: Bearer <credential>`. Invalid or revoked credentials receive `401`. Credentials and input payloads must never appear in logs.

`DELETE /api/v1/agent/pairing` authenticates the current client, revokes that paired-device record, and returns `204`. DeckApp deletes the matching Keychain credential after requesting revocation. Windows-local device listing and revocation remain available even if the client is no longer reachable.

## Security state

`GET /api/v1/agent/security` returns:

```json
{
  "remoteInputAllowed": false,
  "emergencyInputDisabled": false,
  "inputInjectionAvailable": false,
  "protocolVersion": 1
}
```

Allow Remote Input is independent from other Agent capabilities. Emergency disable overrides it. Both are Windows-owned state and cannot be enabled remotely by iOS.

## PC capability endpoints

Capability requests require the same paired bearer credential as security and input requests, but they are deliberately independent from `remoteInputAllowed`. This keeps remote-input permission separate from other present and future Agent capabilities.

`GET /api/v1/agent/capabilities` returns current state:

```json
{
  "applications": [
    { "id": "obs", "name": "OBS Studio", "kind": "application", "isRunning": false }
  ],
  "audioSessions": [
    { "id": "audio-opaque-hash", "name": "Spotify", "volume": 0.72, "isMuted": false }
  ],
  "goXlrChannels": [
    { "id": "mic", "name": "Mic", "level": 0.64, "isMuted": false }
  ],
  "goXlrConnected": true,
  "protocolVersion": 1
}
```

Application IDs and paths originate only from the Windows-local allowlist. Audio IDs are opaque hashes scoped to the current Windows audio session. GoXLR IDs are normalized channel names such as `mic`, `game`, `chat`, `music`, and `system`. Volume and level values are finite numbers from 0 through 1.

`POST /api/v1/agent/commands` accepts exactly one of these command shapes:

```json
{ "command": "launchApplication", "id": "obs" }
{ "command": "setAudioVolume", "id": "audio-opaque-hash", "value": 0.5 }
{ "command": "setAudioMuted", "id": "audio-opaque-hash", "muted": true }
{ "command": "setGoXlrLevel", "id": "music", "value": 0.6 }
{ "command": "setGoXlrMuted", "id": "mic", "muted": true }
```

Command names are case-sensitive. The spelling is `GoXlr` on the JSON wire even though the iOS domain model uses `GoXLR`. Commands are serialized server-side. A `200` response contains `confirmed`, `message`, a fresh `snapshot`, and `protocolVersion`. The client must treat the operation as successful only when `confirmed` is true and the returned snapshot matches the requested state; accepting the HTTP request alone is not confirmation. `409` means the requested target or capability is unavailable or invalid. `401` means the credential is missing, invalid, or revoked.

The Agent cannot receive an executable path or arguments from the network. It does not start the GoXLR Utility daemon or switch device managers. It never logs full command bodies, typed text, credentials, or audio payloads.

## Input endpoint

Connect a WebSocket to `wss://<private-agent-address>:8732/api/v1/agent/input` with the bearer credential. Only one input session is accepted. The server replies with a `ready` message containing `sessionId`, `protocolVersion`, and `serverTimestampMilliseconds`.

Each client message is bounded to 16 KiB and contains at most 64 Swift-compatible events:

```json
{
  "protocolVersion": 1,
  "events": [
    {
      "id": "uuid",
      "sequence": 1,
      "timestampMilliseconds": 1785776400000,
      "payload": {
        "relativePointer": {
          "deltaX": 3.5,
          "deltaY": -1.0,
          "acceleration": true,
          "precision": false
        }
      }
    }
  ]
}
```

The Agent calibrates client/server clock offset per session, rejects replayed sequence numbers, coalesces adjacent motion, drops pointer/scroll events older than 100 ms, and drops non-release discrete events older than two seconds. Release events remain eligible so delayed packets cannot leave controls stuck. The reply contains `lastAcceptedSequence`, applied/dropped counts, status, and server timestamp for latency measurement.

Supported inputs are relative motion, vertical/horizontal scrolling, left/right/middle buttons, virtual/control/function/media keys, modifiers, and Unicode text. Clipboard messages are recognized but deliberately rejected until the explicit clipboard implementation is added.

The WebSocket closes and all held input is released whenever Windows disables input, emergency disable is activated, the client disconnects, a protocol error occurs, or `SendInput` is rejected. The Agent also verifies that the active Windows input desktop is `Default`; it never attempts to switch desktops or bypass Windows security boundaries.
