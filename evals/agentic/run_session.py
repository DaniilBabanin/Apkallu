#!/usr/bin/env python3
"""run_session.py — PRIMARY (PLAN.md a build phase): run ONE long, hands-off, autonomous coding session
in an isolated VM and extract a reviewable result to the host.

  run_session.py --repo DIR --task TEXT|--task-file F --model SLUG [opts]

It: boots a fresh-overlay VM (the security boundary; open egress + LAN block), copies the repo in
(host-initiated rsync — never a host FS mount), scaffolds git (baseline + `agent-session` branch),
runs OpenHands headless inside the VM via `session_agent.py` with long-horizon settings (high
max_iterations, summarizing condenser, periodic git checkpoints, wall-clock timeout) reaching your provider
through the host `proxy` over an ssh `-R` tunnel (key off the VM), then ALWAYS extracts —
even on timeout/error — the result branch (`repo.bundle`), the diff (`session.patch`), and the full
trajectory (`trajectory.json`) into `results/<id>/`, tagging `partial` when the session didn't
finish. Reverts/destroys the VM unless `--keep`.

The host is never at risk: all transfer is host-initiated SSH; the extraction re-reads the VM, the
host FS is never mounted in. Model output is untrusted — the branch/diff is for director review.
"""
import argparse
import json
import os
import subprocess
import sys
import time

import vm

PORT = 18081
HERE = vm.HERE
PROXY_PY = os.path.join(HERE, "proxy.py")
AGENT_PY = os.path.join(HERE, "session_agent.py")
RESULTS = os.path.join(HERE, "results")


MIN_LOCAL_CTX = 16384   # OpenHands' opening prompt alone is ~6k tokens; a model served at a
                        # small context 400s the first request ("n_keep >= n_ctx")


def ensure_local_ctx(model, port):
    """Local-lane preflight: fail fast (or self-heal) when `model` would serve at a context too
    small for an agentic session. Ollama: num_ctx is pinned at import — check /api/show, error
    with the re-import command. LM Studio: check /api/v0/models, reload bigger via `lms`.
    Other OpenAI-compatible servers: skip — nothing to check."""
    import re
    import shutil
    import urllib.request

    def _get(url, data=None):
        req = urllib.request.Request(url, data=data,
                                     headers={"Content-Type": "application/json"} if data else {})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.load(r)

    # ollama?
    try:
        _get(f"http://127.0.0.1:{port}/api/version")
    except Exception:
        pass
    else:
        try:
            info = _get(f"http://127.0.0.1:{port}/api/show",
                        json.dumps({"model": model}).encode())
        except Exception:
            raise SystemExit(f"local model {model!r} not on ollama :{port} — import it: "
                             f"./local/ollama-import.sh <gguf> {model} 32768")
        m = re.search(r"num_ctx\s+(\d+)", info.get("parameters") or "")
        ctx = int(m.group(1)) if m else 0
        if ctx < MIN_LOCAL_CTX:
            raise SystemExit(f"{model}: ollama num_ctx pin {ctx or 'unset'} < {MIN_LOCAL_CTX} — "
                             f"re-import: ./local/ollama-import.sh <gguf> {model} 32768")
        return

    # LM Studio?
    try:
        models = _get(f"http://127.0.0.1:{port}/api/v0/models").get("data", [])
    except Exception:
        return
    m = next((x for x in models if x.get("id") == model), None)
    if m is None:
        raise SystemExit(f"local model {model!r} not on server :{port} (see /api/v0/models)")
    ctx = m.get("loaded_context_length") or 0   # 0 = not loaded → JIT load would use the default
    if ctx >= MIN_LOCAL_CTX:
        return
    target = min(32768, m.get("max_context_length") or 32768)
    lms = shutil.which("lms") or os.path.expanduser("~/.cache/lm-studio/bin/lms")
    if not os.path.exists(lms):
        raise SystemExit(f"{model} loaded_context={ctx} < {MIN_LOCAL_CTX}; "
                         f"fix: lms load {model} --context-length {target}")
    print(f"[run_session] {model} loaded_context={ctx} < {MIN_LOCAL_CTX}: reloading at {target}")
    subprocess.run([lms, "unload", model], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if subprocess.run([lms, "load", model, "--context-length", str(target),
                       "--ttl", "7200", "-y"]).returncode != 0:
        raise SystemExit(f"lms load {model} --context-length {target} failed")


def ensure_proxy():
    if vm._port_open("127.0.0.1", PORT):
        return None
    log = open(os.path.join(HERE, "build", "proxy.log"), "ab")
    proc = subprocess.Popen([sys.executable, PROXY_PY, "--host", "127.0.0.1", "--port", str(PORT)],
                            stdout=log, stderr=log, start_new_session=True)
    for _ in range(20):
        if vm._port_open("127.0.0.1", PORT):
            return proc
        time.sleep(0.5)
    raise SystemExit("proxy failed to start")


def _ssh(ip, cmd, timeout=120):
    """Run a command in the VM; return CompletedProcess (stdout+stderr merged)."""
    return subprocess.run(["ssh", *vm.SSH_OPTS, f"{vm.SSH_USER}@{ip}", cmd],
                          text=True, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def _put(ip, local_path, remote_path):
    with open(local_path) as f:
        subprocess.run(["ssh", *vm.SSH_OPTS, f"{vm.SSH_USER}@{ip}", f"cat > {remote_path}"],
                       text=True, input=f.read(), check=True)


def _scp_out(ip, remote_path, local_path):
    subprocess.run(["scp", *vm.SSH_OPTS, f"{vm.SSH_USER}@{ip}:{remote_path}", local_path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _extract_final(traj_path):
    """Pull the agent's last substantive message — the answer/verdict — out of a trajectory,
    handling both serializations we see (native `llm_message.content[].text` and
    OpenHands `action.message`). Returns (full_text, one_line_headline)."""
    import re
    with open(traj_path) as f:
        t = json.load(f)
    texts = []
    for ev in t if isinstance(t, list) else []:
        if ev.get("source") != "agent":
            continue
        msg = (ev.get("action") or {}).get("message")
        if isinstance(msg, str) and msg.strip():
            texts.append(msg)
        for c in ((ev.get("llm_message") or {}).get("content") or []):
            if isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip():
                texts.append(c["text"])
    final = texts[-1] if texts else ""
    m = re.search(r"VERDICT[:* ].{0,100}", final)
    headline = (m.group(0) if m else final[:120]).replace("\n", " ").strip(" *#")
    return final, headline


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="host dir copied into the VM as the workspace")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--task")
    g.add_argument("--task-file")
    ap.add_argument("--model", default=os.environ.get("LLM_MODEL"),
                    help="model slug for the remote lane; defaults to $LLM_MODEL")
    ap.add_argument("--local-model", help="a local server model slug; run via host a local server over ssh -R "
                    "(local lane, no your provider proxy). Tools still run in the VM sandbox.")
    ap.add_argument("--verify-cmd", help="run in the workspace after the session (informative; not gating)")
    ap.add_argument("--verify-timeout", type=int, default=120,
                    help="seconds for --verify-cmd (a full test gate can take many minutes)")
    ap.add_argument("--timeout", type=int, default=1800, help="in-VM session wall-clock seconds")
    ap.add_argument("--max-iterations", type=int, default=200)
    ap.add_argument("--name", default="sess")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--save-bundle", action="store_true",
                    help="also save repo.bundle (full git history, ~20MB/run). Off by default — "
                         "session.patch + meta already capture the change; the bundle is replay-only bulk.")
    a = ap.parse_args()

    # local lane = a local server model on the host GPU, reached over an ssh -R tunnel; the agent's
    # tools still run in the VM sandbox. your provider lane (default) = remote open model via the key-off-VM
    # auth proxy. a local server is keyless (/v1); the proxy serves /openai/v1.
    local = a.local_model is not None
    if not local and not a.model:
        raise SystemExit("set --model or LLM_MODEL for the remote lane (see .env.example)")
    model = a.local_model if local else a.model
    # local lane default = ollama; LLM_LOCAL_PORT overrides (e.g. 1234 for LM Studio)
    llm_port = int(os.environ.get("LLM_LOCAL_PORT", "11434")) if local else PORT
    if local:
        ensure_local_ctx(model, llm_port)

    repo = os.path.abspath(a.repo.rstrip("/"))
    if not os.path.isdir(repo):
        raise SystemExit(f"--repo not a dir: {repo}")
    task = a.task if a.task is not None else open(a.task_file).read()
    # include --name so concurrent same-model jobs (a build phase dispatcher) never share an outdir
    sid = time.strftime("%Y%m%d-%H%M%S") + "-" + a.name + "-" + model.replace("/", "_")
    outdir = os.path.join(RESULTS, sid)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "task.md"), "w") as f:   # captured session = self-reproducible
        f.write(task)

    proxy = None if local else ensure_proxy()   # local lane needs no auth proxy (a local server is keyless)
    print(f"[run_session] {sid}: booting fresh VM (lane={'local' if local else 'remote'} model={model})")
    vm.destroy(a.name)                      # guarantee a clean overlay
    meta = {"id": sid, "repo": repo, "model": model, "lane": "local" if local else "remote",
            "task": task, "task_chars": len(task),
            "timeout": a.timeout, "max_iterations": a.max_iterations, "verify_cmd": a.verify_cmd,
            "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "extract_errors": []}
    started = time.time()
    ip = None
    try:
        # boot INSIDE the try: a standalone run (no dispatch reaper) must not leak a live VM
        # when up() dies mid-boot — the finally below tears it down.
        ip = vm.up(a.name, egress="open")
        vm.put_repo(a.name, repo, dest="workspace")
        # git scaffold: baseline commit (if needed) + agent-session branch; print baseline SHA.
        scaffold = (
            "set -e; cd ~/workspace; "
            # image ships python3 only; tasks and --verify-cmd routinely say `python` (exit 127)
            "command -v python >/dev/null || sudo ln -sf $(command -v python3) /usr/local/bin/python; "
            "git config --global user.email agent@agentic.local; "
            "git config --global user.name 'agentic agent'; "
            "[ -d .git ] || git init -q; "
            # keep build noise out of the checkpoint commits so session.patch stays a clean review
            # artifact; .git/info/exclude is repo-local and never appears in the tree/diff.
            "printf '__pycache__/\\n*.pyc\\n.oh/\\n' >> .git/info/exclude; "
            "git rev-parse HEAD >/dev/null 2>&1 || { git add -A; git commit -q -m baseline; }; "
            "git checkout -q -B agent-session; git rev-parse HEAD")
        r = _ssh(ip, scaffold)
        meta["baseline_sha"] = (r.stdout or "").strip().splitlines()[-1] if r.returncode == 0 else None
        if r.returncode != 0:
            raise SystemExit(f"git scaffold failed: {r.stdout}")

        _put(ip, AGENT_PY, "/tmp/session_agent.py")
        _ssh(ip, "mkdir -p ~/out", timeout=30)
        subprocess.run(["ssh", *vm.SSH_OPTS, f"{vm.SSH_USER}@{ip}", "cat > /tmp/task.md"],
                       text=True, input=task, check=True)

        # local lane: a local server at host :1234 (/v1) over the ssh -R tunnel; remote lane: proxy :18081 (/openai/v1)
        llm_flags = (f"--model {model} --port 0 --base-url http://127.0.0.1:{llm_port}/v1"
                     if local else f"--model {model} --port {PORT}")
        remote = (f"OPENHANDS_SUPPRESS_BANNER=1 /opt/openhands/bin/python /tmp/session_agent.py "
                  f"{llm_flags} --workspace /home/agent/workspace "
                  f"--task-file /tmp/task.md --out /home/agent/out "
                  f"--timeout {a.timeout} --max-iterations {a.max_iterations}")
        cmd = ["ssh", *vm.SSH_OPTS, "-R", f"{llm_port}:127.0.0.1:{llm_port}", f"{vm.SSH_USER}@{ip}", remote]
        host_timeout = a.timeout + 180       # in-VM alarm should fire first; this is the hard backstop
        print(f"[run_session] running session (in-VM timeout {a.timeout}s, host backstop {host_timeout}s)")
        log = ""
        try:
            p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=host_timeout)
            log = p.stdout
        except subprocess.TimeoutExpired as e:
            # TimeoutExpired.output is bytes even with text=True (partial output isn't decoded on the
            # timeout path), so coerce before concatenating — else "can't concat str to bytes".
            out = e.output or ""
            if isinstance(out, (bytes, bytearray)):
                out = out.decode("utf-8", "replace")
            log = out + "\n[run_session] HOST BACKSTOP TIMEOUT — killing remote session"
            meta["extract_errors"].append("host_backstop_timeout")
            _ssh(ip, "pkill -f session_agent.py || true", timeout=30)  # VM-side kill (safe)
        with open(os.path.join(outdir, "agent.log"), "w") as f:
            f.write(log)
    finally:
        # ---- ALWAYS extract (each step guarded independently; one failure must not lose the rest) ----
        def step(name, fn):
            try:
                return fn()
            except Exception as e:   # noqa: BLE001
                meta["extract_errors"].append(f"{name}: {e}")
                return None

        if ip is None:
            # boot never yielded an IP — nothing in the VM to extract; skip straight to
            # meta/teardown (vm.up cleans its own partial boot; destroy below is idempotent)
            meta["extract_errors"].append("vm boot failed — nothing to extract")
        else:
            # host-side backstop final commit (covers a hard-killed session_agent that never committed)
            step("final_commit", lambda: _ssh(ip, "cd ~/workspace && git add -A && "
                                                   "git commit -q -m 'host final checkpoint' || true", timeout=60))
            meta["head_sha"] = step("head_sha", lambda: (_ssh(ip,
                "cd ~/workspace && git rev-parse HEAD").stdout or "").strip()) or None
            meta["commits"] = step("commits", lambda: int((_ssh(ip,
                "cd ~/workspace && git rev-list --count agent-session").stdout or "0").strip() or 0))
            meta["diffstat"] = step("diffstat", lambda: (_ssh(ip,
                f"cd ~/workspace && git diff {meta.get('baseline_sha')} HEAD --stat").stdout or "").strip())
            if a.save_bundle:
                step("repo_bundle", lambda: (_ssh(ip, "cd ~/workspace && git bundle create /tmp/repo.bundle --all"),
                                             _scp_out(ip, "/tmp/repo.bundle", os.path.join(outdir, "repo.bundle"))))
            step("session_patch", lambda: open(os.path.join(outdir, "session.patch"), "w").write(
                _ssh(ip, f"cd ~/workspace && git diff {meta.get('baseline_sha')} HEAD", timeout=120).stdout or ""))
            step("trajectory", lambda: _scp_out(ip, "/home/agent/out/trajectory.json",
                                                os.path.join(outdir, "trajectory.json")))

            def _save_final():
                tp = os.path.join(outdir, "trajectory.json")
                if not os.path.exists(tp):
                    return
                final, headline = _extract_final(tp)
                if final:
                    open(os.path.join(outdir, "final.md"), "w").write(final)
                    meta["final_headline"] = headline
            step("final", _save_final)
            rj = step("result_json", lambda: _scp_out(ip, "/home/agent/out/result.json",
                                                      os.path.join(outdir, "result.json")))
            # isolation invariant (light): no host FS passthrough mount visible in the VM
            meta["isolation_no_hostfs"] = step("isolation", lambda: int((_ssh(ip,
                "mount | grep -Ec '9p|virtiofs' || true").stdout or "0").strip() or 0) == 0)
            if a.verify_cmd:
                vr = step("verify", lambda: _ssh(ip, f"cd ~/workspace && {a.verify_cmd}", timeout=120))
                if vr is not None:
                    meta["verify"] = {"exit": vr.returncode, "tail": "\n".join((vr.stdout or "").splitlines()[-8:])}

        # status: prefer the in-VM result.json; else partial (we extracted whatever exists)
        rp = os.path.join(outdir, "result.json")
        if os.path.exists(rp):
            res = json.load(open(rp))
            meta["status"] = res.get("status", "partial")
            meta["reason"] = res.get("reason")
            meta["n_events"] = res.get("n_events")
            meta["usage"] = res.get("usage")
        else:
            meta["status"] = "partial"
            meta["reason"] = "no result.json (session did not write one)"
        meta["elapsed_sec"] = round(time.time() - started, 1)
        meta["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        with open(os.path.join(outdir, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)

        if not a.keep:
            vm.destroy(a.name)
            if proxy is not None:
                proxy.terminate()

    print(f"[run_session] status={meta.get('status')} reason={meta.get('reason')} -> {outdir}")
    for fn in ("meta.json", "final.md", "session.patch", "trajectory.json", "result.json", "agent.log"):
        p = os.path.join(outdir, fn)
        print(f"  {'OK ' if os.path.exists(p) else 'MISS'} {fn}"
              + (f" ({os.path.getsize(p)}B)" if os.path.exists(p) else ""))

    # Refresh the cross-run index so learnings stay discoverable without anyone remembering to
    # run it. Runs after every session (dispatch.py calls this per job). Never fail the session on it.
    try:
        import index
        index.main()
    except Exception as e:   # noqa: BLE001
        print(f"[run_session] index refresh skipped: {e}")
    sys.exit(0 if meta.get("status") in ("complete", "partial") else 1)


if __name__ == "__main__":
    main()
