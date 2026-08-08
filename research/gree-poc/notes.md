# Proven Gree protocol details

Extracted from a working session against a real account/device. Everything
here was actually exercised by the scripts in this directory, not just read
from source — treat it as verified, not reverse-engineered-but-untested.

## Local LAN (UDP/7000) — confirmed dead for this unit

Standard Gree scan → bind → control flow on UDP/7000, AES-ECB ("V1") with
fallback to AES-GCM ("V2"). For this specific AC (firmware
`U-WB04BRT13V1.44`), broadcast scan, unicast bind (both ciphers), and a bare
unencrypted probe all got zero response — verified across a clean network
path (correct subnet, correct firewall rules, no AP/client isolation, both
immediately after a power-cycle and after a full Gree+ re-provision). Not a
network problem — the device's local listener simply doesn't answer. Kept
as a code path for other Gree units; not relevant to this one.

## Cloud (proven working end to end)

### Login

Regional servers, try in order until one accepts the credentials:

```
North American   https://nagrih.gree.com
Europe            https://eugrih.gree.com
East South Asia   https://hkgrih.gree.com
India             https://ingrih.gree.com
Latin American    https://lagrih.gree.com
Middle East       https://megrih.gree.com
Russia            https://rugrih.gree.com
South American    https://sagrih.gree.com
Australia         https://augrih.gree.com
China Mainland    https://grih.gree.com
```

`POST /App/UserLoginV2`

Constants: `appId = "4920681951525131286"`, `appHash = "0fa513124aa97781d1f3f40d61ca1a89"`.
Envelope AES key (AES-128-ECB, PKCS7 padding): `"#G$&^jgfujy6ujxt"`.

Password hash:
```
pwMd5 = md5(password)
h     = md5(pwMd5 + password)
psw   = md5(h + t)          # t = UTC "yyyy-MM-dd HH:mm:ss"
```

Envelope (JSON → AES-ECB encrypt → base64 → raw POST body; headers
`Content-Type: application/x-www-form-urlencoded`, `Gaen1: 5ac2bdf935bcca70`,
`Charset: utf-8`):

```json
{
  "api": {
    "appId": "<appId>", "r": "<unix ts>", "t": "<t>",
    "vc": "md5(appId_appHash_t_r)"
  },
  "datVc": "md5(appHash_user_psw_t)",
  "psw": "<psw>", "t": "<t>", "user": "<email>"
}
```

Response: `{"enRes": "<base64>"}` — base64-decode, AES-ECB-decrypt with the
same envelope key, strip trailing bytes after the final `}`, parse JSON.
Success: contains `uid` and `token` (possibly nested under `data`). Failure:
`{"r": 411, "msg": "The password is incorrect or the user does not exist."}`
(or similar non-200 `r`).

### Device lookup

Same envelope/auth pattern, using the `uid`/`token` from login.

```
POST /App/GetHomes
  body: {"token": token, "uid": uid}
  datVc hash_props order: [token, uid]
  -> data.home = [{id, name, ...}]

POST /App/GetDevsInRoomsOfHomeV2
  body: {"token": token, "homeId": id, "uid": uid}
  datVc hash_props order: [token, uid, homeId]
  -> data.rooms[].devs[] each {name, mac, key, ...}
```

`key` is the device's own AES key, used for the MQTT `pack` cipher below.
A device may appear twice: a parent entry (e.g. `mac: "580d0dc5f66b"`) and a
synthetic child entry with a `"00"` suffix (`"580d0dc5f66b00"`) — use the
parent (shorter MAC) for MQTT topics.

### MQTT

Host: `mqtt-<region-code>.gree.com` (region codes: `us`, `eu`, `as`, `in`,
`la`, `me`, `ru`, `sa`, `au`, `cn` — matching the login region). Port `1984`,
TLS with certificate verification disabled (required against Gree's real
broker — verified working, not a shortcut). MQTT v3.1.1, clean session.
`username = str(uid)`, `password = token`, client id = `"app_" + random hex`.

Subscribe (parent MAC, lowercase, no colons), all QoS 1:
```
response/<mac>/#
status/<mac>/#
connect/<mac>
```

Publish commands to `request/<mac>`.

Outer envelope for a publish:
```json
{
  "cid": "<random 10-digit string>",
  "i": 0,
  "pack": "<base64 AES-ECB ciphertext, device key>",
  "t": "pack",
  "tcid": "<parent mac>",
  "uid": "<uid>"
}
```

Inner payload, status query:
```json
{
  "t": "status",
  "cols": ["Pow","Mod","Dwet","DwatSen","Dfltr","DwatFul","Dmod","SetTem",
           "TemSen","TemUn","TemRec","WdSpd","Air","Blo","Health","SwhSlp",
           "SlpMod","Lig","SwingLfRig","SwUpDn","Quiet","Tur","StHt","SvSt",
           "HeatCoolType"]
}
```

Inner payload, command:
```json
{"t": "cmd", "opt": ["SetTem"], "p": [23]}
{"t": "cmd", "opt": ["WdSpd"], "p": [1]}
```

Inbound `status/`/`response/` messages decrypt (same per-device AES-ECB
key) to `{"t":"dat","cols":[...],"dat":[...]}` — zip `cols`/`dat` into a
property dictionary. Unsolicited pushes also arrive on `connect`/`status`
topics without a prior query.

### Property meanings (confirmed against the real device)

| Property | Meaning | Confirmed values |
|---|---|---|
| `Pow` | Power | 0/1 |
| `Mod` | HVAC mode | 1 = cool (confirmed live); Gree's general table: 0 auto, 1 cool, 2 dry, 3 fan, 4 heat |
| `SetTem` | Target temperature | Plain Celsius integer, no offset (`SetTem=23` → 23°C on the unit, confirmed by writing and visually checking) |
| `WdSpd` | Fan speed | 0 auto, 1 low, 2 med-low, 3 med, 4 med-high, 5 high (1 confirmed as "lowest" against the physical remote) |
| `SwUpDn` | Vertical swing | — |
| `SwingLfRig` | Horizontal swing | — |
| `Lig` | Display light | — |

Current room temperature was observed once on an unsolicited `connect`-topic
push (a much longer property set than the status query above, including
fields like `InTem`) but wasn't exercised as a routinely-polled field —
verify it updates live before wiring it into UI, and don't assume any
offset convention without checking a live read against the physical
display.
