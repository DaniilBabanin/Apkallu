"""taskflow acceptance suite — DO NOT MODIFY. Exit 0 == all pass."""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from taskflow import cache, cli, graph, runner  # noqa: E402

PASS = FAIL = 0


def check(name, fn):
    global PASS, FAIL
    try:
        fn()
        PASS += 1
        print(f"PASS {name}")
    except Exception as e:   # noqa: BLE001
        FAIL += 1
        print(f"FAIL {name}: {type(e).__name__}: {e}")


# ---------- graph ----------
def t_topo_linear():
    assert graph.topo_order({"a": [], "b": ["a"], "c": ["b"]}) == ["a", "b", "c"]


def t_topo_deterministic():
    deps = {"z": [], "y": [], "x": [], "m": ["z", "y", "x"]}
    assert graph.topo_order(deps) == ["x", "y", "z", "m"]
    assert graph.topo_order(deps) == ["x", "y", "z", "m"]


def t_topo_diamond():
    order = graph.topo_order({"a": [], "b": ["a"], "c": ["a"], "d": ["b", "c"]})
    assert order.index("a") < order.index("b") < order.index("d")
    assert order.index("a") < order.index("c") < order.index("d")
    assert sorted(order) == ["a", "b", "c", "d"]


def t_cycle_raises():
    try:
        graph.topo_order({"a": ["b"], "b": ["c"], "c": ["a"]})
    except graph.CycleError as e:
        assert set(e.cycle) >= {"a", "b", "c"}, e.cycle
        return
    raise AssertionError("no CycleError")


def t_self_cycle():
    try:
        graph.topo_order({"a": ["a"]})
    except graph.CycleError:
        return
    raise AssertionError("no CycleError for self-dependency")


def t_unknown_dep():
    try:
        graph.topo_order({"a": ["ghost"]})
    except graph.UnknownDependencyError as e:
        assert e.task == "a" and e.dep == "ghost"
        return
    raise AssertionError("no UnknownDependencyError")


# ---------- runner ----------
def t_run_values_flow():
    deps = {"one": [], "two": ["one"], "three": ["one", "two"]}
    actions = {"one": lambda d: 1,
               "two": lambda d: d["one"] + 1,
               "three": lambda d: d["one"] + d["two"]}
    r = runner.run(deps, actions)
    assert r["three"].status == "ok" and r["three"].value == 3
    assert r["two"].value == 2


def t_run_failure_skips_downstream():
    deps = {"a": [], "b": ["a"], "c": ["b"], "d": []}
    def boom(d): raise RuntimeError("nope")
    actions = {"a": lambda d: 1, "b": boom, "c": lambda d: 1, "d": lambda d: 4}
    r = runner.run(deps, actions)
    assert r["a"].status == "ok"
    assert r["b"].status == "failed"
    assert isinstance(r["b"].value, RuntimeError)
    assert r["c"].status == "skipped"
    assert r["d"].status == "ok" and r["d"].value == 4   # independent task still runs


def t_run_fail_fast_aborts_rest():
    deps = {"a": [], "z": []}   # alphabetical order: a then z
    def boom(d): raise ValueError("x")
    r = runner.run(deps, {"a": boom, "z": lambda d: 9}, fail_fast=True)
    assert r["a"].status == "failed"
    assert r["z"].status == "skipped"


def t_run_retries_then_ok():
    calls = {"n": 0}
    def flaky(d):
        calls["n"] += 1
        if calls["n"] < 3:
            raise OSError("flake")
        return "done"
    r = runner.run({"f": []}, {"f": flaky}, retries=2)
    assert r["f"].status == "ok" and r["f"].value == "done" and r["f"].attempts == 3


def t_run_retries_exhausted():
    def boom(d): raise OSError("always")
    r = runner.run({"f": []}, {"f": boom}, retries=2)
    assert r["f"].status == "failed" and r["f"].attempts == 3


# ---------- cache ----------
def t_cache_roundtrip():
    with tempfile.TemporaryDirectory() as td:
        c = cache.Cache(td)
        assert c.get("k" * 64) is None
        c.put("k" * 64, {"x": [1, 2]})
        assert c.get("k" * 64) == {"value": {"x": [1, 2]}}


def t_memoize_second_run_runs_nothing():
    with tempfile.TemporaryDirectory() as td:
        c = cache.Cache(td)
        deps = {"a": [], "b": ["a"]}
        actions = {"a": lambda d: 5, "b": lambda d: d["a"] * 2}
        fp = {"a": "v1", "b": "v1"}
        v1, ran1 = cache.memoize_run(c, deps, actions, fp)
        v2, ran2 = cache.memoize_run(c, deps, actions, fp)
        assert v1 == v2 == {"a": 5, "b": 10}
        assert sorted(ran1) == ["a", "b"] and ran2 == []


def t_memoize_fingerprint_invalidates_downstream():
    with tempfile.TemporaryDirectory() as td:
        c = cache.Cache(td)
        deps = {"a": [], "b": ["a"]}
        fp = {"a": "v1", "b": "v1"}
        cache.memoize_run(c, deps, {"a": lambda d: 5, "b": lambda d: d["a"] * 2}, fp)
        fp2 = {"a": "v2", "b": "v1"}
        v, ran = cache.memoize_run(c, deps, {"a": lambda d: 7, "b": lambda d: d["a"] * 2}, fp2)
        assert v == {"a": 7, "b": 14}
        assert sorted(ran) == ["a", "b"]   # b reruns because a's value changed


def t_memoize_sibling_stays_cached():
    with tempfile.TemporaryDirectory() as td:
        c = cache.Cache(td)
        deps = {"a": [], "b": [], "c": ["a"]}
        fp = {"a": "v1", "b": "v1", "c": "v1"}
        cache.memoize_run(c, deps, {"a": lambda d: 1, "b": lambda d: 2, "c": lambda d: 3}, fp)
        fp2 = {"a": "v1", "b": "v2", "c": "v1"}
        _, ran = cache.memoize_run(c, deps, {"a": lambda d: 1, "b": lambda d: 9, "c": lambda d: 3}, fp2)
        assert ran == ["b"]   # only the changed task reruns


# ---------- cli ----------
TASKFILE = """
# demo taskfile
prep:
    mkdir -p out
alpha: prep
    echo A > out/alpha.txt
beta: prep
    echo B > out/beta.txt
join: alpha beta
    cat out/alpha.txt out/beta.txt > out/join.txt
"""


def t_parse_taskfile():
    deps, commands = cli.parse_taskfile(TASKFILE)
    assert deps == {"prep": [], "alpha": ["prep"], "beta": ["prep"], "join": ["alpha", "beta"]}
    assert commands["join"].startswith("cat ")


def t_parse_multiline_command():
    deps, commands = cli.parse_taskfile("t:\n    echo one\n    echo two\n")
    assert deps == {"t": []}
    assert commands["t"] == "echo one && echo two"


def t_cli_dry_run(capdir=None):
    with tempfile.TemporaryDirectory() as td:
        tf = os.path.join(td, "Taskfile")
        open(tf, "w").write(TASKFILE)
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cli.main(["--dry-run", tf])
        assert rc == 0
        lines = buf.getvalue().split()
        assert lines.index("prep") < lines.index("alpha")
        assert lines.index("alpha") < lines.index("join")
        assert lines.index("beta") < lines.index("join")
        assert not os.path.exists(os.path.join(td, "out"))   # dry run executes nothing


def t_cli_executes():
    with tempfile.TemporaryDirectory() as td:
        tf = os.path.join(td, "Taskfile")
        open(tf, "w").write(TASKFILE)
        old = os.getcwd()
        os.chdir(td)
        try:
            import io
            from contextlib import redirect_stdout
            with redirect_stdout(io.StringIO()):
                rc = cli.main([tf])
        finally:
            os.chdir(old)
        assert rc == 0
        joined = open(os.path.join(td, "out", "join.txt")).read().split()
        assert joined == ["A", "B"]


def t_cli_failure_exit_code():
    with tempfile.TemporaryDirectory() as td:
        tf = os.path.join(td, "Taskfile")
        open(tf, "w").write("bad:\n    false\nnext: bad\n    echo never > never.txt\n")
        old = os.getcwd()
        os.chdir(td)
        try:
            import io
            from contextlib import redirect_stdout
            with redirect_stdout(io.StringIO()):
                rc = cli.main([tf])
        finally:
            os.chdir(old)
        assert rc == 1
        assert not os.path.exists(os.path.join(td, "never.txt"))


def t_cli_usage_error():
    import io
    from contextlib import redirect_stderr
    with redirect_stderr(io.StringIO()):
        assert cli.main([]) == 2


def t_cli_module_runs():
    with tempfile.TemporaryDirectory() as td:
        tf = os.path.join(td, "Taskfile")
        open(tf, "w").write("solo:\n    echo hi > hi.txt\n")
        p = subprocess.run([sys.executable, "-m", "taskflow.cli", "--dry-run", tf],
                           capture_output=True, text=True,
                           cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        assert p.returncode == 0 and p.stdout.split() == ["solo"]


for n, f in sorted({k: v for k, v in globals().items() if k.startswith("t_")}.items()):
    check(n[2:], f)

print(f"\n{PASS}/{PASS + FAIL} passed")
sys.exit(1 if FAIL else 0)
