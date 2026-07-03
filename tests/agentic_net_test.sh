#!/usr/bin/env bash
# Tests for the evals/agentic networking hardening (audit phase 4). Three units:
#   1. vm.py nwfilter XML — every egress profile must drop ALL IPv6 (rules are IPv4-only and
#      nwfilter default-accepts unmatched frames, so the guest's fe80 would bypass everything).
#   2. egress_proxy.py — CONNECT pinned to :443 / plain http to :80, loopback-resolving targets
#      denied, exact host:port exception (the local-LLM pair) passes. Live socket clients
#      against a real proxy process; no VM needed.
#   3. proxy.py — an upstream body without Content-Length is relayed incrementally (chunked),
#      not buffered until upstream EOF.
# Host-local (loopback listeners); the single allowed-public CONNECT probe (1.1.1.1:443)
# accepts 502 as well as 200 so the test stays green offline.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v python3 >/dev/null 2>&1 || { echo "agentic_net_test: SKIP (no python3)"; exit 0; }

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { # check <desc> <expected-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (want: *$2*, got: $3)" ;; esac
}

freeport() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# --- 1. nwfilter XML: IPv6 dropped in every profile --------------------------
IPV6_RULE="<rule action='drop' direction='inout' priority='45'><all-ipv6/></rule>"
for prof in open restricted none; do
  xml="$(python3 -c "import sys; sys.path.insert(0,'evals/agentic'); import vm; print(vm._filter_xml('$prof'))")"
  check "nwfilter[$prof] drops all IPv6" "$IPV6_RULE" "$xml"
done

# --- 2. egress proxy: port pin + resolved-IP vetting + host:port exception ---
EP_PORT="$(freeport)"; LLM_PORT="$(freeport)"

# stub "local LLM server": plain http.server (answers CONNECT-tunneled TCP + absolute-form GET)
python3 -m http.server --bind 127.0.0.1 -d "$TMP" "$LLM_PORT" >/dev/null 2>&1 &
PIDS+=($!)

# the audit scenario: bare "localhost" IS allowlisted (local-model config), plus a public host
# and the exact local-LLM pair exception
python3 evals/agentic/egress_proxy.py --host 127.0.0.1 --port "$EP_PORT" \
  --allow "1.1.1.1,localhost,localhost:${LLM_PORT}" >"$TMP/ep.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(('127.0.0.1',$EP_PORT)))" && break
  sleep 0.1
done

do_connect() { # do_connect <host:port> -> first response line from the proxy
  python3 - "$EP_PORT" "$1" <<'EOF'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=20)
tgt = sys.argv[2]
s.sendall(f"CONNECT {tgt} HTTP/1.1\r\nHost: {tgt}\r\n\r\n".encode())
print(s.recv(4096).decode(errors="replace").splitlines()[0])
EOF
}

check "CONNECT localhost:22 refused (port pin)"      " 403 " "$(do_connect localhost:22)"
check "CONNECT localhost:443 refused (loopback IP)"  " 403 " "$(do_connect localhost:443)"
check "CONNECT 1.1.1.1:22 refused (port pin)"        " 403 " "$(do_connect 1.1.1.1:22)"
r="$(do_connect 1.1.1.1:443)"
case "$r" in *" 403 "*) bad "CONNECT allowed-public:443 not denied (got: $r)" ;;
             *)         ok  "CONNECT allowed-public:443 not denied ($r)" ;; esac
check "CONNECT localhost:LLM_PORT (exception) tunnels" " 200 " "$(do_connect "localhost:${LLM_PORT}")"

http_via_proxy() { # http_via_proxy <url> -> status code
  python3 - "$EP_PORT" "$1" <<'EOF'
import sys, urllib.request, urllib.error
op = urllib.request.build_opener(urllib.request.ProxyHandler({"http": f"http://127.0.0.1:{sys.argv[1]}"}))
try:
    print(op.open(sys.argv[2], timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
EOF
}
check "http GET localhost:LLM_PORT (exception) passes" "200" "$(http_via_proxy "http://localhost:${LLM_PORT}/")"
check "http GET localhost:22 refused"                  "403" "$(http_via_proxy "http://localhost:22/")"

# --- 3. auth proxy: no-Content-Length upstream is relayed incrementally ------
UP_PORT="$(freeport)"; AP_PORT="$(freeport)"

cat >"$TMP/sse_upstream.py" <<'EOF'
# one-shot HTTP/1.0 upstream: 200 with no Content-Length, two chunks 1.2s apart, then close
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for i in range(2):
            self.wfile.write(b"data: chunk%d\n\n" % i)
            self.wfile.flush()
            time.sleep(1.2)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
EOF
python3 "$TMP/sse_upstream.py" "$UP_PORT" &
PIDS+=($!)

LLM_BASE_URL="http://127.0.0.1:${UP_PORT}" LLM_API_KEY=dummy \
  python3 evals/agentic/proxy.py --host 127.0.0.1 --port "$AP_PORT" >"$TMP/ap.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(('127.0.0.1',$AP_PORT)))" && break
  sleep 0.1
done

stream_out="$(python3 - "$AP_PORT" <<'EOF'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=30)
s.sendall(b"GET /openai/v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
t0 = time.time(); buf = b""; seen = {}
while True:
    d = s.recv(65536)
    if not d:
        break
    buf += d
    for tag in (b"chunk0", b"chunk1"):
        if tag in buf and tag not in seen:
            seen[tag] = time.time() - t0
gap = seen.get(b"chunk1", 0) - seen.get(b"chunk0", 99)
print("chunked=%s t0=%.2f t1=%.2f gap=%.2f %s" % (
    b"Transfer-Encoding: chunked" in buf, seen.get(b"chunk0", -1), seen.get(b"chunk1", -1),
    gap, "INCREMENTAL" if gap >= 0.6 else "BUFFERED"))
EOF
)"
echo "     [stream] $stream_out"
check "proxy relays stream chunks incrementally" "INCREMENTAL" "$stream_out"
check "proxy re-frames stream as chunked"        "chunked=True" "$stream_out"

echo "---"
echo "agentic_net_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
