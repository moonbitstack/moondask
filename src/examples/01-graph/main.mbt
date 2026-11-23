///|
/// Building a plan without running it: keys, dependencies, the order they run in,
/// and what happens when the dependencies do not form a graph.
///
/// The plan itself raises when it is inconsistent, so this `main` is allowed to
/// raise: the toolchain prints the fault and exits non-zero.
fn main raise {
  let graph = @moondask.Graph::new()
  graph.call(
    "chunk-1",
    [],
    name="sum_range",
    args=Json::object({
      "start": Json::number(0.0),
      "count": Json::number(1000.0),
    }),
  )
  graph.call(
    "chunk-2",
    [],
    name="sum_range",
    args=Json::object({
      "start": Json::number(1000.0),
      "count": Json::number(1000.0),
    }),
  )
  graph.call("total", ["chunk-1", "chunk-2"], name="add")

  println("nodes: \{graph.size()}")
  println("order: \{graph.topological().join(" -> ")}")
  for level, keys in graph.levels() {
    println("level \{level}: \{keys.join(", ")}")
  }
  println("the total waits for: \{graph.get("total").unwrap().deps.join(", ")}")

  // A graph that cannot be ordered says which keys are in the way.
  let broken = @moondask.Graph::new()
  broken.call("a", ["c"], name="add")
  broken.call("b", ["a"], name="add")
  broken.call("c", ["b"], name="add")
  let why = try {
    broken.validate()
    "no problem"
  } catch {
    error => @moondask.describe(error)
  }
  println("broken: \{why}")
}
