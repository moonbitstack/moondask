///|
/// Runs a graph in the process that holds it.
///
/// Nodes run level by level: every node of a level has all its dependencies
/// finished, and the nodes of one level start together up to the concurrency, so
/// a task that suspends — waiting on a timer, a file, a socket — overlaps with
/// its neighbours. Nothing here is parallel: a MoonBit closure never crosses a
/// thread, so arithmetic on one core is what this executor gives. For parallel
/// arithmetic use worker processes or the C kernels.
///
/// Because it runs in one process it also runs the bodies that cannot travel:
/// closures, including the ones that close over local state.
pub struct Local {
  registry : @moondask.Registry
  concurrency : Int32
}

///|
/// `concurrency` is how many tasks of a level may be in flight at once. One is
/// the default: the same graph then runs in the same order every time, which is
/// what makes a failure reproducible.
pub fn Local::new(
  registry~ : @moondask.Registry = @moondask.Registry::new(),
  concurrency~ : Int32 = 1,
) -> Local {
  { registry, concurrency: if concurrency < 1 { 1 } else { concurrency }, }
}

///|
/// How many tasks of a level run at once.
pub fn Local::concurrency(self : Local) -> Int32 {
  self.concurrency
}

///|
/// The registry the executor looks names up in.
pub fn Local::registry(self : Local) -> @moondask.Registry {
  self.registry
}

///|
/// Something to run one node and report what it produced and how long it took.
pub type Done = (@moondask.Key, Result[Json, String], Int64)

///|
pub impl @moondask.Executor for Local with fn label(_self) {
  "local"
}

///|
pub extend Local with @moondask.Executor::{label, run, map, gather}

///|
pub impl @moondask.Executor for Local with fn run(self, graph, cancel?) -> @moondask.Outcome raise @moondask.Fault {
  let cancel = cancel.unwrap_or(@moondask.Cancel::new())
  let started = @bench.monotonic_clock_start()
  let outcome = @moondask.Outcome::new()
  for level in graph.levels() {
    if cancel.is_stopped() {
      outcome.cancelled = true
      break
    }
    let ready : Array[@moondask.Task] = []
    for key in level {
      let task = graph.get(key).unwrap()
      match blocked_by(task.deps, outcome) {
        Some(dep) => {
          outcome.skipped.push(key)
          outcome.failures[key] = "skipped: \"\{dep}\" produced no value"
        }
        None => ready.push(task)
      }
    }
    if ready.is_empty() {
      continue
    }
    let runs = ready.map(fn(task) { async fn() { self.run_one(task, outcome) } })
    let dones = Ok(@async.all(runs, max_concurrent=self.concurrency)) catch {
      error => Err(error)
    }
    match dones {
      Ok(dones) =>
        for done in dones {
          let (key, result, micros) = done
          outcome.timings[key] = micros
          match result {
            Ok(value) => outcome.results[key] = value
            Err(reason) => outcome.failures[key] = reason
          }
        }
      Err(error) =>
        for task in ready {
          outcome.failures[task.key] = @moondask.describe(error)
        }
    }
  }
  outcome.elapsed_us = @bench.monotonic_clock_end(started).to_int64()
  outcome
}

///|
/// The first dependency of a node that has no value, if any.
fn blocked_by(
  deps : Array[@moondask.Key],
  outcome : @moondask.Outcome,
) -> @moondask.Key? {
  for dep in deps {
    if !outcome.results.contains(dep) {
      return Some(dep)
    }
  }
  None
}

///|
/// Run one node: its value, or the reason it raised, and the microseconds it took.
async fn Local::run_one(
  self : Local,
  task : @moondask.Task,
  outcome : @moondask.Outcome,
) -> Done noraise {
  let started = @bench.monotonic_clock_start()
  let inputs = @moondask.Inputs::new(
    args=@moondask.args_of(task.body),
    deps=@moondask.deps_of(task, outcome.results),
  )
  let result = Ok(@moondask.apply(self.registry, task.body, inputs)) catch {
    error => Err(@moondask.describe(error))
  }
  (task.key, result, @bench.monotonic_clock_end(started).to_int64())
}
