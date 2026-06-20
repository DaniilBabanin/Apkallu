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
"""
import argparse
import select
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ALLOW = set()


def allowed(host):
    host = (host or "").split(":")[0].lower()
    return any(host == a or host.endswith("." + a) for a in ALLOW)


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
        if not allowed(host):
            self.log_message("DENY CONNECT %s", self.path)
            return self._deny()
        try:
            upstream = socket.create_connection((host, int(port or 443)), timeout=10)
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
        if u.scheme != "http" or not allowed(u.hostname):
            self.log_message("DENY %s %s", self.command, self.path)
            return self._deny()
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        try:
            upstream = socket.create_connection((u.hostname, u.port or 80), timeout=10)
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
        self.log_message("ALLOW %s %s", self.command, self.path)
        self._tunnel(self.connection, upstream)
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = do_PATCH = _proxy_http

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
        if a.strip():
            ALLOW.add(a.strip().lower())
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[egress-proxy] allowlist={sorted(ALLOW)} listening {args.host}:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
