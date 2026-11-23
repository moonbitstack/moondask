///|
test "a graph keeps the keys it was given" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", ["a"], name="two")
  inspect(graph.size(), content="2")
  inspect(graph.contains("a"), content="true")
  inspect(graph.contains("zzz"), content="false")
  inspect(graph.keys().join(","), content="a,b")
}

///|
test "a key may only be added once" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  let second = try {
    graph.call("a", [], name="two")
    None
  } catch {
    @moondask.Duplicate(key~) => Some(key)
    _ => None
  }
  debug_inspect(second, content="Some(\"a\")")
}

///|
test "a dependency must be provided" {
  let graph = @moondask.Graph::new()
  graph.call("b", ["a"], name="two")
  let fault = try {
    graph.topological() |> ignore
    ""
  } catch {
    @moondask.Missing(key~, dep~) => "\{key} <- \{dep}"
    error => @moondask.describe(error)
  }
  inspect(fault, content="b <- a")
}

///|
test "the order runs a node after what it reads" {
  let graph = @moondask.Graph::new()
  graph.call("total", ["left", "right"], name="add")
  graph.call("left", [], name="one")
  graph.call("right", [], name="two")
  inspect(graph.topological().join(","), content="left,right,total")
}

///|
test "the order breaks ties by insertion" {
  let graph = @moondask.Graph::new()
  for key in ["c", "a", "b"] {
    graph.call(key, [], name="one")
  }
  inspect(graph.topological().join(","), content="c,a,b")
}

///|
test "a cycle is reported with the keys in it" {
  let graph = @moondask.Graph::new()
  graph.call("a", ["c"], name="one")
  graph.call("b", ["a"], name="two")
  graph.call("c", ["b"], name="three")
  let stuck = try {
    graph.topological() |> ignore
    ""
  } catch {
    @moondask.Cycle(keys~) => keys.join(",")
    _ => "none"
  }
  inspect(stuck, content="a,b,c")
}

///|
test "a node that depends on itself is a cycle" {
  let graph = @moondask.Graph::new()
  graph.call("a", ["a"], name="one")
  let stuck = try {
    graph.validate()
    false
  } catch {
    @moondask.Cycle(_) => true
    _ => false
  }
  inspect(stuck, content="true")
}

///|
test "levels group nodes that can run together" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", [], name="one")
  graph.call("c", ["a"], name="one")
  graph.call("d", ["a", "b"], name="one")
  let levels = graph.levels()
  inspect(levels.length(), content="2")
  inspect(levels[0].join(","), content="a,b")
  inspect(levels[1].join(","), content="c,d")
}

///|
test "map gives one node per input, named after it" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("b", [], name="one")
  let mapped = graph.map("double", ["a", "b"], name="twice")
  inspect(mapped.join(","), content="double:a,double:b")
  inspect(graph.get("double:a").unwrap().deps.join(","), content="a")
  inspect(graph.size(), content="4")
}

///|
test "a copy is independent" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  let copy = graph.copy()
  copy.call("b", [], name="one")
  inspect(graph.size(), content="1")
  inspect(copy.size(), content="2")
}

///|
test "repeating a dependency reads it once" {
  let graph = @moondask.Graph::new()
  graph.call("a", [], name="one")
  graph.call("total", ["a", "a"], name="one")
  inspect(graph.get("total").unwrap().deps.length(), content="1")
}
