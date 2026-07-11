#!/usr/bin/env python3
"""Spot-check the non-coder role bindings through the real serving path (local/llm.sh):
triage classification, general digest, structured JSON conformance, and codegen one-shots
(exec-graded) on every model in the queue's codegen chain.

Usage: local/spotcheck.py [section ...]     sections: triage general structured codegen
       (no args = all). OLLAMA_BASE overrides the endpoint for the codegen calls.
Exit 0 = every graded case passed.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LLM = os.path.join(ROOT, "local", "llm.sh")
QUEUE = os.path.join(ROOT, "local", "queue.sh")
BASE = os.environ.get("OLLAMA_BASE", "http://localhost:11434")
ONLY = set(sys.argv[1:])
results = {}


def wanted(name):
    return not ONLY or name in ONLY


def role(name, prompt, timeout=360):
    p = subprocess.run([LLM, name, prompt], capture_output=True, text=True,
                       timeout=timeout, cwd=ROOT)
    return (p.stdout or "").strip()


def grade(name, case, ok, got):
    results.setdefault(name, [0, 0])
    results[name][0 if ok else 1] += 1
    print(f"{'PASS' if ok else 'FAIL'} {case}" + ("" if ok else f"  -> {got[:90]!r}"))


if wanted("triage"):
    print("\n=== triage")
    TRIAGE = [
        ("Answer yes or no only: does this log line indicate a failure? 'exit code 0'", r"\bno\b"),
        ("One word - error, warning, or info: 'FATAL: could not connect to server'", r"error"),
        ("Classify in one word (code, docs, or ops): 'fix the null pointer bug in parser.py'", r"code"),
        ("Classify in one word (code, docs, or ops): 'rotate the TLS certificates'", r"ops"),
        ("Classify in one word (code, docs, or ops): 'update the API reference for v2'", r"docs"),
        ("Answer yes or no only: is 5 greater than 3?", r"\byes\b"),
        ("Answer yes or no only: is '2026-07-11' a valid ISO-8601 date?", r"\byes\b"),
        ("One word - spam or ham: 'CLICK NOW to claim your FREE prize $$$'", r"spam"),
        ("Answer yes or no only: does the command 'pytest -q' run tests?", r"\byes\b"),
        ("One word - safe or dangerous: running 'rm -rf /' as root", r"danger"),
    ]
    for prompt, pat in TRIAGE:
        got = role("triage", prompt)
        grade("triage", prompt[:48], bool(re.search(pat, got, re.I)), got)

if wanted("general"):
    print("\n=== general")
    LOG = ("2026-07-10 02:14 postgres OOM-killed on host db1 (rss 58GB), restarted by systemd; "
           "02:31 replication caught up. 09:02 deploy v2.3.1 to prod; 09:40 error rate 4x baseline "
           "on /api/checkout; 09:55 v2.3.1 rolled back to v2.3.0, error rate normal. 14:20 /var "
           "disk on web2 resized 80G->160G after pages at 92% full. Open: root-cause the checkout "
           "regression; add memory limit for postgres.")
    got = role("general", "Summarize these ops notes in at most 4 bullet points:\n\n" + LOG)
    for key, pat in [("postgres OOM", r"postgres|OOM"), ("rollback", r"roll(ed)? ?back|revert"),
                     ("disk resize", r"disk|resiz|160"), ("checkout regression", r"checkout")]:
        grade("general", f"summary mentions {key}", bool(re.search(pat, got, re.I)), got)

if wanted("structured"):
    print("\n=== structured")

    def jparse(text):
        m = re.search(r"\{.*\}|\[.*\]", text, re.S)
        return json.loads(m.group(0)) if m else None

    CASES = [
        ("Output ONLY a JSON object {\"name\": string, \"age\": number} extracted from: "
         "'Alice is 34 years old.'",
         lambda j: j and j.get("name", "").lower() == "alice" and j.get("age") == 34),
        ("Output ONLY a JSON array of the first 3 prime numbers as integers.",
         lambda j: j == [2, 3, 5]),
        ("Output ONLY JSON {\"cmd\": string, \"args\": array of strings} for: run pytest "
         "with the -q and -x flags.",
         lambda j: j and j.get("cmd") == "pytest" and sorted(j.get("args", [])) == ["-q", "-x"]),
        ("Output ONLY JSON {\"sentiment\": \"pos\" or \"neg\", \"confidence\": number 0..1} "
         "for the text: 'this is absolutely great'.",
         lambda j: j and j.get("sentiment") == "pos" and 0 <= j.get("confidence", -1) <= 1),
        ("Convert 'a=1, b=2, c=30' to ONLY a JSON object with integer values.",
         lambda j: j == {"a": 1, "b": 2, "c": 30}),
    ]
    for prompt, check in CASES:
        got = role("structured", prompt)
        try:
            ok = bool(check(jparse(got)))
        except Exception:   # noqa: BLE001
            ok = False
        grade("structured", prompt[:48], ok, got)

if wanted("codegen"):
    # every model in the queue's codegen chain, so a binding change is picked up automatically
    chain = subprocess.run([QUEUE, "classes"], capture_output=True, text=True, cwd=ROOT).stdout
    m = re.search(r"^codegen\s+(\S+)", chain, re.M)
    models = m.group(1).split(",") if m else []

    GEN_TASKS = [
        ("is_balanced", "Write a Python function is_balanced(s) that returns True iff the "
         "brackets ()[]{} in s are balanced and properly nested. Output only the code.",
         [("([]{})", True), ("([)]", False), ("", True), ("(((", False)]),
        ("rle", "Write a Python function rle(s) that run-length encodes a string: "
         "rle('aaabbc') == 'a3b2c1'. Output only the code.",
         [("aaabbc", "a3b2c1"), ("", ""), ("z", "z1")]),
    ]

    def chat(model, prompt, timeout=900):
        body = json.dumps({"model": model, "max_tokens": 8000, "temperature": 0.2,
                           "messages": [{"role": "system",
                                         "content": "Be concise. Output only the final answer, no preamble."},
                                        {"role": "user", "content": prompt}]}).encode()
        req = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        u = resp.get("usage", {})
        return (resp["choices"][0]["message"].get("content") or "", time.time() - t0,
                u.get("completion_tokens", 0))

    def run_code(text, fn, cases):
        code = re.sub(r"^```(python)?|```$", "", text.strip(), flags=re.M)
        ns = {}
        exec(code, ns)   # bench-only: executes model output (simple pure functions) locally
        return all(ns[fn](inp) == want for inp, want in cases)

    for model in models:
        name = f"codegen:{model.split('/')[-1]}"
        print(f"\n=== {name}")
        for fn, prompt, cases in GEN_TASKS:
            try:
                text, el, ctok = chat(model, prompt)
                ok = run_code(text, fn, cases)
                grade(name, f"{fn} ({el:.0f}s, {ctok} tok)", ok, text)
            except Exception as e:   # noqa: BLE001
                grade(name, fn, False, f"{type(e).__name__}: {e}")

print("\n=== summary")
bad = 0
for name, (p, f) in results.items():
    bad += f
    print(f"{name:28s} {p}/{p + f}")
sys.exit(1 if bad else 0)
