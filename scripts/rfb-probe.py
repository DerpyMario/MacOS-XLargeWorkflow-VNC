#!/usr/bin/env python3
"""Report which RFB security types the local VNC server is offering.

A viewer that cannot parse Apple's proprietary authentication does not show a
password prompt -- it dies with a protocol error, which looks like a broken
tunnel rather than a wrong auth mode. Listing the offered types on the runner
turns that guess into a fact before anyone tries to connect.

Exit codes: 0 = legacy VNC auth offered, 1 = it is not, 2 = probe failed.
"""

import socket
import sys

NAMES = {
    0: "invalid",
    1: "none",
    2: "VNC password (legacy, understood by every viewer)",
    5: "RA2",
    6: "RA2ne",
    16: "Tight",
    18: "TLS",
    19: "VeNCrypt",
    30: "Apple Diffie-Hellman (RealVNC fails with 'key length too large')",
    33: "Apple RSA-AES",
    35: "Apple RSA-AES-256",
}

LEGACY_VNC_AUTH = 2


def probe(host: str, port: int) -> int:
    with socket.create_connection((host, port), timeout=10) as sock:
        sock.settimeout(10)

        banner = sock.recv(12)
        if not banner.startswith(b"RFB "):
            print(f"not an RFB server, got {banner!r}")
            return 2
        # Apple announces a proprietary 003.889; replying 003.008 pins the
        # handshake to standard RFB 3.8 so we get the full type list back.
        print(f"server banner            : {banner.decode(errors='replace').strip()}")
        sock.sendall(b"RFB 003.008\n")

        head = sock.recv(1)
        if not head:
            print("server closed the connection after version negotiation")
            return 2

        count = head[0]
        if count == 0:
            reason = sock.recv(1024)
            print(f"server refused the handshake: {reason!r}")
            return 2

        types = list(sock.recv(count))

    print("security types offered   : " + ", ".join(str(t) for t in types))
    for t in types:
        print(f"  {t:>3}  {NAMES.get(t, 'unknown')}")

    if LEGACY_VNC_AUTH in types:
        print("legacy VNC auth is available -- cross-platform viewers can connect")
        return 0
    print("legacy VNC auth is NOT offered -- viewers without Apple auth will fail")
    return 1


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5900
    try:
        return probe(host, port)
    except Exception as exc:  # noqa: BLE001 - any failure here is just "no answer"
        print(f"probe failed: {exc}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
