#!/usr/bin/env python3
"""session_agent.py — runs INSIDE the work VM: drive one long-horizon OpenHands session on a real
repo, with the your provider key OFF the VM (inference rides the ssh -R tunnel to the host proxy).

Long-horizon settings (PLAN.md a build phase): high max_iterations, summarizing condenser ON, periodic
git checkpoint commits (so a crash/timeout never loses work), and a wall-clock timeout. On
completion OR timeout OR error it still writes result.json + trajectory.json so the host can extract
a (possibly `partial`) result.

The timeout is enforced by running conv.run() in a worker thread and calling conv.pause() from the
main thread when the budget elapses — signals do NOT interrupt the SDK's run loop (verified: a
SIGALRM mid-run is swallowed and the session continues). The host ssh-timeout is the hard backstop.

ALL session output goes to --out (OUTSIDE the workspace repo) so the checkpoint's `git add -A` never
commits OpenHands internals into the reviewable diff. The trajectory is dumped incrementally (every
checkpoint) so even a host hard-kill leaves a recent trajectory on disk.

Usage: session_agent.py --model SLUG --port P --workspace DIR --task-file F --out DIR
                        [--timeout SEC] [--max-iterations N] [--checkpoint-every K]
"""
import argparse
import ast
import json
import os
import subprocess
import threading
import time

from openhands.sdk import (LLM, Agent, Conversation, LLMSummarizingCondenser, Tool)
from openhands.tools import register_default_tools

PAUSE_GRACE = 45      # seconds to let conv.run() unwind after pause() (an in-flight LLM call finishes)


def _git(ws, *args):
    return subprocess.run(["git", "-C", ws, *args], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def _event_text(d):
    """Pull the human-readable text out of an event's observation/llm_message (a nested content dict)."""
    raw = d.get("observation") or d.get("llm_message")
    if isinstance(raw, str):
        try:
            raw = ast.literal_eval(raw)
        except Exception:   # noqa: BLE001
            return raw
    if isinstance(raw, dict):
        c = raw.get("content")
        if isinstance(c, list) and c and isinstance(c[0], dict):
            return c[0].get("text", "") or ""
        if isinstance(raw.get("text"), str):
            return raw["text"]
    return str(raw) if raw else ""


def _fmt_event(n, event):
    """One compact, human-readable line per event for the live events.log (`tail -f` monitoring)."""
    try:
        d = event.model_dump(mode="json")
    except Exception:   # noqa: BLE001
        return f"[{n:03d}] {type(event).__name__}"
    kind, src, tool = d.get("kind", "?"), d.get("source", ""), d.get("tool_name", "")

    def snip(x, m=160):
        return " ".join(str(x).split())[:m]
    if kind == "ActionEvent":
        return f"[{n:03d}] act  {snip(d.get('summary') or d.get('action'))}"
    if kind == "ObservationEvent":
        return f"[{n:03d}] obs  {tool}: {snip(_event_text(d))}"
    if kind == "MessageEvent":
        return f"[{n:03d}] msg  {src}: {snip(_event_text(d))}"
    if kind == "SystemPromptEvent":
        return f"[{n:03d}] ---  system prompt"
    return f"[{n:03d}] {kind} ({src})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--port", type=int, required=True)
    # --base-url overrides the port-derived default (your provider proxy). Used to point the agent at a
    # local a local server endpoint over an ssh -R tunnel (local model, tools still run in the VM sandbox).
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--api-key", default="x")
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--task-file", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--llm-timeout", type=int, default=600,
                    help="per-LLM-request timeout seconds; raise for slow spilled models "
                         "(a 4k-token turn at 6 tok/s is ~11 min)")
    ap.add_argument("--max-iterations", type=int, default=200)
    ap.add_argument("--checkpoint-every", type=int, default=5)
    a = ap.parse_args()

    ws, out = a.workspace, a.out
    os.makedirs(out, exist_ok=True)
    with open(a.task_file) as f:
        task = f.read()

    register_default_tools()
    base_url = a.base_url or f"http://127.0.0.1:{a.port}/openai/v1"
    llm = LLM(model=f"openai/{a.model}", base_url=base_url,
              api_key=a.api_key, usage_id="session", temperature=0.0, num_retries=3,
              timeout=a.llm_timeout)
    agent = Agent(
        llm=llm,
        tools=[Tool(name="terminal"), Tool(name="file_editor")],
        condenser=LLMSummarizingCondenser(llm=llm),   # summarize long histories so the ctx window holds
    )

    def dump_trajectory(conv):
        try:
            ev = [e.model_dump(mode="json") for e in conv.state.events]
        except Exception:   # noqa: BLE001 — a non-serializable field must not lose the trajectory
            ev = json.loads(json.dumps([str(e) for e in conv.state.events], default=str))
        tmp = os.path.join(out, "trajectory.json.tmp")
        with open(tmp, "w") as f:
            json.dump(ev, f)
        os.replace(tmp, os.path.join(out, "trajectory.json"))   # atomic

    # Periodic checkpoint: commit the agent's progress + refresh the trajectory every K events.
    # Guarded so a checkpoint failure can NEVER abort the session; skip-if-clean so no empty commits.
    # This (not the timeout) is the crash-safety net — branch + trajectory always hold the last step.
    state = {"n": 0, "ck": 0}
    ev_log = os.path.join(out, "events.log")   # live, one line/event, in `out` (outside ws) -> tail -f

    def checkpoint(event):
        state["n"] += 1
        try:                              # live event stream (every event) for `tail -f` monitoring
            with open(ev_log, "a") as f:
                f.write(_fmt_event(state["n"], event) + "\n")
        except Exception:                 # noqa: BLE001 — never let logging kill the run
            pass
        if state["n"] % a.checkpoint_every:
            return
        try:
            _git(ws, "add", "-A")
            if _git(ws, "diff", "--cached", "--quiet").returncode != 0:
                _git(ws, "commit", "-q", "-m", f"checkpoint {state['ck'] + 1}")
                state["ck"] += 1
            dump_trajectory(conv)
        except Exception:   # noqa: BLE001 — best-effort; never let a checkpoint kill the run
            pass

    conv = Conversation(
        agent, workspace=ws,
        persistence_dir=os.path.join(out, "oh_state"),   # OUTSIDE ws -> not caught by git add -A
        max_iteration_per_run=a.max_iterations,
        callbacks=[checkpoint],
    )

    # Run in a worker thread; the main thread enforces the wall-clock budget via conv.pause().
    box = {"err": None}
    done = threading.Event()

    def _run():
        try:
            conv.send_message(task)
            conv.run()
        except Exception as e:   # noqa: BLE001 — report honestly, still extract
            box["err"] = f"{type(e).__name__}: {e}"
        finally:
            done.set()

    t0 = time.time()
    th = threading.Thread(target=_run, daemon=True)
    th.start()
    finished = done.wait(a.timeout)
    timed_out = not finished
    if timed_out:
        try:
            conv.pause()           # stop the loop after the current step
        except Exception:          # noqa: BLE001
            pass
        done.wait(PAUSE_GRACE)     # let run() unwind (in-flight LLM call completes)

    es = str(getattr(conv.state, "execution_status", ""))
    if box["err"]:
        status, reason, err = "error", box["err"].split(":")[0], box["err"]
    elif timed_out:
        status, reason, err = "partial", "timeout", None
    elif "FINISHED" in es:
        status, reason, err = "complete", "finished", None
    else:
        status, reason, err = "partial", (es.split(".")[-1].lower() or "not_finished"), None

    # final checkpoint + trajectory of whatever the agent left
    try:
        _git(ws, "add", "-A")
        if _git(ws, "diff", "--cached", "--quiet").returncode != 0:
            _git(ws, "commit", "-q", "-m", "final checkpoint")
            state["ck"] += 1
    except Exception:   # noqa: BLE001
        pass
    dump_trajectory(conv)

    usage = None
    try:
        usage = json.loads(json.dumps(conv.state.agent.llm.metrics.model_dump(mode="json"), default=str))
    except Exception:   # noqa: BLE001
        usage = None

    result = {
        "model": a.model, "status": status, "reason": reason, "error": err,
        "execution_status": str(getattr(conv.state, "execution_status", None)),
        "n_events": len(conv.state.events), "checkpoints": state["ck"],
        "elapsed_sec": round(time.time() - t0, 1), "usage": usage,
    }
    with open(os.path.join(out, "result.json"), "w") as f:
        json.dump(result, f, indent=2)
    print("SESSION_RESULT_JSON: " + json.dumps({k: result[k] for k in
          ("model", "status", "reason", "n_events", "checkpoints", "elapsed_sec")}))


if __name__ == "__main__":
    main()
