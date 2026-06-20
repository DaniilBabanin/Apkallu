#!/usr/bin/env python3
"""smoke_agent.py — runs INSIDE the work VM: drive OpenHands (SDK v1.27) headless on a trivial task
against a your provider model, with the key OFF the VM.

Inference goes to http://127.0.0.1:<port>/openai/v1 — the SSH `-R` tunnel back to the host's
proxy, which injects the real key. This process only ever holds a dummy key (`api_key="x"`).

Usage: smoke_agent.py <model-slug> <tunnel-port> <workspace-dir>
  model-slug e.g. <model-slug>   (the `openai/` prefix is added here = LiteLLM
                                              OpenAI-compatible route)
Prints one machine-readable line `SMOKE_RESULT_JSON: {...}` to stdout for the host driver to parse.
"""
import json
import os
import subprocess
import sys

from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.tools import register_default_tools

TASK = (
    "In your current working directory create two files. "
    "hello.py: when run with `python hello.py` it prints exactly `hello world` (one line). "
    "test_hello.py: a standalone test runnable with `python test_hello.py` that runs hello.py, "
    "captures its stdout, and asserts it equals `hello world\\n`; it must exit 0 on success. "
    "Then run `python test_hello.py` yourself to confirm it passes. Keep it minimal."
)


def main():
    slug, port, ws = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    os.makedirs(ws, exist_ok=True)
    register_default_tools()

    llm = LLM(
        model=f"openai/{slug}",
        base_url=f"http://127.0.0.1:{port}/openai/v1",
        api_key="x",                       # discarded by proxy; real key stays on the host
        usage_id="smoke",
        temperature=0.0,
        num_retries=3,
    )
    agent = Agent(llm=llm, tools=[Tool(name="terminal"), Tool(name="file_editor")])
    conv = Conversation(
        agent, workspace=ws,
        persistence_dir=os.path.join(ws, ".oh"),
        max_iteration_per_run=25,
    )

    err = None
    try:
        conv.send_message(TASK)
        conv.run()
    except Exception as e:                  # noqa: BLE001 — report the failure honestly, don't fake success
        err = f"{type(e).__name__}: {e}"

    # Ground-truth verification: the files exist AND the test actually passes (re-run it ourselves —
    # the model's own claim of success is untrusted).
    hello = os.path.join(ws, "hello.py")
    test = os.path.join(ws, "test_hello.py")
    test_rc = None
    if os.path.exists(test):
        test_rc = subprocess.run([sys.executable, test], cwd=ws,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    result = {
        "model": slug,
        "error": err,
        "execution_status": str(getattr(conv.state, "execution_status", None)),
        "agent_status": str(getattr(conv.state, "agent_state", None)),
        "n_events": len(conv.state.events),
        "hello_py": os.path.exists(hello),
        "test_py": os.path.exists(test),
        "test_exit": test_rc,
        "passed": bool(os.path.exists(hello) and os.path.exists(test) and test_rc == 0),
    }
    print("SMOKE_RESULT_JSON: " + json.dumps(result))


if __name__ == "__main__":
    main()
