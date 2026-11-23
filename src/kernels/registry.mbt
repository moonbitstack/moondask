///|
/// The kernels the reference worker serves, by name.
///
/// Every one is a function of its arguments alone, so a graph built on them
/// produces the same values whatever runs it. Two of them exist to exercise the
/// boundary: `abort` ends the worker process outright, and `fragile` does the
/// same on its first attempt only, which is a worker dying in the middle of a
/// task and the retry then succeeding.
pub fn registry() -> @moondask.Registry {
  let registry = @moondask.Registry::new()
  registry.add("monte_carlo_pi", pi_task)
  registry.add("sum_range", sum_task)
  registry.add("dot", dot_task)
  registry.add("add", add_task)
  registry.add("abort", abort_task)
  registry.add("fragile", fragile_task)
  registry
}

///|
fn pi_task(inputs : @moondask.Inputs) -> Json raise {
  let samples = inputs.integer("samples")
  let seed = inputs.integer("seed").reinterpret_as_uint64()
  Json::number(monte_carlo_pi(samples, seed))
}

///|
fn sum_task(inputs : @moondask.Inputs) -> Json raise {
  let start = inputs.integer("start")
  let count = inputs.integer("count")
  Json::number(sum_range(start, count))
}

///|
fn dot_task(inputs : @moondask.Inputs) -> Json raise {
  let a = @moondask.doubles(inputs.arg("a"))
  let b = @moondask.doubles(inputs.arg("b"))
  Json::number(dot(a, b))
}

///|
/// Add the values of every dependency, which is how a chunked sum is finished.
fn add_task(inputs : @moondask.Inputs) -> Json raise {
  let mut total = 0.0
  for key in inputs.deps.keys() {
    match inputs.dep(key) {
      Number(value, ..) => total = total + value
      _ => ()
    }
  }
  Json::number(total)
}

///|
/// End the worker process, without unwinding anything.
fn abort_task(_inputs : @moondask.Inputs) -> Json raise {
  raise @moondask.Fault::Aborted(reason="the task asked to end its worker")
}

///|
/// End the worker process on the first attempt and answer on every later one, so
/// a retry has something to succeed at.
fn fragile_task(inputs : @moondask.Inputs) -> Json raise {
  if inputs.attempt <= 1 {
    raise @moondask.Fault::Aborted(reason="the first attempt ends its worker")
  }
  Json::string("survived")
}
