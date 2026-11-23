///|
/// The command that starts the reference worker.
///
/// The worker is a program of its own, so a test has to build it first. `moon
/// build` is run once per test process and the path it writes to is the one the
/// build directory always uses; building also keeps the worker in step with the
/// sources under test.
let worker_built : Ref[Bool] = Ref(false)

///|
async fn worker_command() -> Array[String] {
  if !worker_built.val {
    let (code, _, err) = @subprocess.collect_output(
      "moon",
      ["build", "src/cmd/worker", "--target", "native"],
      cwd=".",
    )
    if code != 0 {
      abort("the reference worker did not build:\n\{err.text()}")
    }
    worker_built.val = true
  }
  let suffix = if @async.platform is Windows { ".exe" } else { "" }
  let root = @env.current_dir().unwrap_or(".")
  ["\{root}/_build/native/debug/build/cmd/worker/worker\{suffix}"]
}

///|
/// The graph the examples and the tests share: four chunks of a sum, then a node
/// that adds them up.
fn chunks(graph : @moondask.Graph) -> Array[String] raise @moondask.Fault {
  let parts = []
  for index in 0..<4 {
    let key = "chunk-\{index}"
    graph.call(
      key,
      [],
      name="sum_range",
      args=Json::object({
        "start": Json::number((index * 500).to_double()),
        "count": Json::number(500.0),
      }),
    )
    parts.push(key)
  }
  graph.call("total", parts, name="add")
  parts
}

///|
async test "a graph runs on worker processes" {
  let graph = @moondask.Graph::new()
  chunks(graph) |> ignore
  let executor = @process.Process::new(worker=worker_command(), workers=2)
  let outcome = try {
    executor.run(graph)
  } catch {
    error => abort("the pool refused to run: \{@moondask.describe(error)}")
  }
  inspect(outcome.is_ok(), content="true")
  let in_process = @local.Local::new(registry=@kernels.registry()).run(graph)
  inspect(
    @moonjson.dumps(outcome.to_json(), sort=true),
    content=@moonjson.dumps(in_process.to_json(), sort=true),
  )
}

///|
async test "the number of workers does not change the answers" {
  let graph = @moondask.Graph::new()
  chunks(graph) |> ignore
  let one = @process.Process::new(worker=worker_command(), workers=1).run(graph)
  let four = @process.Process::new(worker=worker_command(), workers=4).run(
    graph,
  )
  inspect(
    @moonjson.dumps(one.to_json(), sort=true),
    content=@moonjson.dumps(four.to_json(), sort=true),
  )
}

///|
async test "a closure cannot be sent, and the graph is refused before it runs" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="abort")
  graph.closure("local-only", [], fn(_inputs) { Json::number(1.0) })
  let executor = @process.Process::new(worker=worker_command())
  let refusal = try {
    executor.run(graph) |> ignore
    ""
  } catch {
    @moondask.NotPortable(key~) => key
    error => @moondask.describe(error)
  }
  inspect(refusal, content="local-only")
}

///|
async test "a worker that dies holding a task is replaced and the retry answers" {
  let graph = @moondask.Graph::new()
  graph.call("fragile", [], name="fragile")
  graph.call("after", ["fragile"], name="add")
  let executor = @process.Process::new(worker=worker_command(), retries=3)
  let outcome = executor.run(graph)
  inspect(outcome.is_ok(), content="true")
  match outcome.get("fragile") {
    String(text) => inspect(text, content="survived")
    _ => inspect("not text", content="survived")
  }
}

///|
async test "a dead worker does not stop the rest of the graph" {
  let graph = @moondask.Graph::new()
  graph.call("doomed", [], name="abort")
  graph.call("after-doomed", ["doomed"], name="add")
  graph.call(
    "fine",
    [],
    name="sum_range",
    args=Json::object({
      "start": Json::number(0.0),
      "count": Json::number(10.0),
    }),
  )
  graph.call("after-fine", ["fine"], name="add")
  let executor = @process.Process::new(worker=worker_command(), retries=0)
  let outcome = executor.run(graph)
  inspect(outcome.is_ok(), content="false")
  inspect(outcome.has("after-doomed"), content="false")
  inspect(outcome.skipped().join(","), content="after-doomed")
  inspect(outcome.has("after-fine"), content="true")
  // The branch that did not touch the poisoned node matches what one process
  // computes for it.
  let in_process = @local.Local::new(registry=@kernels.registry()).run(graph)
  inspect(
    @moonjson.dumps(outcome.get("after-fine")),
    content=@moonjson.dumps(in_process.get("after-fine")),
  )
}

///|
async test "a worker that never answers is killed and the task fails" {
  let graph = @moondask.Graph::new()
  graph.call(
    "slow",
    [],
    name="sum_range",
    args=Json::object({
      "start": Json::number(0.0),
      "count": Json::number(400000000.0),
    }),
  )
  let executor = @process.Process::new(
    worker=worker_command(),
    retries=0,
    timeout=50,
  )
  let outcome = executor.run(graph)
  inspect(outcome.is_ok(), content="false")
  inspect(
    outcome.failures().get("slow").unwrap().contains("did not answer"),
    content="true",
  )
}

///|
async test "cancelling before the wait starts no worker" {
  let graph = @moondask.Graph::new()
  chunks(graph) |> ignore
  let executor = @process.Process::new(worker=worker_command(), workers=2)
  let run = @moondask.submit((executor : &@moondask.Executor), graph)
  run.cancel()
  let outcome = run.wait()
  inspect(outcome.cancelled, content="true")
  inspect(outcome.has("total"), content="false")
}

///|
async test "a task sees which attempt it is on" {
  let graph = @moondask.Graph::new()
  graph.call("fragile", [], name="fragile")
  let executor = @process.Process::new(worker=worker_command(), retries=1)
  let outcome = executor.run(graph)
  // The first attempt ended the worker; the second one answered.
  inspect(outcome.has("fragile"), content="true")
  inspect(outcome.timing_us("fragile") is Some(_), content="true")
}
