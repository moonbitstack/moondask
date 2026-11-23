---
name: moondask
description: "Run a task graph in one process, across worker processes, or on threads: build a dependency graph of keyed tasks, pick an executor, and read the results. Use when work has dependencies and should run in parallel."
---

# moondask

```bash
moon add moonbitstack/moondask
```

```moonbit
import {
  "moonbitstack/moondask",
  "moonbitstack/moondask/local",
}
```

Four packages do the work: `moondask` (the graph, the executor contract, the worker protocol),
`moondask/local` (one process), `moondask/process` (worker processes, native only), and `moondask/omp`
(parallel C kernels, native only).

## Run a graph in this process

```moonbit
async test {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", [], name="one")
  graph.call("total", ["a", "b"], name="add")
  let registry = @moondask.Registry::new()
  registry.add("one", fn(_inputs) { Json::number(1.0) })
  registry.add("add", fn(inputs) {
    let mut total = 0.0
    for key in inputs.deps.keys() {
      match inputs.dep(key) {
        Number(value, ..) => total = total + value
        _ => ()
      }
    }
    Json::number(total)
  })
  let executor = @local.Local::new(registry~, concurrency=2)
  assert_eq(executor.gather(graph, keys=["total"]).length(), 1)
}
```

`@local.Local` is the only executor that runs closures, so `graph.closure(key, deps, fn)` is the
shortcut for work that has no name.

## Send the same graph to worker processes

A worker is a program that serves a registry over standard input and output; `moondask/worker` has
the loop, and `src/cmd/worker` is a working one to copy.

```moonbit
test {
  // In a program, not a test: `worker` is the command that starts one worker.
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="sum_range", args=Json::object({
    "start": Json::number(0.0),
    "count": Json::number(1000.0),
  }))
  assert_eq(graph.size(), 1)
}
```

Only named tasks cross the boundary: a node built with `Graph::closure` is refused with
`Fault::NotPortable` before anything runs. A worker that dies holding a task is replaced and the task
is retried, up to `retries`; `Inputs::attempt` says which try a task is on.

## Make one loop faster

```moonbit native
test {
  let values = FixedArray::make(1000, 1.0)
  let total = @omp.sum(values, knobs=@omp.Knobs::new(threads=4))
  assert_eq(total, 1000.0)
}
```

`@omp.sum`, `dot`, `scale`, `axpy` and `monte_carlo_pi` take `Knobs { threads, schedule, affinity }`.
`@omp.backend()` reports whether the build used OpenMP, the thread pool, or one thread.

## Rules that catch people out

- Every value a node produces is JSON, and a task body has to be `fn(Inputs) -> Json raise`.
- A node with a dependency that produced nothing is skipped, and so are its dependents; the run still
  finishes and `Outcome::failures()` says what went wrong where.
- `Graph::call` and `Graph::add` raise `Fault::Duplicate` for a key already in the graph.
- `Executor::run` is async: call it from an `async fn`, or use `submit` and `Run::wait`.
- `moondask/process` and `moondask/omp` are native only; the graph and `moondask/kernels` run
  everywhere.
