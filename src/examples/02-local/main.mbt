///|
/// Running a graph in one process: four chunks of a sum and the node that adds
/// them, with the time each node took.
async fn main {
  run() catch {
    error => {
      eprintln(@moondask.describe(error))
      @env.exit(1)
    }
  }
}

///|
async fn run() -> Unit {
  let graph = @moondask.Graph::new()
  let parts = []
  for index in 0..<4 {
    let key = "chunk-\{index}"
    graph.call(
      key,
      [],
      name="sum_range",
      args=Json::object({
        "start": Json::number((index * 250_000).to_double()),
        "count": Json::number(250_000.0),
      }),
    )
    parts.push(key)
  }
  graph.call("total", parts, name="add")

  let executor = @local.Local::new(registry=@kernels.registry(), concurrency=2)
  let outcome = executor.run(graph)
  println("total: \{number_of(outcome.get("total"))}")
  // The same terms in one range differ in the last digits: addition is not
  // associative, so where the range was cut is visible in the rounding.
  println("summed in one range: \{@kernels.sum_range(0L, 1_000_000L)}")
  println("nodes and their time:")
  for key in graph.topological() {
    println("  \{key}: \{outcome.timing_us(key).unwrap_or(0)} us")
  }
  println("whole run: \{outcome.elapsed_us()} us")
}

///|
fn number_of(value : Json) -> String {
  match value {
    Number(number, ..) => number.to_string()
    other => other.stringify()
  }
}
