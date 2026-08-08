"""
Gree cloud MQTT control PoC - sets target temperature and fan speed for real
(no revert). Confirms the write landed by re-querying state afterward.

Run gree_cloud_login.py and gree_cloud_mqtt.py first to confirm read access
works before trusting this.
"""

import json
import random
import ssl
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt

import gree_cloud_login as cloud
from gree_cloud_mqtt import MQTT_HOSTS, STATUS_COLS, device_cipher_decrypt, device_cipher_encrypt

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TARGET_TEMP = 23
FAN_LOWEST = 1  # Gree WdSpd: 0=Auto, 1=Low, 2=Med-Low, 3=Med, 4=Med-High, 5=High


def main() -> None:
    here = Path(__file__).parent
    device_info = json.loads((here / "gree_cloud_device.json").read_text())
    creds = json.loads((here / "gree_cloud_credentials.json").read_text())
    region = device_info["region"]
    target = min(device_info["devices"], key=lambda d: len(d.get("mac", "")))
    parent_mac, device_key = target["mac"], target["key"]
    print(f"Target device: {target.get('name')!r} mac={parent_mac}")

    base_url = cloud.SERVERS[region]
    auth = cloud.login(base_url, creds["email"], creds["password"])
    if auth is None:
        print("Login failed.")
        return
    uid, token = auth["uid"], auth["token"]
    print(f"Login OK, uid={uid}")

    host = MQTT_HOSTS[region]
    client_id = f"app_{random.getrandbits(64):016x}"
    client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)
    client.username_pw_set(str(uid), token)

    states = []

    def on_connect(c, userdata, flags, rc, properties=None):
        print(f"MQTT connected, rc={rc}")
        for topic in (f"response/{parent_mac}/#", f"status/{parent_mac}/#", f"connect/{parent_mac}"):
            c.subscribe(topic, qos=1)

    def on_message(c, userdata, msg):
        try:
            outer = json.loads(msg.payload)
            if "pack" not in outer:
                return
            inner = device_cipher_decrypt(device_key, outer["pack"])
        except Exception:
            return
        if inner.get("t") == "dat" and "cols" in inner and "dat" in inner:
            state = dict(zip(inner["cols"], inner["dat"]))
            print(f"  state update on {msg.topic}: SetTem={state.get('SetTem')} WdSpd={state.get('WdSpd')} Pow={state.get('Pow')}")
            states.append(state)

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    client.tls_set_context(ctx)
    client.on_connect = on_connect
    client.on_message = on_message

    print(f"Connecting to {host}:1984 (TLS)...")
    client.connect(host, 1984, keepalive=60)
    client.loop_start()
    time.sleep(2)

    def send(pack_obj: dict) -> None:
        pack = device_cipher_encrypt(device_key, pack_obj)
        request = {
            "cid": str(random.randint(1000000000, 9999999999)),
            "i": 0, "pack": pack, "t": "pack",
            "tcid": parent_mac, "uid": uid,
        }
        client.publish(f"request/{parent_mac}", json.dumps(request), qos=1)

    print(f"Setting SetTem={TARGET_TEMP}...")
    send({"t": "cmd", "opt": ["SetTem"], "p": [TARGET_TEMP]})
    time.sleep(2)

    print(f"Setting WdSpd={FAN_LOWEST} (lowest)...")
    send({"t": "cmd", "opt": ["WdSpd"], "p": [FAN_LOWEST]})
    time.sleep(2)

    print("Re-querying status to confirm...")
    send({"t": "status", "cols": STATUS_COLS})
    time.sleep(5)

    client.loop_stop()
    client.disconnect()

    if not states:
        print("No state confirmation received - commands were sent but we")
        print("couldn't verify they applied. Check the physical unit/remote.")
        return

    final = states[-1]
    print()
    print(f"Final confirmed state: SetTem={final.get('SetTem')}  WdSpd={final.get('WdSpd')}  Pow={final.get('Pow')}")
    temp_ok = final.get("SetTem") == TARGET_TEMP
    fan_ok = final.get("WdSpd") == FAN_LOWEST
    print(f"Temperature set to {TARGET_TEMP}: {'CONFIRMED' if temp_ok else 'NOT CONFIRMED'}")
    print(f"Fan set to lowest ({FAN_LOWEST}): {'CONFIRMED' if fan_ok else 'NOT CONFIRMED'}")
    print()
    print("Please also check the physical unit/remote display to visually confirm.")


if __name__ == "__main__":
    main()
