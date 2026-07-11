"""Dependency graph: deterministic topological order, cycle and unknown-dep detection."""


class CycleError(Exception):
    def __init__(self, cycle):
        self.cycle = cycle
        super().__init__("cycle: " + " -> ".join(cycle))


class UnknownDependencyError(Exception):
    def __init__(self, task, dep):
        self.task = task
        self.dep = dep
        super().__init__(f"task {task!r} depends on unknown task {dep!r}")


def topo_order(deps):
    for task, ds in deps.items():
        for d in ds:
            if d not in deps:
                raise UnknownDependencyError(task, d)

    order = []
    state = {}  # name -> 1 visiting, 2 done
    stack_path = []

    def visit(name):
        if state.get(name) == 2:
            return
        if state.get(name) == 1:
            i = stack_path.index(name)
            raise CycleError(stack_path[i:] + [name])
        state[name] = 1
        stack_path.append(name)
        for d in sorted(deps[name]):
            visit(d)
        stack_path.pop()
        state[name] = 2
        order.append(name)

    for name in sorted(deps):
        visit(name)
    return order
