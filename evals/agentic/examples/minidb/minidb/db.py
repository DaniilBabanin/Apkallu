"""Public API: a tiny LSM-style store. Durability contract:

- Every put/delete hits the WAL (fsync) before the memtable → an accepted write survives
  a crash at any moment.
- flush() persists the memtable as a new SSTable, THEN resets the WAL. A crash between
  the two must lose nothing: recovery ignores partial tables and replays the intact WAL.
- compact() merges all tables into one (newest versions win, tombstones dropped).
- get()/scan() read newest-first: memtable, then tables newest→oldest. A tombstone in a
  newer layer masks any older value.

`failpoints` is a test hook: a callable invoked with a label at crash-critical points;
tests raise from it to simulate power loss, then reopen the directory.
"""
import os

from . import sstable
from .memtable import TOMBSTONE, Memtable
from .sstable import SSTable
from .wal import WAL


class DB:
    def __init__(self, root, failpoints=None):
        self.root = root
        self.failpoints = failpoints or (lambda name: None)
        os.makedirs(root, exist_ok=True)
        self.tables = []          # oldest -> newest
        for fn in sorted(os.listdir(root)):
            if not fn.endswith(".sst"):
                continue
            try:
                self.tables.append(SSTable(os.path.join(root, fn)))
            except ValueError:
                os.remove(os.path.join(root, fn))   # partial flush: discard, WAL has the data
        self.memtable = Memtable()
        self.wal = WAL(os.path.join(root, "wal.log"))
        for op in self.wal.replay():
            if op["op"] == "put":
                self.memtable.put(op["key"], op["value"])
            else:
                self.memtable.delete(op["key"])

    # ---- writes ----
    def put(self, key, value):
        self.wal.append({"op": "put", "key": key, "value": value})
        self.memtable.put(key, value)

    def delete(self, key):
        self.wal.append({"op": "del", "key": key})
        self.memtable.delete(key)

    # ---- reads ----
    def get(self, key):
        v = self.memtable.get(key)
        if v is None:
            for t in reversed(self.tables):        # newest table first
                v = t.get(key)
                if v is not None:
                    break
        return None if v in (None, TOMBSTONE) else v

    def scan(self, prefix=""):
        """Sorted [(key, value)] of live entries whose key starts with prefix."""
        merged = {}
        for t in reversed(self.tables):
            for key, value in t.items():
                merged[key] = value
        for key, value in self.memtable.items():   # memtable is newest of all
            merged[key] = value
        return sorted((k, v) for k, v in merged.items()
                      if k.startswith(prefix) and v != TOMBSTONE)

    # ---- maintenance ----
    def _next_table_path(self):
        n = 1 + max([int(t.path.split(os.sep)[-1].split(".")[0]) for t in self.tables] or [0])
        return os.path.join(self.root, f"{n:06d}.sst")

    def flush(self):
        if not len(self.memtable):
            return
        path = self._next_table_path()
        self.wal.reset()
        self.failpoints("flush:before_table")
        sstable.write_table(path, self.memtable.items())
        self.failpoints("flush:after_table")
        self.tables.append(SSTable(path))
        self.memtable.clear()

    def compact(self):
        if len(self.tables) < 2:
            return
        items = sstable.merge(self.tables)
        path = self._next_table_path()
        sstable.write_table(path, items)
        old = self.tables
        self.tables = [SSTable(path)]
        for t in old:
            os.remove(t.path)

    def close(self):
        self.wal.close()
