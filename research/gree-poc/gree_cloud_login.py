"""
Gree cloud login + device lookup PoC — Stage 1 of 2.

Local LAN control (UDP/7000) is confirmed dead for this specific AC after
extensive testing. This tests the alternative: Gree's cloud REST API,
reverse-engineered from davo22/greeclimate and cross-checked against
luc10/gree-api-client (both repos implement this login flow identically).

This stage only logs in and looks up the device + its per-device AES key.
It makes no MQTT connection and sends no control commands - read-only
against Gree's account API.

Credentials are read from gree_cloud_credentials.json (gitignored, next to
this script) - never pasted into chat. Copy the .template file and fill it
in before running.
"""

import base64
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import requests
from Crypto.Cipher import AES

APP_ID = "4920681951525131286"
APP_HASH = "0fa513124aa97781d1f3f40d61ca1a89"
AES_KEY = b"#G$&^jgfujy6ujxt"

SERVERS = {
    "North American": "https://nagrih.gree.com",
    "Europe": "https://eugrih.gree.com",
    "East South Asia": "https://hkgrih.gree.com",
    "India": "https://ingrih.gree.com",
    "Latin American": "https://lagrih.gree.com",
    "Middle East": "https://megrih.gree.com",
    "Russia": "https://rugrih.gree.com",
    "South American": "https://sagrih.gree.com",
    "Australia": "https://augrih.gree.com",
    "China Mainland": "https://grih.gree.com",
}


def md5hex(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def aes_encrypt(plaintext: str) -> str:
    data = plaintext.encode("utf-8")
    pad_len = 16 - (len(data) % 16)
    data += bytes([pad_len]) * pad_len
    cipher = AES.new(AES_KEY, AES.MODE_ECB)
    return base64.b64encode(cipher.encrypt(data)).decode("ascii")


def aes_decrypt(b64_ciphertext: str) -> dict:
    raw = base64.b64decode(b64_ciphertext)
    cipher = AES.new(AES_KEY, AES.MODE_ECB)
    plain = cipher.decrypt(raw)
    plain = plain.rstrip(bytes(range(1, 17)))  # strip PKCS7 padding
    text = plain.decode("utf-8", errors="replace")
    # defend against trailing padding remnants after the final brace
    end = text.rfind("}")
    if end != -1:
        text = text[: end + 1]
    return json.loads(text)


def build_envelope(payload: dict, hash_props: list[str]) -> dict:
    r = int(time.time())
    t = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    vc = md5hex(f"{APP_ID}_{APP_HASH}_{t}_{r}")
    values = "_".join(str(payload.get(k, t if k == "t" else "")) for k in hash_props)
    dat_vc = md5hex(f"{APP_HASH}_{values}")
    envelope = {"api": {"appId": APP_ID, "r": r, "t": t, "vc": vc}, "datVc": dat_vc}
    envelope.update(payload)
    return envelope, t


def call(base_url: str, path: str, payload: dict, hash_props: list[str]) -> dict:
    envelope, t = build_envelope(payload, hash_props)
    envelope["t"] = t if "t" in hash_props and "t" not in payload else envelope.get("t", t)
    body = aes_encrypt(json.dumps(envelope))
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Gaen1": "5ac2bdf935bcca70",
        "Charset": "utf-8",
    }
    resp = requests.post(f"{base_url}{path}", data=body, headers=headers, timeout=10)
    print(f"    HTTP {resp.status_code} from {base_url}{path}")
    try:
        outer = resp.json()
    except ValueError:
        print(f"    Non-JSON response: {resp.text[:300]!r}")
        return {"r": -1, "msg": "non-json response"}
    if "enRes" not in outer:
        print(f"    Unexpected response shape: {outer}")
        return outer
    decrypted = aes_decrypt(outer["enRes"])
    return decrypted


def login(base_url: str, email: str, password: str) -> dict | None:
    t_now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    pw_md5 = md5hex(password)
    h = md5hex(pw_md5 + password)
    psw = md5hex(h + t_now)
    payload = {"psw": psw, "t": t_now, "user": email}
    result = call(base_url, "/App/UserLoginV2", payload, ["user", "psw", "t"])
    data = result.get("data", result)
    if result.get("r") not in (None, 200) or "token" not in data:
        print(f"    Login rejected: {result}")
        return None
    return data


def get_homes(base_url: str, uid, token: str) -> list[dict]:
    result = call(base_url, "/App/GetHomes", {"token": token, "uid": uid}, ["token", "uid"])
    data = result.get("data", result)
    return data.get("home", [])


def get_devices(base_url: str, uid, token: str, home_id) -> list[dict]:
    payload = {"token": token, "homeId": home_id, "uid": uid}
    result = call(base_url, "/App/GetDevsInRoomsOfHomeV2", payload, ["token", "uid", "homeId"])
    data = result.get("data", result)
    devices = []
    for room in data.get("rooms", []):
        devices.extend(room.get("devs", []))
    return devices


def main() -> None:
    creds_path = Path(__file__).parent / "gree_cloud_credentials.json"
    if not creds_path.exists():
        print(f"Missing {creds_path}. Copy the .template file next to it and fill in your")
        print("Gree+ account email/password (this file stays local, never sent to me).")
        return
    creds = json.loads(creds_path.read_text())
    email, password = creds["email"], creds["password"]

    for region, base_url in SERVERS.items():
        print(f"Trying region '{region}' ({base_url})...")
        try:
            auth = login(base_url, email, password)
        except requests.RequestException as error:
            print(f"    Network error: {error}")
            continue
        if auth is None:
            continue

        print(f"LOGIN OK on '{region}'. uid={auth.get('uid')}")
        uid, token = auth["uid"], auth["token"]

        homes = get_homes(base_url, uid, token)
        print(f"Homes: {homes}")
        if not homes:
            print("No homes returned; stopping here.")
            return

        found = []
        for home in homes:
            devices = get_devices(base_url, uid, token, home["id"])
            print(f"Home '{home.get('name')}' devices:")
            for dev in devices:
                masked_key = (dev.get("key", "")[:4] + "...") if dev.get("key") else None
                print(f"  name={dev.get('name')} mac={dev.get('mac')} key={masked_key}")
                found.append(dev)
        print()
        print("SUCCESS: cloud login + device lookup works.")

        out_path = Path(__file__).parent / "gree_cloud_device.json"
        out_path.write_text(json.dumps({"region": region, "devices": found}, indent=2))
        print(f"Saved region + device list (including full keys, local only) to {out_path.name}")
        print("for stage 2 (MQTT live state) to read - not printed here in full.")
        return

    print("No region accepted these credentials. Either the account/password is")
    print("wrong, or Gree uses a region server not in this list.")


if __name__ == "__main__":
    main()
