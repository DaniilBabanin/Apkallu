#!/usr/bin/env python3
"""proxy.py — host-side auth-injecting reverse proxy that keeps the inference API key OFF the VM.

Provider-agnostic. Point it at any OpenAI-compatible endpoint with EITHER:
  LLM_BASE_URL       full scheme://host[:port]/path (e.g. https://api.example.com/openai/v1 or
                     http://localhost:11434/v1) — the upstream path is remapped onto the client's, so
                     endpoints using /v1, /api/v1, etc. work, not just /openai/v1.
  LLM_UPSTREAM_HOST  host only (legacy) — implies https and forwards the client's /openai/v1 verbatim.
Supply the key with LLM_API_KEY. One of the upstream vars is required (see .env.example).

The VM needs to *use* the inference API but must never *possess* the key (open egress makes anything
in the VM exfiltratable — PLAN.md security model, D-023). This proxy runs on the host, reads the
key from the gitignored `.secrets.env`, and forwards inference requests to the upstream with the real
`Authorization` header injected. The VM points OpenHands' `LLM_BASE_URL` at this proxy over an SSH `-R`
reverse tunnel (loopback only — no nwfilter hole, works in any egress profile), so the guest connects
to `http://127.0.0.1:PORT/openai/v1` with a *dummy* key that this proxy discards.

Residual (honest framing, same precision as D-025): a hostile VM can *spend* the disposable key's
quota through the open tunnel, but cannot read the key value. The key is disposable + spend-capped.

Listens loopback by default (the SSH `-R` endpoint is the host's 127.0.0.1). Stdlib only.
"""
import argparse
import http.client
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# Upstream resolution (required; checked in main()):
#   LLM_BASE_URL      — full scheme://host[:port]/path. Preferred: any API path is remapped onto LOCAL_BASE.
#   LLM_UPSTREAM_HOST — host only (legacy): https + the client's /openai/v1 path forwarded verbatim.
LOCAL_BASE = "/openai/v1"   # the path the VM-side client always talks to (session_agent.py base_url)
_BASE_URL = os.environ.get("LLM_BASE_URL")
if _BASE_URL:
    _u = urlsplit(_BASE_URL)
    SCHEME = _u.scheme or "https"
    UPSTREAM = _u.netloc                       # host[:port]
    UPSTREAM_PATH = _u.path.rstrip("/")        # "/openai/v1", "/v1", or "" — remapped onto LOCAL_BASE
else:
    SCHEME = "https"
    UPSTREAM = os.environ.get("LLM_UPSTREAM_HOST")
    UPSTREAM_PATH = None                        # forward the client path verbatim (legacy)
# Headers we must not blind-copy: hop-by-hop (RFC 7230 6.1) + ones we recompute/override.
STRIP = {"host", "authorization", "content-length", "connection", "keep-alive",
         "transfer-encoding", "proxy-connection", "te", "trailer", "upgrade"}
KEY = None
# Key var names tried in order, env first then the secrets file.
KEY_VARS = ("LLM_API_KEY",)
# your provider's edge 403s the default Python http.client UA (the run_eval.py gotcha — and THIS proxy is
# exactly that raw-HTTP path). LiteLLM sends its own UA which passes; we preserve it and only supply
# this fallback if a client sent none.
UA_FALLBACK = "Mozilla/5.0 (X11; Linux x86_64) remote-proxy/1"


def _read_key(path):
    # env wins (CI / container use); otherwise scan the gitignored secrets file.
    for var in KEY_VARS:
        if os.environ.get(var):
            return os.environ[var]
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        lines = []
    for var in KEY_VARS:
        for line in lines:
            line = line.strip()
            if line.startswith("export "):
                line = line[len("export "):].strip()
            if line.startswith(var + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(f"no API key ({' / '.join(KEY_VARS)}) in env or {path}")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Never log headers or bodies (they would log the injected key). Only method/path/status.
    def log_message(self, fmt, *args):  # noqa: A003 (override)
        sys.stderr.write("remote-proxy %s\n" % (fmt % args))

    def _forward(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        headers = {k: v for k, v in self.headers.items() if k.lower() not in STRIP}
        headers["Authorization"] = f"Bearer {KEY}"        # discard the VM's dummy, inject the real key
        headers.setdefault("User-Agent", UA_FALLBACK)
        path = self.path
        if UPSTREAM_PATH is not None and path.startswith(LOCAL_BASE):
            path = (UPSTREAM_PATH + path[len(LOCAL_BASE):]) or "/"   # remap the client's base onto the upstream's
        try:
            conn = http.client.HTTPSConnection if SCHEME == "https" else http.client.HTTPConnection
            up = conn(UPSTREAM, timeout=300)
            up.request(method, path, body=body, headers=headers)  # http.client sets Host + Content-Length
            resp = up.getresponse()
            data = resp.read()                            # stream=False -> one JSON blob; read fully
        except Exception as e:                            # noqa: BLE001 — surface upstream failures as 502
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            msg = f"remote-proxy upstream error: {e}".encode()
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in STRIP:
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self._forward("POST")

    def do_GET(self):
        self._forward("GET")


def main():
    global KEY
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description="auth-injecting reverse proxy, key off the VM (set LLM_BASE_URL)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18081)
    p.add_argument("--secrets", default=os.path.join(here, ".secrets.env"))
    a = p.parse_args()
    if not UPSTREAM:
        raise SystemExit("set LLM_BASE_URL (scheme://host/path) or LLM_UPSTREAM_HOST (see .env.example)")
    KEY = _read_key(a.secrets)
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    sys.stderr.write(f"remote-proxy listening on {a.host}:{a.port} -> {SCHEME}://{UPSTREAM}{UPSTREAM_PATH or ''}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
