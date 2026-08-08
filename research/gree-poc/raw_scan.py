"""Minimal raw UDP scan probe, bypassing greeclimate entirely.

Sends the exact same unencrypted {"t":"scan"} packet Gree clients use for
discovery, as a plain unicast datagram to a specific IP:7000, and prints
whatever comes back (or times out). This isolates "does the device answer
UDP/7000 at all" from any cipher/bind logic higher up the stack.
"""

import socket
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.3.89"
PORT = 7000
TIMEOUT = 5

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(TIMEOUT)

payload = b'{"t":"scan"}'
print(f"Sending raw scan packet to {HOST}:{PORT} -> {payload!r}")
sock.sendto(payload, (HOST, PORT))

try:
    data, addr = sock.recvfrom(4096)
    print(f"REPLY from {addr}: {data!r}")
except socket.timeout:
    print(f"No reply within {TIMEOUT}s.")
finally:
    sock.close()
