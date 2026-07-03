#!/usr/bin/env python3
"""egress_proxy.py — host-side allowlist forward proxy for the `restricted` egress profile.

The VM's nwfilter drops all direct egress (and DNS) except TCP to this proxy, and the VM is
configured with HTTP(S)_PROXY pointing here. The proxy resolves + allowlists by hostname, so
the VM never does its own DNS and can only reach allowlisted domains (pip / git / your provider).

This is a *soft* control: an allowed domain (e.g. a git push to github) can still be an exfil
channel. It satisfies the "private repo, opt-in restriction" intent — not a hard exfil
guarantee (PLAN.md security model). It is also the foundation the a build phase key-off-VM proxy
builds on (later: inject the your provider auth header here so the key never enters the VM).

Allowlist match is suffix-based: an entry `pythonhosted.org` matches `files.pythonhosted.org`.
Plain entries are pinned to port 443 (CONNECT) / 80 (absolute-form http) and must resolve to
public addresses — the name is resolved once and the connection goes to the resolved address, so
an allowed name can never be repointed (DNS rebind) at the host or the LAN, and the proxy is not
an arbitrary-port relay. An entry WITH a port (`localhost:1234` — the local-LLM upstream from
LLM_BASE_URL) is an exact host:port exception that bypasses both checks, for that pair only.
"""
import argparse
import ipaddress
import select
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ALLOW = set()        # bare hostnames — suffix match, port-pinned, must resolve public
ALLOW_PAIRS = set()  # (host, port) exceptions — exact match, may be loopback (local LLM)


def allowed(host):
    host = (host or "").split(":")[0].lower()
    return any(host == a or host.endswith("." + a) for a in ALLOW)


def vet(host, port, pinned):
    """Vet a proxy target. Returns the list of (addr, port) to connect to, or None (deny).

    An exact (host, port) in ALLOW_PAIRS passes as-is (the local-LLM exception — loopback ok).
    Otherwise the hostname must be allowlisted AND the port must equal `pinned` (443 for
    CONNECT, 80 for plain http), and the name is resolved ONCE here: every resolved address
    must be public (no loopback/RFC1918/link-local), and the connection is made to the resolved
    address, never by re-resolving the name (no check-vs-connect rebind window)."""
    host = (host or "").lower()
    if not host or not port:
        return None
    if (host, port) in ALLOW_PAIRS:
        return [(host, port)]
    if port != pinned or not allowed(host):
        return None
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError:
        return None
    addrs = [i[4][0] for i in infos]
    if not addrs or any(not ipaddress.ip_address(a).is_global for a in addrs):
        return None  # any non-public resolution -> deny the whole target (rebind defense)
    return [(a, port) for a in addrs]


def connect_first(targets):
    """socket.create_connection over the vetted addresses, first one that answers wins."""
    err = None
    for t in targets:
        try:
            return socket.create_connection(t, timeout=10)
        except OSError as e:
            err = e
    raise err


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _deny(self):
        self.send_response(403, "Forbidden by egress allowlist")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_CONNECT(self):
        host, _, port = self.path.partition(":")
        try:
            port = int(port or 443)
        except ValueError:
            port = None
        targets = vet(host, port, 443)
        if not targets:
            self.log_message("DENY CONNECT %s", self.path)
            return self._deny()
        try:
            upstream = connect_first(targets)
        except OSError:
            self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers()
            self.close_connection = True
            return
        self.send_response(200, "Connection established")
        self.end_headers()
        self.log_message("ALLOW CONNECT %s", self.path)
        self._tunnel(self.connection, upstream)
        self.close_connection = True

    def _proxy_http(self):
        u = urlsplit(self.path)
        try:
            host, port = u.hostname, (u.port or 80)
        except ValueError:  # malformed port in the URL
            host, port = None, None
        # Log scheme+host(+port) only — a full URL can embed credentials (userinfo,
        # tokens in the path/query) and this log line may leave the host.
        dest = "%s://%s:%s" % (u.scheme or "?", host or "?", port or "?")
        targets = vet(host, port, 80) if u.scheme == "http" else None
        if not targets:
            self.log_message("DENY %s %s", self.command, dest)
            return self._deny()
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        try:
            upstream = connect_first(targets)
        except OSError:
            self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers()
            self.close_connection = True
            return
        body = b""
        clen = int(self.headers.get("Content-Length", 0) or 0)
        if clen:
            body = self.rfile.read(clen)
        hdrs = "".join(f"{k}: {v}\r\n" for k, v in self.headers.items()
                       if k.lower() not in ("proxy-connection", "connection"))
        req = (f"{self.command} {path} HTTP/1.0\r\n{hdrs}Connection: close\r\n\r\n").encode() + body
        upstream.sendall(req)
        self.log_message("ALLOW %s %s", self.command, dest)
        self._tunnel(self.connection, upstream)
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = do_PATCH = _proxy_http

    def log_request(self, code="-", size="-"):
        # Default BaseHTTPRequestHandler behavior logs the raw request line (the full URL,
        # credentials and all) on every send_response. The explicit ALLOW/DENY lines above
        # already log a redacted target — suppress the raw line entirely.
        pass

    @staticmethod
    def _tunnel(a, b):
        socks = [a, b]
        try:
            while True:
                r, _, _ = select.select(socks, [], [], 60)
                if not r:
                    break
                for s in r:
                    data = s.recv(65536)
                    if not data:
                        return
                    (b if s is a else a).sendall(data)
        except OSError:
            pass
        finally:
            try:
                b.close()
            except OSError:
                pass

    def log_message(self, fmt, *a):
        sys.stdout.write("[egress-proxy] " + (fmt % a) + "\n")
        sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--allow", default="")
    args = ap.parse_args()
    for a in args.allow.split(","):
        a = a.strip().lower()
        if not a:
            continue
        if ":" in a:  # host:port -> exact-pair exception (see module docstring)
            h, _, p = a.rpartition(":")
            ALLOW_PAIRS.add((h, int(p)))
        else:
            ALLOW.add(a)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[egress-proxy] allowlist={sorted(ALLOW)} pairs={sorted(ALLOW_PAIRS)} "
          f"listening {args.host}:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
