"""Execute a dependency graph of callables with retries and failure propagation."""
from . import graph


class Result:
    def __init__(self, status, value=None, attempts=0):
        self.status = status      # "ok" | "failed" | "skipped"
        self.value = value        # return value, or the exception when failed
        self.attempts = attempts

    def __repr__(self):
        return f"Result({self.status!r}, {self.value!r}, attempts={self.attempts})"


def run(deps, actions, retries=0, fail_fast=False):
    order = graph.topo_order(deps)
    results = {}
    aborted = False
    for name in order:
        if aborted:
            results[name] = Result("skipped")
            continue
        failed_dep = any(results[d].status != "ok" for d in deps[name])
        if failed_dep:
            results[name] = Result("skipped")
            continue
        dep_values = {d: results[d].value for d in deps[name]}
        attempts = 0
        while True:
            attempts += 1
            try:
                value = actions[name](dep_values)
                results[name] = Result("ok", value, attempts)
                break
            except Exception as e:   # noqa: BLE001
                if attempts <= retries:
                    continue
                results[name] = Result("failed", e, attempts)
                if fail_fast:
                    aborted = True
                break
    return results
