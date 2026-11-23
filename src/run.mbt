///|
/// What a node carries as its own arguments, whatever its body is. A named task
/// carries the arguments it was built with; a closure carries none, because it
/// already closes over what it needs.
pub fn args_of(body : Body) -> Json {
  match body {
    Call(args~, ..) => args
    Fn(_) | Async(_) => Json::null()
  }
}

///|
/// The values a node reads, keyed by dependency name, taken from the values
/// produced so far. A dependency that produced nothing is left out; the caller
/// decides what that means.
pub fn deps_of(task : Task, values : Map[Key, Json]) -> Map[Key, Json] {
  let deps : Map[Key, Json] = Map([])
  for dep in task.deps {
    match values.get(dep) {
      Some(value) => deps[dep] = value
      None => ()
    }
  }
  deps
}

///|
/// Run one node's body with the inputs it was given.
pub async fn apply(
  registry : Registry,
  body : Body,
  inputs : Inputs,
) -> Json raise Error {
  match body {
    Call(name~, ..) => registry.run(name, inputs)
    Fn(handler) => handler(inputs)
    Async(handler) => handler(inputs)
  }
}

///|
/// Whether a body can be sent to another process: only a name and its arguments
/// can, because a closure is code, not data.
pub fn portable(body : Body) -> Bool {
  match body {
    Call(_) => true
    Fn(_) | Async(_) => false
  }
}
