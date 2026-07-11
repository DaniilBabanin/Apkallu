# taskflow — implement a small DAG task runner

Implement the four modules in `taskflow/` so the acceptance suite passes:

```
python3 tests/test_all.py     # exit 0 when everything is implemented
```

Do NOT modify `tests/test_all.py`. Standard library only.

## taskflow/graph.py

- `topo_order(deps: dict[str, list[str]]) -> list[str]` — topological order of all tasks.
  - Deterministic: among tasks whose dependencies are all satisfied, alphabetical order decides.
    (Equivalently: depth-first over task names in sorted order, visiting each task's deps in
    sorted order, post-order emit.)
  - `CycleError(cycle)` raised on any dependency cycle (including self-dependency). The exception
    exposes a `.cycle` attribute: the list of task names forming the cycle.
  - `UnknownDependencyError(task, dep)` raised when `task` names a `dep` that is not a key of
    `deps`. Exposes `.task` and `.dep` attributes.

## taskflow/runner.py

- `Result` — object with `.status` (`"ok" | "failed" | "skipped"`), `.value`, `.attempts`.
  - ok: `.value` is the action's return value.
  - failed: `.value` is the exception instance that ended the last attempt.
  - skipped: task never ran (a dependency was not ok, or the run was aborted by fail_fast).
- `run(deps, actions, retries=0, fail_fast=False) -> dict[str, Result]`
  - Executes `actions[name](dep_values)` in `topo_order`, where `dep_values` maps each direct
    dependency name to its Result value.
  - A task whose any direct dependency is not `ok` is `skipped` (does not run).
  - `retries=N`: on exception, retry up to N more times; `.attempts` counts all attempts.
  - `fail_fast=True`: after a task ends `failed`, every task later in the order is `skipped`
    (even independent ones). With `fail_fast=False`, independent tasks still run.

## taskflow/cache.py

- `Cache(root_dir)` — persistent key→value store under `root_dir`.
  - `put(key, value)` stores a JSON-serializable value; `get(key)` returns `{"value": value}`
    or `None` when absent. Survives across `Cache` instances on the same dir.
- `memoize_run(cache, deps, actions, fingerprints) -> (values, ran)`
  - Like a build system: runs tasks in `topo_order`, but a task is SKIPPED (result reused from
    cache) when the same combination of (task name, its fingerprint from `fingerprints[name]`,
    and the values of its direct dependencies) has been cached before.
  - Returns `values` (name → value for ALL tasks) and `ran` (names actually executed, in
    execution order). A fingerprint change must re-run the task; a changed task value must
    re-run its dependents; unrelated tasks must stay cached. Actions here always succeed and
    return JSON-serializable values.

## taskflow/cli.py

Taskfile text format:

```
# comment
name: dep1 dep2
    shell command
```

- A non-indented `name: deps...` line starts a task (deps space-separated, may be empty).
- Indented lines under it are its shell command; multiple indented lines join with ` && `.
- Blank lines and `#` comments are ignored.
- `parse_taskfile(text) -> (deps, commands)` — `{name: [deps]}`, `{name: command_string}`.
- `main(argv) -> int` (argv excludes the program name):
  - `main(["--dry-run", path])` — print the topo order, one task name per line, run nothing,
    return 0.
  - `main([path])` — run each task's command through the shell in dependency order with
    fail_fast semantics; print one status line per task; return 0 if all ok, else 1.
  - No/too many positional args: print usage to stderr, return 2.
- `python3 -m taskflow.cli --dry-run Taskfile` must work (module runnable).

The taskfile is authored by the user running the tool (a Makefile-like trust model), so
executing its commands through the shell is the intended behavior.
