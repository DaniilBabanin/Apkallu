#!/usr/bin/env python3
"""Throughput bench for any OpenAI-compatible endpoint: generation tok/s (short prompt,
512-token generation, run twice — run 1 includes model load, run 2 is steady state) and
prompt-processing tok/s (~3k-token prompt, 1-token generation; run 2 may hit prefix cache).

Usage: bench_tps.py <base_url> <model> <label>
  e.g.: bench_tps.py http://127.0.0.1:11434/v1 ornith-1.0-35b ornith35

Writes tps-<label>.json into the current directory.
"""
import json
import sys
import time
import urllib.request

BASE, MODEL, LABEL = sys.argv[1], sys.argv[2], sys.argv[3]

PARA = ("The B-tree keeps keys in sorted order inside nodes that hold between t-1 and 2t-1 keys, "
        "splitting a full child before descending so inserts never backtrack, and merging or "
        "borrowing on deletes so occupancy never falls below the minimum degree. ")


def chat(prompt, max_tokens):
    body = json.dumps({"model": MODEL, "max_tokens": max_tokens, "temperature": 0.2,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(BASE + "/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        resp = json.load(r)
    el = time.time() - t0
    u = resp.get("usage", {})
    return el, u.get("prompt_tokens", 0), u.get("completion_tokens", 0)


rows = []
for i in (1, 2):  # run 1 warms caches/loads the model; run 2 is steady-state
    el, pt, ct = chat("Write a detailed technical essay of about 1000 words explaining how "
                      "a B-tree works, including insertion, deletion and splitting.", 512)
    rows.append(("tg", i, el, pt, ct, ct / el))
    print(f"{LABEL} tg run{i}: {ct} tok in {el:.1f}s = {ct/el:.1f} tok/s (prompt {pt})")

long_prompt = PARA * 60 + "\nIn one word, what data structure is described above?"
for i in (1, 2):  # run 1 = true prompt-processing speed; run 2 may hit the prefix cache
    el, pt, ct = chat(long_prompt, 1)
    rows.append(("pp", i, el, pt, ct, pt / el))
    print(f"{LABEL} pp run{i}: {pt} tok in {el:.1f}s = {pt/el:.0f} tok/s")

with open(f"tps-{LABEL}.json", "w") as f:
    json.dump([{"kind": k, "run": i, "sec": round(e, 2), "prompt_tokens": p,
                "completion_tokens": c, "tok_per_sec": round(t, 1)}
               for k, i, e, p, c, t in rows], f, indent=2)
