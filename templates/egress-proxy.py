#!/usr/bin/env python3
"""hgt egress-proxy — CONNECT-only forward proxy, allowlisted by hostname (issue #74, ADR 0006).

Runs on the host, outside the bwrap jail. The jailed Claude session is pointed at it via
HTTPS_PROXY/HTTP_PROXY; a host-side nftables rule (templates/nftables/hgt-egress.nft) confines
the jail's cgroup to reach only this proxy's port, so it's the only way out. This proxy relays
CONNECT tunnels to an explicit set of allowed hosts (the Anthropic API + the git remote) and
refuses everything else. It never terminates TLS — it reads the plaintext CONNECT line, checks
the target host, then splices raw bytes end-to-end, so it never sees headers, bodies, or the
credential inside the tunnel.

usage: egress-proxy.py <port> <allowed-host> [<allowed-host> ...]
"""
import socket
import sys
import threading

MAX_HEADER = 16384


def relay(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(conn, allowed):
    with conn:
        conn.settimeout(10)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
            if len(buf) > MAX_HEADER:
                return  # refuse rather than buffer an unbounded header

        head = buf.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = head.split()
        if len(parts) != 3 or parts[0] != "CONNECT":
            conn.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return

        target = parts[1]
        host, _, port_str = target.rpartition(":")
        if not host:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        if host not in allowed:
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            return

        try:
            port = int(port_str) if port_str else 443
            upstream = socket.create_connection((host, port), timeout=10)
        except (OSError, ValueError):
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return

        with upstream:
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            conn.settimeout(None)
            upstream.settimeout(None)
            t = threading.Thread(target=relay, args=(conn, upstream), daemon=True)
            t.start()
            relay(upstream, conn)
            t.join()


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    port = int(sys.argv[1])
    allowed = set(sys.argv[2:])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(64)
    print(
        f"hgt egress-proxy: listening on 127.0.0.1:{port}, allow={sorted(allowed)}",
        file=sys.stderr,
    )
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, allowed), daemon=True).start()


if __name__ == "__main__":
    main()
