///|
/// A task body that runs to completion without suspending. Every executor can
/// run it in the process that holds it.
pub type Handler = (Inputs) -> Json raise Error

///|
/// A task body that may suspend, for work that waits on something. Only the
/// in-process executor runs it.
pub type AsyncHandler = async (Inputs) -> Json raise Error

///|
/// What a node does when it runs.
pub(all) enum Body {
  ///
  /// A call by name: the executor looks the name up in its registry and passes
  /// the given arguments. Names travel across a process boundary; closures do
  /// not, so this is the only body a worker can be handed.
  Call(name~ : String, args~ : Json)
  ///
  /// A closure held in this process. Nothing has to be serialised, so it may
  /// close over anything; an out-of-process executor refuses it.
  Fn(Handler)
  ///
  /// A closure that may suspend between steps, run by the in-process executor
  /// with the other tasks of its level.
  Async(AsyncHandler)
}

///|
/// One node: a key, the keys it reads before it runs, and what it does.
pub(all) struct Task {
  key : Key
  deps : Array[Key]
  body : Body
}

///|
/// A node that calls a named task. `args` is what the task reads as
/// [`Inputs::args`]; its dependencies arrive under their own keys.
pub fn Task::call(
  key : Key,
  deps : Array[Key],
  name~ : String,
  args~ : Json = Json::null(),
) -> Task {
  { key, deps: unique(deps), body: Call(name~, args~), }
}

///|
/// A node that runs a closure in the process holding the graph.
pub fn Task::closure(key : Key, deps : Array[Key], body : Handler) -> Task {
  { key, deps: unique(deps), body: Fn(body), }
}

///|
/// A node that runs a closure that may suspend, in the process holding the graph.
pub fn Task::async_closure(
  key : Key,
  deps : Array[Key],
  body : AsyncHandler,
) -> Task {
  { key, deps: unique(deps), body: Async(body), }
}

///|
/// The dependencies in the order they were given, each once: a node that names
/// the same dependency twice still reads it once.
fn unique(keys : Array[Key]) -> Array[Key] {
  let seen : Map[Key, Unit] = Map([])
  let out : Array[Key] = []
  for key in keys {
    if !seen.contains(key) {
      seen[key] = ()
      out.push(key)
    }
  }
  out
}
