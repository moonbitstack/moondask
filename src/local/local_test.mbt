///|
/// A registry with three tasks: `one` always gives 1, `add` sums its
/// dependencies, `echo` gives back its arguments.
fn registry() -> @moondask.Registry {
  let registry = @moondask.Registry::new()
  registry.add("one", fn(_inputs) { Json::number(1.0) })
  registry.add("add", fn(inputs) raise {
    let mut total = 0.0
    for key in inputs.deps.keys() {
      match inputs.dep(key) {
        Number(value, ..) => total = total + value
        _ => raise @moondask.Fault::MissingResult(key="dependency")
      }
    }
    Json::number(total)
  })
  registry.add("echo", fn(inputs) { inputs.args })
  registry
}

///|
async test "a named graph runs in dependency order" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", [], name="one")
  graph.call("total", ["a", "b"], name="add")
  let runner = @local.Local::new(registry=registry())
  let outcome = runner.run(graph)
  inspect(outcome.is_ok(), content="true")
  inspect(outcome.gather(["total"]).length(), content="1")
  match outcome.get("total") {
    Number(value, ..) => inspect(value, content="2")
    _ => inspect("not a number", content="2")
  }
  inspect(outcome.keys().length(), content="3")
}

///|
async test "a closure node reads the values of its dependencies" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.closure("double", ["a"], fn(inputs) raise {
    match inputs.dep("a") {
      Number(value, ..) => Json::number(value * 2.0)
      _ => raise @moondask.Fault::MissingResult(key="a")
    }
  })
  let outcome = @local.Local::new(registry=registry()).run(graph)
  match outcome.get("double") {
    Number(value, ..) => inspect(value, content="2")
    _ => inspect("not a number", content="2")
  }
}

///|
async test "a task that raises costs its own branch only" {
  let graph = @moondask.Graph::new()
  graph.call("good", [], name="one")
  graph.closure("bad", [], fn(_inputs) raise { raise @moondask.Fault::Stopped })
  graph.call("after_bad", ["bad"], name="one")
  graph.call("after_good", ["good"], name="one")
  let outcome = @local.Local::new(registry=registry()).run(graph)
  inspect(outcome.is_ok(), content="false")
  inspect(outcome.has("good"), content="true")
  inspect(outcome.has("after_good"), content="true")
  inspect(outcome.has("after_bad"), content="false")
  inspect(outcome.skipped().join(","), content="after_bad")
  inspect(outcome.failures().contains("bad"), content="true")
}

///|
async test "an unknown name is a failure of that node" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="nobody")
  let outcome = @local.Local::new().run(graph)
  inspect(outcome.is_ok(), content="false")
  inspect(
    outcome.failures().get("a").unwrap().contains("nobody"),
    content="true",
  )
}

///|
async test "a level runs its tasks at the same time when asked to" {
  let graph = @moondask.Graph::new()
  for key in ["a", "b", "c"] {
    graph.async_closure(key, [], async fn(_inputs) {
      @async.sleep(60)
      Json::string(key)
    })
  }
  let together = @local.Local::new(concurrency=3).run(graph)
  let one_by_one = @local.Local::new(concurrency=1).run(graph)
  inspect(together.is_ok(), content="true")
  inspect(one_by_one.is_ok(), content="true")
  // Three tasks of 60 ms: together they take about one sleep, one after another
  // about three. The margin is wide so a busy machine still agrees.
  inspect(together.elapsed_us() < one_by_one.elapsed_us(), content="true")
  inspect(one_by_one.elapsed_us() >= 180_000, content="true")
}

///|
async test "cancelling before the wait runs nothing" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  let runner = @local.Local::new(registry=registry())
  let run = @moondask.submit((runner : &@moondask.Executor), graph)
  run.cancel()
  let outcome = run.wait()
  inspect(outcome.cancelled, content="true")
  inspect(outcome.is_ok(), content="false")
  inspect(outcome.has("a"), content="false")
}

///|
async test "cancelling between levels stops the rest" {
  let stop = @moondask.Cancel::new()
  let graph = @moondask.Graph::new()
  graph.closure("first", [], fn(_inputs) {
    stop.stop()
    Json::number(1.0)
  })
  graph.call("second", ["first"], name="one")
  let outcome = @local.Local::new(registry=registry()).run(graph, cancel=stop)
  inspect(outcome.cancelled, content="true")
  inspect(outcome.has("first"), content="true")
  inspect(outcome.has("second"), content="false")
}

///|
async test "the same graph run twice gives the same values" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", [], name="one")
  graph.call("total", ["a", "b"], name="add")
  let runner = @local.Local::new(registry=registry())
  let first = runner.run(graph)
  let second = runner.run(graph)
  inspect(
    @moonjson.dumps(first.to_json(), sort=true),
    content=@moonjson.dumps(second.to_json(), sort=true),
  )
}

///|
async test "map applies one task to many values" {
  let runner = @local.Local::new(registry=registry())
  let values = runner.map([Json::number(1.0), Json::number(2.0)], name="echo")
  inspect(values.length(), content="2")
  match values[0] {
    Number(value, ..) => inspect(value, content="1")
    _ => inspect("not a number", content="1")
  }
}

///|
async test "gather runs the whole graph and reads the keys asked for" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", [], name="one")
  graph.call("total", ["a", "b"], name="add")
  let runner = @local.Local::new(registry=registry())
  let values = runner.gather(graph, keys=["total"])
  match values[0] {
    Number(value, ..) => inspect(value, content="2")
    _ => inspect("not a number", content="2")
  }
}
