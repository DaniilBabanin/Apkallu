"""Content-addressed result cache keyed on task fingerprint + dependency results."""
import hashlib
import json
import os

from . import graph


def _key(name, payload):
    blob = json.dumps([name, payload], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest()


class Cache:
    def __init__(self, root):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def _path(self, key):
        return os.path.join(self.root, key + ".json")

    def get(self, key):
        p = self._path(key)
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return json.load(f)   # {"value": ...}

    def put(self, key, value):
        with open(self._path(key), "w") as f:
            json.dump({"value": value}, f)


def memoize_run(cache, deps, actions, fingerprints):
    """Run the graph, skipping any task whose (fingerprint + dep values) was seen before.
    Returns (values, ran) where values maps name -> value and ran is the list of task
    names actually executed (in execution order). All actions are assumed to succeed and
    return JSON-serializable values."""
    order = graph.topo_order(deps)
    values, ran = {}, []
    for name in order:
        payload = {"fp": fingerprints[name],
                   "deps": {d: values[d] for d in sorted(deps[name])}}
        key = _key(name, payload)
        hit = cache.get(key)
        if hit is not None:
            values[name] = hit["value"]
            continue
        value = actions[name]({d: values[d] for d in deps[name]})
        cache.put(key, value)
        values[name] = value
        ran.append(name)
    return values, ran
