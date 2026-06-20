"""Deterministic test suite for kvstore (no pytest dependency — run `python tests/test_core.py`).

Uses a FakeClock so TTL behavior is exact and reproducible. Exit 0 iff every test passes.
The agentic session must make the whole suite pass WITHOUT editing this file.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from kvstore import KVStore  # noqa: E402


class FakeClock:
    def __init__(self, t=0.0):
        self.t = t

    def __call__(self):
        return self.t


def test_basic():
    s = KVStore()
    s.set("a", 1)
    s.set("b", 2)
    assert s.get("a") == 1
    assert s.get("missing", "def") == "def"
    s.delete("a")
    assert s.get("a") is None
    assert len(s) == 1


def test_ttl_expiry():
    clk = FakeClock()
    s = KVStore(clock=clk)
    s.set("k", "v", ttl=10)
    assert s.get("k") == "v"
    clk.t = 9.9
    assert s.get("k") == "v"          # not yet expired
    clk.t = 10.1
    assert s.get("k") is None         # expired -> absent
    assert len(s) == 0                # expired entries don't count


def test_default_ttl():
    clk = FakeClock()
    s = KVStore(default_ttl=5, clock=clk)
    s.set("k", "v")                   # uses default_ttl
    clk.t = 6
    assert s.get("k") is None


def test_lru_eviction():
    s = KVStore(max_size=2)
    s.set("a", 1)
    s.set("b", 2)
    assert s.get("a") == 1            # touch a -> b is now least-recently-used
    s.set("c", 3)                     # over capacity -> evict b
    assert s.get("b") is None
    assert s.get("a") == 1
    assert s.get("c") == 3
    assert len(s) == 2


def test_persistence_roundtrip():
    clk = FakeClock()
    s = KVStore(clock=clk)
    s.set("x", 10, ttl=100)
    s.set("y", [1, 2, 3])
    text = s.to_json()
    assert isinstance(text, str)
    s2 = KVStore.from_json(text, clock=clk)
    assert s2.get("x") == 10
    assert s2.get("y") == [1, 2, 3]
    clk.t = 101
    assert s2.get("x") is None        # expiry survives the round-trip


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
