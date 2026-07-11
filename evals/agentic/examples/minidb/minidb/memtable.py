"""In-memory write buffer. Deletes are tombstones so they mask older on-disk values."""

TOMBSTONE = "__tombstone__"


class Memtable:
    def __init__(self):
        self._data = {}

    def put(self, key, value):
        self._data[key] = value

    def delete(self, key):
        self._data[key] = TOMBSTONE

    def get(self, key):
        """Value, TOMBSTONE, or None when the key is not buffered here."""
        return self._data.get(key)

    def items(self):
        """All entries (tombstones included), sorted by key."""
        return list(self._data.items())

    def clear(self):
        self._data = {}

    def __len__(self):
        return len(self._data)
