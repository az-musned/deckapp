# GoXLR live audio meters

DeckApp treats the configured GoXLR fader level and the live Windows audio signal as separate values. A channel can have a 100% fader and a zero meter when no audio is passing through its mapped endpoint.

The app opens one lower-priority authenticated WebSocket per active Agent at `wss://<agent>/api/v1/audio/meters/ws`. It sends the same Bearer pairing credential used by other Agent APIs and relies on the existing strict TLS trust configuration. Mouse and keyboard events remain on their dedicated high-priority input socket.

Expected messages have `type: "audio.meters"`, an increasing `sequence`, a Unix-millisecond `timestamp`, and channel entries containing `id`, optional `endpointId`, `available`, `linearPeak`, `decibels`, `displayLevel`, `peakHold`, and `clipping`. Reordered frames are dropped. Sequence tracking resets after every reconnect so an Agent restart can begin again at zero.

Endpoint configuration uses:

- `GET /api/v1/audio/endpoints`
- `GET /api/v1/audio/channels`
- `PUT /api/v1/audio/channels/{channelId}/mapping` with `{ "endpointId": "..." }`

Only mapping configuration is retained by the Agent. Meter frames are never written to SwiftData, UserDefaults, analytics, or logs.

If no frame arrives for about one second, DeckApp marks the stream stale and decays each visible bar. After about four seconds, it has returned to zero; GoXLR control availability remains separate. The socket reconnects with bounded exponential backoff, stops in the background, and resumes when a visible mixer consumer returns to the foreground.

To test, play audio through each mapped Windows render endpoint and speak into mapped capture endpoints. The meter should move only for the endpoint carrying signal, while fader and mute commands continue to use the existing capability API. Windows endpoint peak meters can differ from the physical GoXLR LED meters because they may measure at a different point in the signal path.
