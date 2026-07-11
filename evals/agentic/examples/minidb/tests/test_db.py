"""minidb acceptance suite — DO NOT MODIFY. Exit 0 == all pass."""
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from minidb import sstable, wal  # noqa: E402
from minidb.db import DB  # noqa: E402
from minidb.memtable import TOMBSTONE, Memtable  # noqa: E402

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


class Crash(Exception):
    pass


def crasher(label):
    def fp(name):
        if name == label:
            raise Crash(label)
    return fp


# ---------- wal ----------
def t_wal_roundtrip():
    with tempfile.TemporaryDirectory() as td:
        w = wal.WAL(os.path.join(td, "w"))
        w.append({"op": "put", "key": "a", "value": 1})
        w.append({"op": "del", "key": "a"})
        w.close()
        assert wal.WAL(os.path.join(td, "w")).replay() == [
            {"op": "put", "key": "a", "value": 1}, {"op": "del", "key": "a"}]


def t_wal_torn_tail_ignored():
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "w")
        w = wal.WAL(p)
        w.append({"op": "put", "key": "a", "value": 1})
        w.append({"op": "put", "key": "b", "value": 2})
        w.close()
        raw = open(p, "rb").read()
        open(p, "wb").write(raw[:-3])          # torn last record
        assert wal.WAL(p).replay() == [{"op": "put", "key": "a", "value": 1}]


def t_wal_corrupt_middle_stops_replay():
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "w")
        w = wal.WAL(p)
        for k in ("a", "b", "c"):
            w.append({"op": "put", "key": k, "value": k})
        w.close()
        raw = bytearray(open(p, "rb").read())
        (n0,) = struct.unpack(">I", raw[0:4])
        second_payload = 8 + n0 + 4
        raw[second_payload + 2] ^= 0xFF        # flip a byte inside record 2's payload
        open(p, "wb").write(bytes(raw))
        ops = wal.WAL(p).replay()
        assert ops == [{"op": "put", "key": "a", "value": "a"}], ops


# ---------- memtable ----------
def t_memtable_tombstone_visible():
    m = Memtable()
    m.put("k", 1)
    m.delete("k")
    assert m.get("k") == TOMBSTONE
    assert m.get("other") is None


def t_memtable_items_sorted():
    m = Memtable()
    for k in ("c", "a", "b"):
        m.put(k, k.upper())
    assert m.items() == [("a", "A"), ("b", "B"), ("c", "C")]


# ---------- sstable ----------
def t_sstable_get_and_boundaries():
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "t.sst")
        sstable.write_table(p, [("b", 1), ("d", 2)])
        t = sstable.SSTable(p)
        assert t.get("b") == 1 and t.get("d") == 2
        assert t.get("a") is None      # below range
        assert t.get("c") is None      # between keys
        assert t.get("e") is None      # above range


def t_sstable_tombstone_is_a_result():
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "t.sst")
        sstable.write_table(p, [("k", TOMBSTONE)])
        assert sstable.SSTable(p).get("k") == TOMBSTONE


def t_sstable_merge_newest_wins_drops_tombstones():
    with tempfile.TemporaryDirectory() as td:
        p1, p2 = os.path.join(td, "1.sst"), os.path.join(td, "2.sst")
        sstable.write_table(p1, [("a", "old"), ("b", "keep"), ("c", "x")])
        sstable.write_table(p2, [("a", "new"), ("c", TOMBSTONE)])
        merged = sstable.merge([sstable.SSTable(p1), sstable.SSTable(p2)])
        assert merged == [("a", "new"), ("b", "keep")], merged


# ---------- db ----------
def t_db_basic_put_get_overwrite():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("k", {"v": 1})
        assert db.get("k") == {"v": 1}
        db.put("k", 2)
        assert db.get("k") == 2
        assert db.get("missing") is None


def t_db_reopen_recovers_from_wal():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("a", 1)
        db.delete("a")
        db.put("b", 2)
        db.close()
        db2 = DB(td)
        assert db2.get("a") is None and db2.get("b") == 2


def t_db_flush_then_read_and_reopen():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        for k in ("c", "a", "b"):
            db.put(k, k.upper())
        db.flush()
        assert db.get("a") == "A" and db.get("b") == "B" and db.get("c") == "C"
        assert db.get("aa") is None
        db.close()
        db2 = DB(td)
        assert db2.get("b") == "B"


def t_db_newest_layer_wins():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("k", "v1")
        db.flush()
        db.put("k", "v2")
        db.flush()
        assert db.get("k") == "v2"
        db.put("k", "v3")          # memtable beats every table
        assert db.get("k") == "v3"


def t_db_delete_masks_flushed_value():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("k", 1)
        db.flush()
        db.delete("k")
        db.flush()                 # tombstone now lives in the NEWER table
        assert db.get("k") is None
        db.close()
        assert DB(td).get("k") is None


def t_db_scan_merges_layers():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("p/1", "old")
        db.put("p/2", "two")
        db.flush()
        db.put("p/1", "new")       # newer table must win in scan
        db.flush()
        db.put("p/3", "three")     # memtable entry
        db.put("q/1", "other")
        db.delete("p/2")           # tombstone hides flushed value
        assert db.scan("p/") == [("p/1", "new"), ("p/3", "three")]
        assert [k for k, _ in db.scan()] == ["p/1", "p/3", "q/1"]


def t_db_crash_before_table_loses_nothing():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td, failpoints=crasher("flush:before_table"))
        db.put("k", "precious")
        try:
            db.flush()
            raise AssertionError("failpoint did not fire")
        except Crash:
            pass
        db2 = DB(td)               # power-loss reopen
        assert db2.get("k") == "precious"


def t_db_crash_after_table_is_idempotent():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td, failpoints=crasher("flush:after_table"))
        db.put("k", "v")
        try:
            db.flush()
            raise AssertionError("failpoint did not fire")
        except Crash:
            pass
        db2 = DB(td)
        assert db2.get("k") == "v"
        db2.put("k2", "v2")
        db2.flush()                # must not corrupt anything
        assert db2.get("k") == "v" and db2.get("k2") == "v2"


def t_db_partial_table_ignored():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("k", "safe")
        db.close()
        with open(os.path.join(td, "000099.sst"), "w") as f:
            f.write("zz\t\"junk-without-footer\"\n")
        db2 = DB(td)
        assert db2.get("k") == "safe"
        assert db2.get("zz") is None


def t_db_corrupt_wal_keeps_prefix():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("a", 1)
        db.put("b", 2)
        db.close()
        p = os.path.join(td, "wal.log")
        raw = open(p, "rb").read()
        open(p, "wb").write(raw[:-2])
        db2 = DB(td)
        assert db2.get("a") == 1 and db2.get("b") is None


def t_db_compact_single_table_result():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("k", "v1")
        db.flush()
        db.put("k", "v2")
        db.put("x", "y")
        db.flush()
        db.compact()
        assert db.get("k") == "v2" and db.get("x") == "y"
        assert len([f for f in os.listdir(td) if f.endswith(".sst")]) == 1
        db.close()
        db2 = DB(td)
        assert db2.get("k") == "v2"


def t_db_no_resurrection_after_compact():
    with tempfile.TemporaryDirectory() as td:
        db = DB(td)
        db.put("ghost", "boo")
        db.flush()
        db.delete("ghost")
        db.flush()
        db.compact()
        assert db.get("ghost") is None
        assert db.scan() == []
        db.close()
        assert DB(td).get("ghost") is None


for n, f in sorted({k: v for k, v in globals().items() if k.startswith("t_")}.items()):
    check(n[2:], f)

print(f"\n{PASS}/{PASS + FAIL} passed")
sys.exit(1 if FAIL else 0)
