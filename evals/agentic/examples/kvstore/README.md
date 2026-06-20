# kvstore

A small in-memory key-value store. `get` / `set` / `delete` / `len` / `keys` already work.
Three features are **unimplemented** — implement them in `kvstore/core.py` so the suite passes:

```
python tests/test_core.py     # exit 0 when all features are implemented
```

1. **TTL expiry.** `set(key, value, ttl=seconds)` makes the entry expire `ttl` seconds after it is
   set, measured by the store's injected `clock` (default `time.monotonic`). If no `ttl` is given,
   `default_ttl` applies. Once expired, the entry reads as absent (`get` returns the default) and is
   excluded from `len()` and `keys()`.
2. **LRU eviction.** When `max_size` is set, inserting a new key beyond the limit evicts the
   **least-recently-used** key. Both `set` and a successful `get` count as a use.
3. **JSON persistence.** `to_json()` returns a JSON string capturing values, per-key expiry, and
   access order; `KVStore.from_json(text, clock=..., max_size=..., default_ttl=...)` rebuilds an
   equivalent store (expiry must survive the round-trip).

Do not modify `tests/test_core.py`.
