///|
/// Everything this library does, in one run: a plan, the same plan on one process
/// and on worker processes, and the parallel kernels underneath.
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
  let args = @env.args()
  if args.length() > 1 && args[1] == "--worker" {
    @worker.serve_stdio(@kernels.registry())
    return
  }
  let graph = @moondask.Graph::new()
  let parts = []
  for index in 0..<4 {
    let key = "chunk-\{index}"
    graph.call(
      key,
      [],
      name="sum_range",
      args=Json::object({
        "start": Json::number((index * 100_000).to_double()),
        "count": Json::number(100_000.0),
      }),
    )
    parts.push(key)
  }
  graph.call("total", parts, name="add")
  println(
    "plan: \{graph.size()} nodes, order \{graph.topological().join(" -> ")}",
  )

  let in_process = @local.Local::new(registry=@kernels.registry()).run(graph)
  println(
    "local    : \{number_of(in_process.get("total"))} in \{in_process.elapsed_us()} us",
  )

  let pool = @process.Process::new(worker=[args[0], "--worker"], workers=2)
  let across = pool.run(graph)
  println(
    "2 workers: \{number_of(across.get("total"))} in \{across.elapsed_us()} us",
  )

  println(
    "one kernel on \{@omp.available_threads()} cores: pi = \{@omp.monte_carlo_pi(4_000_000L, 7UL)}",
  )
}

///|
fn number_of(value : Json) -> String {
  match value {
    Number(number, ..) => number.to_string()
    other => other.stringify()
  }
}
