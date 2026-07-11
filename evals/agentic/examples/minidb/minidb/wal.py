"""Write-ahead log: length+CRC framed JSON records, replay of the valid prefix."""
import json
import os
import struct
import zlib


class WAL:
    def __init__(self, path):
        self.path = path
        self._f = open(path, "ab")

    def append(self, op):
        payload = json.dumps(op, sort_keys=True).encode()
        frame = struct.pack(">I", len(payload)) + payload + struct.pack(">I", zlib.crc32(payload))
        self._f.write(frame)
        self._f.flush()
        os.fsync(self._f.fileno())

    def replay(self):
        """Return ops from the longest valid prefix; a torn or corrupt record ends replay."""
        ops = []
        with open(self.path, "rb") as f:
            data = f.read()
        pos = 0
        while pos + 4 <= len(data):
            (n,) = struct.unpack(">I", data[pos:pos + 4])
            if pos + 4 + n + 4 > len(data):
                break                      # torn tail
            payload = data[pos + 4:pos + 4 + n]
            ops.append(json.loads(payload))
            pos += 8 + n
        return ops

    def reset(self):
        self._f.close()
        self._f = open(self.path, "wb")
        self._f.flush()
        os.fsync(self._f.fileno())

    def close(self):
        self._f.close()
