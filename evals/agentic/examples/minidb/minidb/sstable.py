"""Sorted string tables: immutable sorted key/value files with a JSON footer index.

File layout: one 'key\\tjson-value' line per entry (sorted), then a footer line
'@@INDEX@@\\t{"keys": [...], "offsets": [...]}'. A file without a complete footer is a
partial write from a crashed flush and must be ignored by recovery.
"""
import bisect
import json

from .memtable import TOMBSTONE

FOOTER_TAG = "@@INDEX@@"


def write_table(path, items):
    """items: sorted [(key, value-or-TOMBSTONE)]. Writes entries, then the footer."""
    keys, offsets = [], []
    with open(path, "w") as f:
        for key, value in items:
            keys.append(key)
            offsets.append(f.tell())
            f.write(f"{key}\t{json.dumps(value)}\n")
        f.write(f"{FOOTER_TAG}\t{json.dumps({'keys': keys, 'offsets': offsets})}\n")


class SSTable:
    def __init__(self, path):
        self.path = path
        with open(path) as f:
            lines = f.read().splitlines()
        if not lines or not lines[-1].startswith(FOOTER_TAG + "\t"):
            raise ValueError(f"no footer (partial table): {path}")
        self._index = json.loads(lines[-1].split("\t", 1)[1])
        self._keys = self._index["keys"]
        self._offsets = self._index["offsets"]

    def get(self, key):
        """Value, TOMBSTONE (a masked delete IS a result), or None when absent."""
        i = bisect.bisect_left(self._keys, key)
        if i == len(self._keys):
            return None
        with open(self.path) as f:
            f.seek(self._offsets[i])
            line = f.readline().rstrip("\n")
        value = json.loads(line.split("\t", 1)[1])
        return None if value == TOMBSTONE else value

    def items(self):
        with open(self.path) as f:
            for line in f:
                if line.startswith(FOOTER_TAG + "\t"):
                    break
                key, raw = line.rstrip("\n").split("\t", 1)
                yield key, json.loads(raw)


def merge(tables):
    """Merge tables (oldest..newest) into one sorted item list; the NEWEST version of a
    key wins. Tombstones are dropped — merge() is only used for full compaction, where
    nothing older can resurface. Returns sorted [(key, value)]."""
    latest = {}
    for t in reversed(tables):
        for key, value in t.items():
            latest[key] = value
    return sorted((k, v) for k, v in latest.items() if v != TOMBSTONE)
