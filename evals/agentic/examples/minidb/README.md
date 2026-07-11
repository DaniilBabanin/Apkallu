# minidb — debug a small LSM-style key-value store

`minidb/` is a tiny write-ahead-logged, SSTable-backed store (WAL → memtable → flush →
sorted tables → compaction). It once worked; **exactly 7 bugs** have crept in across its
modules. Find and fix them so the acceptance suite passes:

```
python3 tests/test_db.py     # exit 0 when the store is correct again
```

Rules:
- Do NOT modify `tests/test_db.py`.
- Fix the bugs **minimally** — do not restructure or rewrite modules; every fix should be
  a small, surgical change. The module docstrings state the intended contracts and are
  correct; trust them over the code.
- Standard library only.

The durability/read contract (also in `minidb/db.py`'s docstring):
- An accepted write (put/delete) must survive a crash at any moment.
- `flush()` persists the memtable as a new SSTable and only THEN resets the WAL; a crash
  anywhere in between must lose nothing. Recovery ignores partial tables and replays the
  WAL's longest valid prefix (a torn or corrupt record ends replay).
- Reads are newest-first: memtable, then tables newest→oldest. A tombstone in a newer
  layer masks any older value — deleted keys must never resurrect, including across
  flushes, reopens, and `compact()`.
- `scan(prefix)` returns the live, sorted view under the same newest-wins rule.
- `compact()` merges everything into one table where the newest version of each key wins.
