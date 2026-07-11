"""CLI: parse a taskfile and run its shell commands in dependency order.

Taskfile format (one task per block):
    name: dep1 dep2
        shell command line

Indented line(s) under a header are the command (joined with ' && ' if several).
Blank lines and lines starting with '#' are ignored.

Trust model: the taskfile is authored by the user running the tool (like a Makefile), so its
commands run through the shell by design — that is the feature, not an injection surface.
"""
import subprocess
import sys

from . import graph, runner


def parse_taskfile(text):
    """Return (deps, commands): {name: [deps]}, {name: command-string}."""
    deps, commands = {}, {}
    current = None
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw[0] in " \t":
            if current is None:
                raise ValueError("command line before any task header")
            cmd = raw.strip()
            commands[current] = (commands[current] + " && " + cmd) if commands.get(current) else cmd
            continue
        name, _, rest = raw.partition(":")
        current = name.strip()
        deps[current] = rest.split()
        commands[current] = ""
    return deps, commands


def main(argv):
    args = [a for a in argv if a != "--dry-run"]
    dry = len(args) != len(argv)
    if len(args) != 1:
        print("usage: taskflow [--dry-run] TASKFILE", file=sys.stderr)
        return 2
    with open(args[0]) as f:
        deps, commands = parse_taskfile(f.read())
    order = graph.topo_order(deps)
    if dry:
        for name in order:
            print(name)
        return 0
    actions = {name: (lambda _deps, c=cmd: subprocess.run(c, shell=True, check=True)
                      if c else None)
               for name, cmd in commands.items()}
    results = runner.run(deps, actions, fail_fast=True)
    ok = True
    for name in order:
        r = results[name]
        print(f"{r.status:8s} {name}")
        ok = ok and r.status == "ok"
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
