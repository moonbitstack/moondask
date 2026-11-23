# moondask

Task graphs and the executors that run them: a deterministic in-process scheduler, worker processes
that cross a JSON boundary, and OpenMP-shaped C kernels behind a thread pool.

[![mooncakes](https://img.shields.io/badge/mooncakes-moonbitstack%2Fmoondask-2f6f4e)](https://mooncakes.io/docs/moonbitstack/moondask)
[![license](https://img.shields.io/badge/license-Apache--2.0-2f6f4e)](LICENSE)

A graph is a plan: keys, the keys each one reads, and what it does. It runs nowhere until an executor
is handed one, so the same plan can be costed, printed, moved between executors, and run twice.
Swapping the executor is the only change between a laptop and a cluster.

```moonbit
test {
  let graph = @moondask.Graph::new()
  graph.call("left", [], name="sum_range", args=Json::object({
    "start": Json::number(0.0),
    "count": Json::number(1000.0),
  }))
  graph.call("right", [], name="sum_range", args=Json::object({
    "start": Json::number(1000.0),
    "count": Json::number(1000.0),
  }))
  graph.call("total", ["left", "right"], name="add")
  assert_eq(graph.topological().join(" -> "), "left -> right -> total")
}
```

## Install

```bash
moon add moonbitstack/moondask
```

```moonbit
import {
  "moonbitstack/moondask",
  "moonbitstack/moondask/local",
}
```

## The five verbs

Every executor answers the same five calls. `submit` hands over a graph, `Run::wait` waits,
`Run::cancel` stops it, `map` applies one task to many values, and `gather` reads the values of the
keys you ask for. Writing an executor means writing `run`; the rest follow from it.

```moonbit
test {
  let graph = @moondask.Graph::new()
  let parts = []
  for index in 0..<2 {
    let key = "chunk-\{index}"
    graph.call(key, [], name="echo", args=Json::number(index.to_double()))
    parts.push(key)
  }
  graph.call("total", parts, name="echo")
  // A plan that is only checked is a plan that has not run.
  assert_eq(graph.size(), 3)
}
```

`moondask/local` runs that plan in this process; `moondask/process` runs it on worker programs.

## Executors

| Executor | Where the work runs | What it is for |
|:--|:--|:--|
| `moondask/local` | the current process, one level of the graph at a time | plans, closures, tasks that suspend |
| `moondask/process` | a pool of worker programs, one request in flight per worker | parallel arithmetic, a graph bigger than one core |
| `moondask/omp` | C threads inside one call | a single loop that has to go faster |

`moondask/local` starts the nodes of a level together up to its concurrency, so a task that suspends
overlaps with its neighbours. It is not parallel: a MoonBit closure never crosses a thread, so
arithmetic on one core is what it gives. It is the only executor that runs closures.

`moondask/process` sends each node to a worker program as one JSON line and reads one JSON line back,
so only named tasks travel: a node that carries a closure is refused before the run starts. Work is
handed out as dependencies finish, and a task whose worker dies goes back on the queue for another
worker, up to `retries` times. `moondask/worker` is the other end of that protocol, and
`src/cmd/worker` is a worker that serves the kernels in `moondask/kernels`.

`moondask/omp` is the one package with C in it: `sum`, `dot`, `scale`, `axpy` and a Monte Carlo
estimate of π over flat arrays of doubles, with the thread count, the splitting schedule and core
placement as knobs. Compiled with `-fopenmp` the loops are OpenMP's; without it the same loops run on
a pool of pthreads, or of Win32 threads; with one thread they run on the caller's. `backend()` says
which of the three a build took.

## Interface

| Item | Signature | Notes |
|:--|:--|:--|
| `Key` | `String` | a node's name |
| `Task::call` | `(Key, Array[Key], name~ : String, args~ : Json) -> Task` | a named task: travels |
| `Task::closure` | `(Key, Array[Key], Handler) -> Task` | a closure: stays in the process |
| `Graph::new` | `() -> Graph` | an empty plan |
| `Graph::call` | `(Graph, Key, Array[Key], name~, args~) -> Unit raise Fault` | add a named node |
| `Graph::map` | `(Graph, String, Array[Key], name~) -> Array[Key] raise Fault` | one node per input |
| `Graph::topological` | `(Graph) -> Array[Key] raise Fault` | a runnable order, ties by insertion |
| `Graph::levels` | `(Graph) -> Array[Array[Key]] raise Fault` | the nodes that can run together |
| `Executor::run` | `(Self, Graph, cancel? : Cancel) -> Outcome raise Fault` | the one method to write |
| `Executor::map` | `(Self, Array[Json], name~) -> Array[Json] raise Fault` | one task over many values |
| `Executor::gather` | `(Self, Graph, keys~ : Array[Key]) -> Array[Json] raise Fault` | run, then read |
| `submit` | `(&Executor, Graph) -> Run` | a plan and a stop flag |
| `Run::wait` | `(Run) -> Outcome raise Fault` | run it, once |
| `Run::cancel` | `(Run) -> Unit` | stop before the nodes that have not started |
| `Outcome::get` | `(Outcome, Key) -> Json raise Fault` | a value, or why there is none |
| `Outcome::to_json` | `(Outcome) -> Json` | the whole run, comparable |
| `Registry::add` | `(Registry, String, Handler) -> Unit` | the names a worker serves |
| `Inputs::dep` | `(Inputs, Key) -> Json raise Fault` | a dependency's value |
| `Local::new` | `(registry? : Registry, concurrency? : Int) -> Local` | in-process executor |
| `Process::new` | `(worker~ : Array[String], workers~ : Int, retries~ : Int, timeout~ : Int) -> Process` | worker processes |
| `omp.sum` | `(FixedArray[Double], knobs~ : Knobs) -> Double` | a parallel reduction |
| `omp.Knobs` | `{ threads : Int, schedule : Schedule, affinity : Affinity }` | the knobs |
| `Fault` | suberror | `Duplicate`, `Missing`, `Cycle`, `Unknown`, `NotPortable`, `MissingResult`, `Failed`, `Aborted`, `Stopped` |

## What a value is

Every value a node produces is JSON. That is what makes one graph runnable under any executor, and
what makes `Outcome::to_json` comparable between them. A task reads its own arguments and the values
of its dependencies through `Inputs`:

```moonbit
test {
  let inputs = @moondask.Inputs::new(
    args=Json::object({ "alpha": Json::number(2.0) }),
    deps=Map([("x", Json::array([Json::number(1.0), Json::number(2.0)]))]),
  )
  assert_eq(inputs.number("alpha"), 2.0)
  let x = @moondask.doubles(inputs.dep("x"))
  assert_eq(x.length(), 2)
}
```

A node whose dependencies produced nothing is skipped, and its dependents are skipped with it, so one
failed branch costs its own branch and nothing else.

## Failures

A task that raises is recorded against its key and the run continues. The fault a `run` raises is
about the graph: a duplicate key, a dependency no node provides, a cycle, or a closure handed to an
executor that cannot carry it.

```moonbit
test {
  let graph = @moondask.Graph::new()
  graph.call("a", ["b"], name="add")
  graph.call("b", ["a"], name="add")
  let why = try {
    graph.validate()
    "no problem"
  } catch {
    @moondask.Cycle(keys~) => keys.join(", ")
    _ => "another fault"
  }
  assert_eq(why, "a, b")
}
```

## Examples

| Example | What it shows |
|:--|:--|
| `src/examples/01-graph` | a plan, its order, its levels, and a cycle it refuses |
| `src/examples/02-local` | one process, per-node timings |
| `src/examples/03-worker-pool` | the same graph on one process and on four workers, timed |
| `src/examples/04-parallel-kernels` | one kernel at one, two, four and all cores, timed |
| `src/examples/05-tour` | the whole surface in one run |

```bash
moon run src/examples/05-tour --target native
```

## Limits

- A closure cannot leave the process it was made in, so `moondask/process` refuses a graph that holds
  one. Write those nodes as named tasks in a registry.
- `moondask/omp` needs a C compiler and native threads; `moondask/kernels` is the same arithmetic in
  plain MoonBit and runs on every target.
- The worker protocol is one request and one reply per line, so a worker holds one task at a time and
  a value has to fit in a line.
- Adding terms in a different order changes the last digits of a floating-point reduction. A graph
  gives the same bytes under any executor; splitting a sum differently does not.

## Licence

Apache-2.0.
