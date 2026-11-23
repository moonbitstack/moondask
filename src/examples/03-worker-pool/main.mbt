///|
/// The same graph on one process and on four worker processes, with the numbers
/// each took.
///
/// The driver starts workers by running this same program with `--worker`, so the
/// example needs nothing built beside it.
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
  for index in 0..<8 {
    let key = "chunk-\{index}"
    graph.call(
      key,
      [],
      name="monte_carlo_pi",
      args=Json::object({
        "samples": Json::number(4_000_000.0),
        "seed": Json::number((index + 1).to_double()),
      }),
    )
    parts.push(key)
  }
  graph.call("total", parts, name="add")

  let in_process = @local.Local::new(registry=@kernels.registry()).run(graph)
  println("local      : \{milliseconds(in_process.elapsed_us())} ms")
  let one = @process.Process::new(worker=[args[0], "--worker"], workers=1).run(
    graph,
  )
  println("1 worker   : \{milliseconds(one.elapsed_us())} ms")
  let across = @process.Process::new(worker=[args[0], "--worker"], workers=4).run(
    graph,
  )
  println("4 workers  : \{milliseconds(across.elapsed_us())} ms")
  println("same values: \{same(in_process, across)}")
  println("pi         : \{number_of(across.get("total"))}")
}

///|
fn milliseconds(micros : Int64) -> Int64 {
  micros / 1000L
}

///|
/// Whether two runs agree on every key they both produced.
fn same(a : @moondask.Outcome, b : @moondask.Outcome) -> Bool raise {
  let keys = a.keys()
  let other = b.keys()
  keys.sort()
  other.sort()
  if keys != other {
    return false
  }
  for key in keys {
    if a.get(key) != b.get(key) {
      return false
    }
  }
  true
}

///|
fn number_of(value : Json) -> String {
  match value {
    Number(number, ..) => number.to_string()
    other => other.stringify()
  }
}
