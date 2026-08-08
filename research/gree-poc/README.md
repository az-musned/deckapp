# Gree AC integration — proof-of-concept scripts

These scripts proved out real bidirectional control of the Gree AC before
porting the protocol into DeckApp. Kept here as the ground-truth reference
for that port (see `research/gree-poc/notes.md` for the exact results).

**Local LAN control (UDP/7000) is confirmed dead for this specific unit**
(firmware `U-WB04BRT13V1.44`) — network path was fully verified clean, so
this isn't a discovery/firewall problem, the device's local listener simply
never answers. **Gree's cloud API is confirmed working** — login, live state
read, and real writes (`SetTem`, `WdSpd`) all succeeded and were verified
against the physical unit.

## Files

- `gree_poc.py` — local LAN diagnostic (`scan` / `state` / `control`
  subcommands, via the `greeclimate` PyPI package). Read-only unless you
  pass `control --confirm`.
- `raw_scan.py` — minimal raw unicast UDP probe, bypasses `greeclimate`
  entirely, used to rule out cipher/bind-logic issues during diagnosis.
- `gree_cloud_login.py` — cloud login + home/device lookup (read-only).
  Tries Gree's ~10 regional servers until one accepts the credentials.
- `gree_cloud_mqtt.py` — cloud MQTT live state read (read-only), using the
  device info/key `gree_cloud_login.py` discovers.
- `gree_cloud_set.py` — cloud MQTT control (writes real state — sets
  target temperature and fan speed, no revert).

## Running

```bash
python -m venv .venv
.venv/Scripts/activate   # or .venv/bin/activate on macOS/Linux
pip install greeclimate pycryptodome paho-mqtt requests

cp gree_cloud_credentials.json.template gree_cloud_credentials.json
# edit gree_cloud_credentials.json with your real Gree+ email/password —
# this file is gitignored, never commit it

python gree_cloud_login.py   # writes gree_cloud_device.json (gitignored)
python gree_cloud_mqtt.py
python gree_cloud_set.py
```

`gree_cloud_credentials.json` and `gree_cloud_device.json` are both
gitignored — the former holds your real account password, the latter holds
your AC's per-device AES key. Never commit either.

## Why this matters for the Swift port

The full protocol details (exact endpoints, envelope format, MQTT topics,
cipher, property names) are written up in `notes.md` in this directory —
that's what a from-scratch reimplementation (e.g. in Swift) should follow,
cross-checked against this working Python implementation if anything
doesn't match.
