# minidb planted-bug map (grader's key — NOT part of the task repo)

Reference (correct) impl: scratchpad/minidb-ref — passes 20/20.
Task repo: scratchpad/minidb-task — 8/20 passing at start (12 red).

| # | file | bug | primary failing tests |
|---|------|-----|----------------------|
| B1 | wal.py | replay never checks CRC (accepts corrupt records) | wal_corrupt_middle_stops_replay |
| B2 | db.py flush | WAL reset moved BEFORE table write (durability hole) | db_crash_before_table_loses_nothing, db_crash_after_table_is_idempotent |
| B3 | sstable.py get | missing `self._keys[i] != key` exact-match check → absent key returns neighbor's value | sstable_get_and_boundaries, db_flush_then_read_and_reopen |
| B4 | sstable.py get | maps TOMBSTONE→None → deletes resurrect older values | sstable_tombstone_is_a_result, db_delete_masks_flushed_value |
| B5 | db.py scan | iterates tables reversed → oldest version wins in scan | db_scan_merges_layers |
| B6 | memtable.py items | unsorted → SSTables written out of order, bisect broken | memtable_items_sorted (+ compounds most db tests) |
| B7 | sstable.py merge | iterates reversed → oldest wins in compaction | sstable_merge_newest_wins_drops_tombstones, db_compact_single_table_result, db_no_resurrection_after_compact |

Scoring separation beyond pass/fail: tests fixed (partial credit visible in suite output),
wall time, iterations/tokens, diff minimality (surgical fix vs rewrite — compare against the
7-line reference delta), and whether fixes match the planted bugs or work around them.
