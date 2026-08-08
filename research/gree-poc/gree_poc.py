"""
Gree local-LAN control proof of concept.

This is a throwaway diagnostic, not part of DeckApp. It answers one question:
does this specific Gree AC support real local UDP/7000 read + write control,
independent of any Windows Agent / Home Assistant / cloud plumbing?

Usage (from this directory, with the venv active):

    # 1. Read-only: broadcast discovery only. Safe, changes nothing.
    python gree_poc.py scan

    # 2. Read-only: discovery + bind + one state read. Safe, changes nothing.
    python gree_poc.py state

    # 3. If your network doesn't route broadcast to the AC, target it directly
    #    once you know (or guess) its IP, e.g. from the Huawei mesh app's
    #    client list:
    python gree_poc.py state --host 192.168.3.50

    # 4. Optional control test: nudges target temperature by +/-1C and back.
    #    Only run this once `state` succeeds and the AC is already powered on.
    #    Requires --confirm because it changes real device state.
    python gree_poc.py control --host 192.168.3.50 --confirm
"""

import argparse
import asyncio
import sys

from greeclimate.device import Device
from greeclimate.discovery import Discovery
from greeclimate.deviceinfo import DeviceInfo


async def do_scan(wait_for: int) -> list[DeviceInfo]:
    print(f"Broadcasting Gree discovery packet, waiting {wait_for}s for replies...")
    discovery = Discovery()
    devices = await discovery.scan(wait_for=wait_for)
    if not devices:
        print("No devices replied. This means either:")
        print("  - no Gree AC is reachable in this broadcast domain from this")
        print("    machine (most likely if you're not on the Huawei mesh Wi-Fi), or")
        print("  - the device's local listener is disabled (firmware regression).")
        print("Try again while connected directly to the Huawei mesh SSID, or")
        print("pass --host <ip> to bypass broadcast entirely.")
        return []
    for info in devices:
        print(f"FOUND  ip={info.ip}  mac={info.mac}  name={info.name}"
              f"  brand={info.brand}  model={info.model}")
    return devices


async def resolve_device_info(host: str | None, wait_for: int, mac: str | None) -> DeviceInfo | None:
    if host:
        clean_mac = mac.replace(":", "").replace("-", "").lower() if mac else ""
        print(f"Skipping broadcast; probing {host} directly (unicast), mac={clean_mac or '<unknown>'}...")
        # greeclimate's scan is broadcast-only; for a known host we build the
        # DeviceInfo directly and let bind() do the real unicast handshake.
        # Some units silently ignore a bind whose mac field doesn't match theirs,
        # so pass it through when known.
        return DeviceInfo(ip=host, port=7000, mac=clean_mac, name="manual-target")
    devices = await do_scan(wait_for)
    return devices[0] if devices else None


async def do_state(host: str | None, wait_for: int, mac: str | None) -> None:
    info = await resolve_device_info(host, wait_for, mac)
    if info is None:
        sys.exit(1)

    device = Device(info)
    print(f"Binding to {info.ip} (scan -> bind -> device-specific key exchange)...")
    try:
        await device.bind()
    except Exception as error:  # noqa: BLE001 - PoC, surface everything
        print(f"Bind failed: {error!r}")
        print("If this is a manual --host target, the device may need a fresh")
        print("broadcast scan reply immediately before bind (Gree's handshake")
        print("is documented as only accepting bind right after a scan reply).")
        sys.exit(1)

    print("Bound. Reading live state...")
    await device.update_state()

    print("--- Live state (read-only) ---")
    print(f"  power              : {device.power}")
    print(f"  mode               : {device.mode}")
    print(f"  target_temperature : {device.target_temperature}")
    print(f"  current_temperature: {device.current_temperature}")
    print(f"  fan_speed          : {device.fan_speed}")
    print(f"  vertical_swing     : {device.vertical_swing}")
    print(f"  horizontal_swing   : {device.horizontal_swing}")
    print(f"  raw_properties     : {device.raw_properties}")
    print()
    print("Compare 'power'/'mode'/'target_temperature' against what the")
    print("physical remote or the Gree+ app currently shows. If they match,")
    print("local read access is confirmed for this unit.")


async def do_control(host: str | None, wait_for: int, mac: str | None) -> None:
    info = await resolve_device_info(host, wait_for, mac)
    if info is None:
        sys.exit(1)

    device = Device(info)
    await device.bind()
    await device.update_state()

    if not device.power:
        print("AC currently reports power=OFF. Refusing to run the control test:")
        print("the PoC only nudges target temperature, which is meaningless/")
        print("unverifiable while the unit is off. Turn it on first (with the")
        print("physical remote) and re-run.")
        sys.exit(1)

    original = device.target_temperature
    nudge = original + (1 if original < 30 else -1)
    print(f"Current target_temperature = {original}")
    print(f"Setting target_temperature = {nudge} for ~5s, then restoring...")
    device.target_temperature = nudge
    await device.push_state_update()
    await asyncio.sleep(5)

    await device.update_state()
    print(f"Device now reports target_temperature = {device.target_temperature}")
    if device.target_temperature == nudge:
        print("MATCH - the write was applied and read back. Check the physical")
        print("remote/display now to visually confirm the AC itself changed.")
    else:
        print("MISMATCH - command was sent but device-reported state didn't")
        print("change as expected. Command channel may be write-only/lossy.")

    print(f"Restoring target_temperature = {original}...")
    device.target_temperature = original
    await device.push_state_update()
    print("Done.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_scan = sub.add_parser("scan", help="Broadcast discovery only (read-only, no bind).")
    p_scan.add_argument("--wait", type=int, default=5, help="Seconds to wait for replies.")

    p_state = sub.add_parser("state", help="Discover/target + bind + read live state (read-only).")
    p_state.add_argument("--host", default=None, help="Skip broadcast, target this IP directly.")
    p_state.add_argument("--mac", default=None, help="Device MAC (from router/mesh client list), e.g. 58:0D:0D:C5:F6:6B.")
    p_state.add_argument("--wait", type=int, default=5, help="Seconds to wait for broadcast replies.")

    p_control = sub.add_parser("control", help="Nudge target temperature by 1C and restore it (writes state).")
    p_control.add_argument("--host", default=None, help="Skip broadcast, target this IP directly.")
    p_control.add_argument("--mac", default=None, help="Device MAC (from router/mesh client list).")
    p_control.add_argument("--wait", type=int, default=5, help="Seconds to wait for broadcast replies.")
    p_control.add_argument("--confirm", action="store_true", required=True,
                            help="Required acknowledgement that this changes real device state.")

    args = parser.parse_args()

    if args.command == "scan":
        asyncio.run(do_scan(args.wait))
    elif args.command == "state":
        asyncio.run(do_state(args.host, args.wait, args.mac))
    elif args.command == "control":
        asyncio.run(do_control(args.host, args.wait, args.mac))


if __name__ == "__main__":
    main()
