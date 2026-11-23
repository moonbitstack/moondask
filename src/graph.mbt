///|
/// A set of keyed tasks and the dependencies between them: the plan an executor
/// runs.
///
/// A graph is only a plan. Nothing runs until an executor is handed one, so the
/// same graph can be costed, printed, moved between executors, and run twice.
pub struct Graph {
  order : Array[Key]
  nodes : Map[Key, Task]
}

///|
/// An empty graph.
pub fn Graph::new() -> Graph {
  { order: [], nodes: Map([]), }
}

///|
/// Whether a node with this key is in the graph.
pub fn Graph::contains(self : Graph, key : Key) -> Bool {
  self.nodes.contains(key)
}

///|
/// How many nodes the graph has.
pub fn Graph::size(self : Graph) -> Int32 {
  self.order.length()
}

///|
/// The keys in the order the nodes were added, which is also the order ties are
/// broken in when the graph is ordered.
pub fn Graph::keys(self : Graph) -> Array[Key] {
  self.order.copy()
}

///|
/// The node filed under a key.
pub fn Graph::get(self : Graph, key : Key) -> Task? {
  self.nodes.get(key)
}

///|
/// Add a node. A key may only be used once: two nodes producing the same key
/// would make what a dependent reads depend on execution order.
pub fn Graph::add(self : Graph, task : Task) -> Unit raise Fault {
  if self.nodes.contains(task.key) {
    raise Fault::Duplicate(key=task.key)
  }
  self.nodes[task.key] = task
  self.order.push(task.key)
}

///|
/// Add a node that calls a named task. The name is looked up in the registry of
/// whichever executor runs the graph.
pub fn Graph::call(
  self : Graph,
  key : Key,
  deps : Array[Key],
  name~ : String,
  args~ : Json = Json::null(),
) -> Unit raise Fault {
  self.add(Task::call(key, deps, name~, args~))
}

///|
/// Add a node that runs a closure. Only the in-process executor runs it; the
/// others refuse the graph with [`Fault::NotPortable`].
pub fn Graph::closure(
  self : Graph,
  key : Key,
  deps : Array[Key],
  body : Handler,
) -> Unit raise Fault {
  self.add(Task::closure(key, deps, body))
}

///|
/// Add a node that runs a closure that may suspend.
pub fn Graph::async_closure(
  self : Graph,
  key : Key,
  deps : Array[Key],
  body : AsyncHandler,
) -> Unit raise Fault {
  self.add(Task::async_closure(key, deps, body))
}

///|
/// Add one node per input, each reading that input under the same key and
/// calling the same named task. The keys come back in input order, ready to be
/// gathered or reduced by a node that depends on them all.
///
/// ```mbt check
/// test {
///   let graph = @moondask.Graph::new()
///   graph.call("chunk-1", [], name="sum")
///   graph.call("chunk-2", [], name="sum")
///   let squares = graph.map("square", ["chunk-1", "chunk-2"], name="square")
///   inspect(squares.join(", "), content="square:chunk-1, square:chunk-2")
/// }
/// ```
pub fn Graph::map(
  self : Graph,
  prefix : String,
  inputs : Array[Key],
  name~ : String,
  args~ : Json = Json::null(),
) -> Array[Key] raise Fault {
  let keys = []
  for input in inputs {
    let key = "\{prefix}:\{input}"
    self.call(key, [input], name~, args~)
    keys.push(key)
  }
  keys
}

///|
/// Add one closure node per input, the closure counterpart of [`Graph::map`].
pub fn Graph::map_with(
  self : Graph,
  prefix : String,
  inputs : Array[Key],
  body : Handler,
) -> Array[Key] raise Fault {
  let keys = []
  for input in inputs {
    let key = "\{prefix}:\{input}"
    self.closure(key, [input], body)
    keys.push(key)
  }
  keys
}

///|
/// Every key in an order that runs a node after the nodes it depends on.
///
/// Ties are broken by the order nodes were added, so the same graph always gives
/// the same order, and a local run and a distributed run visit nodes the same way.
pub fn Graph::topological(self : Graph) -> Array[Key] raise Fault {
  for key in self.order {
    let task = self.nodes.get(key).unwrap()
    for dep in task.deps {
      if !self.nodes.contains(dep) {
        raise Fault::Missing(key~, dep~)
      }
    }
  }
  let waiting : Map[Key, Int32] = Map([])
  let children : Map[Key, Array[Key]] = Map([])
  for key in self.order {
    waiting[key] = self.nodes.get(key).unwrap().deps.length()
  }
  for key in self.order {
    for dep in self.nodes.get(key).unwrap().deps {
      match children.get(dep) {
        Some(list) => list.push(key)
        None => children[dep] = [key]
      }
    }
  }
  let order : Array[Key] = []
  for key in self.order {
    if waiting.get(key).unwrap() == 0 {
      order.push(key)
    }
  }
  let mut index = 0
  while index < order.length() {
    let key = order[index]
    index += 1
    match children.get(key) {
      Some(list) =>
        for child in list {
          let left = waiting.get(child).unwrap() - 1
          waiting[child] = left
          if left == 0 {
            order.push(child)
          }
        }
      None => ()
    }
  }
  if order.length() != self.order.length() {
    let stuck = []
    for key in self.order {
      if !order.contains(key) {
        stuck.push(key)
      }
    }
    raise Fault::Cycle(keys=stuck)
  }
  order
}

///|
/// The nodes grouped into levels: level 0 has no dependencies, and every node of
/// level n depends only on nodes of levels below n. A level's nodes can run at
/// the same time; levels themselves are ordered.
pub fn Graph::levels(self : Graph) -> Array[Array[Key]] raise Fault {
  let depth : Map[Key, Int32] = Map([])
  for key in self.topological() {
    let mut level = 0
    for dep in self.nodes.get(key).unwrap().deps {
      let below = depth.get(dep).unwrap() + 1
      if below > level {
        level = below
      }
    }
    depth[key] = level
  }
  let levels : Array[Array[Key]] = []
  for key in self.order {
    let level = depth.get(key).unwrap()
    while levels.length() <= level {
      levels.push([])
    }
    levels[level].push(key)
  }
  levels
}

///|
/// Whether the graph can be run: every dependency is provided and no cycle
/// blocks the order. Raises the same fault [`Graph::topological`] would.
pub fn Graph::validate(self : Graph) -> Unit raise Fault {
  self.topological() |> ignore
}

///|
/// An independent copy: adding nodes to the copy leaves the original alone.
pub fn Graph::copy(self : Graph) -> Graph {
  let nodes : Map[Key, Task] = Map([])
  for key in self.order {
    nodes[key] = self.nodes.get(key).unwrap()
  }
  { order: self.order.copy(), nodes, }
}
