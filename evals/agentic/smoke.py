#!/usr/bin/env python3
"""smoke.py — a build phase host driver: prove OpenHands (SDK v1.27) × your provider wiring works inside the VM,
with the your provider key kept OFF the VM.

For each model it: ensures the host `proxy` is up (key-injecting reverse proxy), copies
`smoke_agent.py` into the VM, and runs it over an SSH `-R` tunnel so the guest reaches your provider via
the host proxy (dummy key in the VM). Collects the per-model result and writes `smoke.md`.

Usage: smoke.py [--name smoke] [--keep]   (--keep leaves the VM + proxy running for inspection)
"""
import argparse
import json
import os
import subprocess
import sys
import time

import vm  # reuse SSH key/opts, IP discovery, VM lifecycle

PORT = 18081  # host proxy + the VM-side SSH -R loopback endpoint
MODELS = [m.strip() for m in (os.environ.get("LLM_SMOKE_MODELS") or "").split(",") if m.strip()]
PROXY_PY = os.path.join(vm.HERE, "proxy.py")
AGENT_PY = os.path.join(vm.HERE, "smoke_agent.py")


def ensure_proxy():
    """Start the host proxy if it isn't already up. Returns the Popen we started (so we can
    terminate exactly it at teardown), or None if one was already running (then it isn't ours to kill)."""
    if vm._port_open("127.0.0.1", PORT):
        return None
    log = open(os.path.join(vm.HERE, "build", "proxy.log"), "ab")
    proc = subprocess.Popen([sys.executable, PROXY_PY, "--host", "127.0.0.1", "--port", str(PORT)],
                            stdout=log, stderr=log, start_new_session=True)
    for _ in range(20):
        if vm._port_open("127.0.0.1", PORT):
            return proc
        time.sleep(0.5)
    raise SystemExit("proxy failed to start")


def ensure_up(name):
    ip = vm._ip(name)
    if ip and vm.ssh(name, "true").returncode == 0:
        print(f"reusing {vm.dom(name)} at {ip}")
        return ip
    return vm.up(name, egress="open")


def run_model(name, ip, slug):
    """Run smoke_agent.py in the VM for one model over an ssh -R tunnel; return the parsed result."""
    ws = "/home/agent/smoke/" + slug.replace("/", "_")
    remote = f"OPENHANDS_SUPPRESS_BANNER=1 /opt/openhands/bin/python /tmp/smoke_agent.py {slug} {PORT} {ws}"
    cmd = ["ssh", *vm.SSH_OPTS, "-R", f"{PORT}:127.0.0.1:{PORT}", f"{vm.SSH_USER}@{ip}", remote]
    print(f"--- {slug} ---")
    p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    sys.stdout.write(p.stdout)
    for line in p.stdout.splitlines():
        if line.startswith("SMOKE_RESULT_JSON: "):
            return json.loads(line[len("SMOKE_RESULT_JSON: "):])
    return {"model": slug, "error": "no SMOKE_RESULT_JSON in output (exit %d)" % p.returncode,
            "passed": False}


def write_report(results):
    lines = [
        "# a build phase smoke — OpenHands SDK v1.27 × your provider (key off the VM)",
        "",
        "One headless run per model on a trivial task (`hello.py` + `test_hello.py`, make the test",
        "pass), driven by `smoke.py` -> `smoke_agent.py` inside the work VM. Inference reaches your provider",
        "through `proxy.py` over an SSH `-R` tunnel, so the **your provider key never enters the VM**",
        "(the guest holds only `api_key=\"x\"`). `passed` = both files exist AND `python test_hello.py`",
        "exits 0 when re-run on the host's behalf (the model's own success claim is untrusted).",
        "",
        "| model | passed | test_exit | files (hello/test) | agent events | execution_status | error |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in results:
        files = f"{'Y' if r.get('hello_py') else 'N'}/{'Y' if r.get('test_py') else 'N'}"
        lines.append("| {model} | {p} | {te} | {f} | {n} | {st} | {err} |".format(
            model=r.get("model"), p="**PASS**" if r.get("passed") else "FAIL",
            te=r.get("test_exit"), f=files, n=r.get("n_events"),
            st=(r.get("execution_status") or "").replace("|", "/"),
            err=(r.get("error") or "-")))
    overall = "ALL PASS" if results and all(r.get("passed") for r in results) else "FAILURES PRESENT"
    lines += ["", f"**SMOKE: {overall}**", "",
              "Wiring (D-024): `register_default_tools()`; "
              "`LLM(model=\"openai/<slug>\", base_url=tunnel, api_key=\"x\")`; "
              "`Agent(llm, tools=[Tool(\"terminal\"), Tool(\"file_editor\")])`; "
              "`Conversation(agent, workspace)`; `send_message(task)`; `run()`. "
              "No UA/auth errors (proxy preserves LiteLLM's UA, injects the real key).", "",
              "Caveat: `<model-slug>` is not in LiteLLM's price map, so its in-SDK cost telemetry "
              "reports `$0.00` (a harmless `Cost calculation failed` warning; inference is unaffected). "
              "a build phase budget parity must source the local model cost from your provider usage, not the SDK number.", ""]
    path = os.path.join(vm.HERE, "smoke.md")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print("wrote", path)
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="smoke")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    if not MODELS:
        raise SystemExit("set LLM_SMOKE_MODELS=slug1,slug2 (see .env.example)")
    proxy = ensure_proxy()
    ip = ensure_up(a.name)
    # copy the in-VM agent driver in (host-initiated, no host FS mount)
    with open(AGENT_PY) as f:
        subprocess.run(["ssh", *vm.SSH_OPTS, f"{vm.SSH_USER}@{ip}", "cat > /tmp/smoke_agent.py"],
                       text=True, input=f.read(), check=True)
    results = [run_model(a.name, ip, slug) for slug in MODELS]
    write_report(results)
    if not a.keep:
        vm.destroy(a.name)
        if proxy is not None:        # terminate only the proxy we started, by handle (never pkill -f)
            proxy.terminate()
    sys.exit(0 if all(r.get("passed") for r in results) else 1)


if __name__ == "__main__":
    main()
