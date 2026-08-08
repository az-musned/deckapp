"""
Gree cloud MQTT live-state PoC - Stage 2 of 2.

Requires gree_cloud_login.py to have run successfully first (produces
gree_cloud_device.json with the device's mac/key, and needs
gree_cloud_credentials.json for a fresh login token here).

This is read-only: it logs in, connects to Gree's regional MQTT broker,
subscribes to the device's status/response topics, publishes a single
"status" query, and prints whatever comes back (or times out). No control
commands are sent. Protocol details here are reverse-engineered from a
single source (a community fork) and are less certain than the cloud
login flow that already worked - expect to iterate.
"""

import base64
import json
import random
import ssl
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

import gree_cloud_login as cloud

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

MQTT_HOSTS = {
    "North American": "mqtt-us.gree.com",
    "Europe": "mqtt-eu.gree.com",
    "East South Asia": "mqtt-as.gree.com",
    "India": "mqtt-in.gree.com",
    "Latin American": "mqtt-la.gree.com",
    "Middle East": "mqtt-me.gree.com",
    "Russia": "mqtt-ru.gree.com",
    "South American": "mqtt-sa.gree.com",
    "Australia": "mqtt-au.gree.com",
    "China Mainland": "mqtt-cn.gree.com",
}

STATUS_COLS = [
    "Pow", "Mod", "Dwet", "DwatSen", "Dfltr", "DwatFul", "Dmod", "SetTem",
    "TemSen", "TemUn", "TemRec", "WdSpd", "Air", "Blo", "Health", "SwhSlp",
    "SlpMod", "Lig", "SwingLfRig", "SwUpDn", "Quiet", "Tur", "StHt", "SvSt",
    "HeatCoolType",
]


def device_cipher_encrypt(key: str, data: dict) -> str:
    raw = json.dumps(data).encode("utf-8")
    cipher = AES.new(key.encode("utf-8"), AES.MODE_ECB)
    return base64.b64encode(cipher.encrypt(pad(raw, 16))).decode("ascii")


def device_cipher_decrypt(key: str, b64_ciphertext: str) -> dict:
    raw = base64.b64decode(b64_ciphertext)
    cipher = AES.new(key.encode("utf-8"), AES.MODE_ECB)
    plain = cipher.decrypt(raw)
    try:
        plain = unpad(plain, 16)
    except ValueError:
        pass
    text = plain.decode("utf-8", errors="replace")
    end = text.rfind("}")
    if end != -1:
        text = text[: end + 1]
    return json.loads(text)


def main() -> None:
    here = Path(__file__).parent
    device_info_path = here / "gree_cloud_device.json"
    creds_path = here / "gree_cloud_credentials.json"
    if not device_info_path.exists():
        print("Run gree_cloud_login.py successfully first.")
        return

    device_info = json.loads(device_info_path.read_text())
    region = device_info["region"]
    devices = device_info["devices"]

    # Prefer the parent device (mac not ending in synthetic "00" child suffix
    # unless that's the only entry) - match by shortest mac for this AC.
    target = min(devices, key=lambda d: len(d.get("mac", "")))
    parent_mac = target["mac"]
    device_key = target["key"]
    print(f"Target device: name={target.get('name')!r} mac={parent_mac}")

    creds = json.loads(creds_path.read_text())
    base_url = cloud.SERVERS[region]
    print(f"Logging in against '{region}' ({base_url}) for a fresh token...")
    auth = cloud.login(base_url, creds["email"], creds["password"])
    if auth is None:
        print("Login failed - credentials may have changed, or token flow needs rework.")
        return
    uid, token = auth["uid"], auth["token"]
    print(f"Login OK, uid={uid}")

    host = MQTT_HOSTS[region]
    client_id = f"app_{random.getrandbits(64):016x}"
    print(f"Connecting to MQTT broker {host} as client_id={client_id}...")

    received = []

    def on_connect(client, userdata, flags, rc, properties=None):
        print(f"MQTT connected, rc={rc}")
        for topic in (f"response/{parent_mac}/#", f"status/{parent_mac}/#", f"connect/{parent_mac}"):
            client.subscribe(topic, qos=1)
            print(f"  subscribed to {topic}")

    def on_message(client, userdata, msg):
        print(f"MQTT message on {msg.topic}: {msg.payload[:200]!r}")
        try:
            outer = json.loads(msg.payload)
        except ValueError:
            print("  (not JSON, skipping)")
            return
        if "pack" not in outer:
            print(f"  no 'pack' field, raw outer={outer}")
            return
        try:
            inner = device_cipher_decrypt(device_key, outer["pack"])
        except Exception as error:  # noqa: BLE001 - PoC, surface everything
            print(f"  decrypt failed: {error!r}")
            return
        print(f"  decrypted: {inner}")
        if inner.get("t") == "dat" and "cols" in inner and "dat" in inner:
            state = dict(zip(inner["cols"], inner["dat"]))
            print(f"  STATE: {state}")
            received.append(state)

    def on_disconnect(client, userdata, rc, properties=None):
        print(f"MQTT disconnected, rc={rc}")

    def on_log(client, userdata, level, buf):
        pass  # quiet by default; flip to print(buf) for deep debugging

    for port, use_tls in ((1984, True), (8883, True), (1883, False)):
        print(f"--- Attempt: port {port}, tls={use_tls} ---")
        client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)
        client.username_pw_set(str(uid), token)
        client.on_connect = on_connect
        client.on_message = on_message
        client.on_disconnect = on_disconnect
        client.on_log = on_log
        if use_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            client.tls_set_context(ctx)

        try:
            client.connect(host, port, keepalive=60)
        except Exception as error:  # noqa: BLE001 - PoC, surface everything
            print(f"  connect() raised: {error!r}")
            continue

        client.loop_start()
        time.sleep(2)  # let CONNACK land + subscriptions register

        cid = str(random.randint(1000000000, 9999999999))
        pack = device_cipher_encrypt(device_key, {"t": "status", "cols": STATUS_COLS})
        request = {
            "cid": cid, "i": 0, "pack": pack, "t": "pack",
            "tcid": parent_mac, "uid": uid,
        }
        topic = f"request/{parent_mac}"
        print(f"  publishing status query to {topic}")
        client.publish(topic, json.dumps(request), qos=1)

        time.sleep(6)  # wait for a reply
        client.loop_stop()
        client.disconnect()

        if received:
            print()
            print("SUCCESS: got live state back over cloud MQTT:")
            print(received[-1])
            return
        print("  no state received on this port/tls combination, trying next...")

    print()
    print("No live state received on any port. Either the topic/payload shape")
    print("needs adjustment, the broker requires a different handshake, or this")
    print("account/device combination doesn't support MQTT push in this region.")


if __name__ == "__main__":
    main()
