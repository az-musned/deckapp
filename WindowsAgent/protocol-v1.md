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
