"""kvstore.core — a small key-value store.

Basic get/set/delete/len/keys work. THREE features are intentionally unimplemented (this is the
agentic-session task — see README.md):
  1. per-key TTL expiry
  2. LRU eviction when max_size is set
  3. JSON persistence (to_json / from_json)
Implement them here so tests/test_core.py passes. Do not change the tests.
"""
import time


class KVStore:
    def __init__(self, max_size=None, default_ttl=None, clock=time.monotonic):
        self.max_size = max_size
        self.default_ttl = default_ttl
        self._clock = clock
        self._data = {}        # key -> value
        # TODO(task): also track per-key expiry and access order for TTL + LRU.

    def set(self, key, value, ttl=None):
        # TODO(task): honor ttl (falling back to default_ttl), record access order, and when
        # max_size is set and exceeded, evict the least-recently-used key.
        self._data[key] = value

    def get(self, key, default=None):
        # TODO(task): treat an entry whose ttl has elapsed (per self._clock) as absent, and count
        # a successful get as a use for LRU purposes.
        return self._data.get(key, default)

    def delete(self, key):
        self._data.pop(key, None)

    def __len__(self):
        # TODO(task): expired entries must not be counted.
        return len(self._data)

    def keys(self):
        # TODO(task): in least-recently-used -> most-recently-used order, excluding expired.
        return list(self._data.keys())

    def to_json(self):
        # TODO(task): serialize values + per-key absolute expiry + access order to a JSON string.
        raise NotImplementedError("persistence: implement to_json")

    @classmethod
    def from_json(cls, text, clock=time.monotonic, max_size=None, default_ttl=None):
        # TODO(task): rebuild a KVStore from to_json output, preserving values, expiry, and order.
        raise NotImplementedError("persistence: implement from_json")
