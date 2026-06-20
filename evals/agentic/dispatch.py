#!/usr/bin/env python3
"""dispatch.py — PLAN.md a build phase: run K autonomous coding sessions CONCURRENTLY, one isolated VM each.

Fans out run_session.py (the a build phase per-session runner) across distinct --name VMs, bounded by a
RAM-derived concurrency cap so N VMs (4 GB each, run_session's default) fit in host memory with
headroom. The host `proxy` is started ONCE and owned here, so the concurrent children never
race to start/stop it (each child's ensure_proxy() sees the port already open and no-ops). Every
job's reviewable result lands in its own results/<id>/ exactly as in a build phase. After all jobs finish
the dispatcher reaps any leftover agentic-* VMs and asserts none remain.

  dispatch.py --jobs jobs.json [--max-concurrent N]
  dispatch.py --demo                       # K=3 kvstore sessions (the a build phase example run)

jobs.json: [{"name","repo","task"|"task_file","model"?,"verify_cmd"?,"timeout"?,"max_iterations"?}, ...]
Job names must be unique — each maps to a distinct VM (agentic-<name>) and results dir.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import run_session
import vm

HERE = vm.HERE
RUN_SESSION = os.path.join(HERE, "run_session.py")
RESULTS = os.path.join(HERE, "results")
PER_VM_MEM_MB = 4096       # run_session boots vm.up() at its 4 GB default
HOST_HEADROOM_MB = 16384   # leave for host + libvirtd + proxies + the K ssh/scp + this dispatcher


def ram_cap():
    """Max concurrent VMs that fit in host RAM with headroom (61 GB host -> ~11 at 4 GB/VM)."""
    total_mb = PER_VM_MEM_MB
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total_mb = int(line.split()[1]) // 1024
                    break
    except OSError:
        pass
    return max(1, (total_mb - HOST_HEADROOM_MB) // PER_VM_MEM_MB)


def run_one(job, ddir):
    """Run one session via run_session.py; never raises (a single job's failure must not abort the
    fan-out or skip the reaper). Returns a summary record; the child's full log lands in ddir."""
    name = job["name"]
    t0 = time.time()
    rec = {"name": name, "status": None, "outdir": None}
    try:
        cmd = [sys.executable, RUN_SESSION, "--name", name, "--repo", job["repo"],
               "--model", job.get("model") or os.environ.get("LLM_MODEL") or "<model-slug>",
               "--timeout", str(job.get("timeout", 1800)),
               "--max-iterations", str(job.get("max_iterations", 200))]
        if job.get("task_file"):
            cmd += ["--task-file", job["task_file"]]
        else:
            cmd += ["--task", job["task"]]
        if job.get("verify_cmd"):
            cmd += ["--verify-cmd", job["verify_cmd"]]
        # host backstop > run_session's own (a.timeout + 180 ssh) + boot + extraction
        p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=job.get("timeout", 1800) + 600)
        with open(os.path.join(ddir, f"{name}.log"), "w") as f:
            f.write(p.stdout)
        rec["rc"] = p.returncode
        # run_session ends with exactly one "... -> <outdir>" line; read that session's meta.json.
        m = re.findall(r"-> (\S+)\s*$", p.stdout, re.M)
        if m:
            rec["outdir"] = m[-1]
            mp = os.path.join(m[-1], "meta.json")
            if os.path.exists(mp):
                with open(mp) as f:
                    meta = json.load(f)
                rec.update(status=meta.get("status"), reason=meta.get("reason"),
                           verify=meta.get("verify"), n_events=meta.get("n_events"),
                           head_sha=meta.get("head_sha"),
                           isolation_no_hostfs=meta.get("isolation_no_hostfs"))
    except subprocess.TimeoutExpired:
        rec["status"] = "host_timeout"
    except Exception as e:   # noqa: BLE001 — record, don't propagate
        rec["status"] = f"dispatch_error: {e}"
    rec["elapsed_sec"] = round(time.time() - t0, 1)
    return rec


def demo_jobs():
    """K=3 sessions on the kvstore fixture (distinct VMs/results) — the a build phase example run."""
    repo = os.path.join(HERE, "examples", "kvstore")
    task = ("Implement the three unimplemented features in kvstore/core.py — TTL expiry, LRU "
            "eviction, and JSON persistence (to_json/from_json) — exactly as described in README.md, "
            "so that `python3 tests/test_core.py` passes every test. Do not modify the test file.")
    return [{"name": f"sess{i}", "repo": repo, "task": task,
             "verify_cmd": "python3 tests/test_core.py", "timeout": 900, "max_iterations": 100}
            for i in (1, 2, 3)]


def main():
    ap = argparse.ArgumentParser(description="concurrent isolated-session dispatcher (a build phase)")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--jobs", help="JSON file: list of job objects")
    g.add_argument("--demo", action="store_true", help="K=3 kvstore sessions (the a build phase example)")
    ap.add_argument("--max-concurrent", type=int, default=0, help="0 = RAM-derived cap")
    a = ap.parse_args()

    if a.demo:
        jobs = demo_jobs()
    else:
        with open(a.jobs) as f:
            jobs = json.load(f)
    names = [j["name"] for j in jobs]
    if len(set(names)) != len(names):
        raise SystemExit("job names must be unique (each maps to a distinct VM + results dir)")

    cap = a.max_concurrent or ram_cap()
    conc = min(len(jobs), cap)
    sid = time.strftime("%Y%m%d-%H%M%S")
    ddir = os.path.join(RESULTS, f"dispatch-{sid}")
    os.makedirs(ddir, exist_ok=True)

    proxy = run_session.ensure_proxy()   # own the shared proxy here so children don't race it
    print(f"[dispatch] {len(jobs)} jobs, concurrency {conc} (RAM cap {cap}); "
          f"proxy {'started' if proxy else 'reused'} -> {ddir}")
    started = time.time()
    results = []
    try:
        with ThreadPoolExecutor(max_workers=conc) as ex:
            futs = {ex.submit(run_one, j, ddir): j for j in jobs}
            for fut in as_completed(futs):
                r = fut.result()
                results.append(r)
                v = (r.get("verify") or {}).get("exit")
                print(f"[dispatch] done {r['name']}: status={r.get('status')} "
                      f"verify_exit={v} {r['elapsed_sec']}s")
    finally:
        vm.reap()   # safety net: kill/clean any VM a crashed child left behind
        listed = vm.virsh("list", "--all", "--name", check=False).stdout or ""
        orphans = [n for n in listed.split() if n.startswith("agentic-")]
        if proxy is not None:
            proxy.terminate()
        summary = {"id": sid, "n_jobs": len(jobs), "concurrency": conc, "ram_cap": cap,
                   "per_vm_mem_mb": PER_VM_MEM_MB, "elapsed_sec": round(time.time() - started, 1),
                   "orphans_after_reap": orphans,
                   "results": sorted(results, key=lambda r: r["name"])}
        with open(os.path.join(ddir, "summary.json"), "w") as f:
            json.dump(summary, f, indent=2)

    ok = sum(1 for r in results if r.get("status") in ("complete", "partial"))
    print(f"[dispatch] {ok}/{len(jobs)} sessions OK; orphans after reap: {len(orphans)} -> {ddir}")
    sys.exit(0 if ok == len(jobs) and not orphans else 1)


if __name__ == "__main__":
    main()
