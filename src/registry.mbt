///|
/// The tasks a worker can be asked to run, by name.
///
/// A name is what travels between processes: the executor sends the name, the
/// arguments and the dependencies' values, and the process that holds the
/// registry runs the matching function. Two processes agree on a graph when they
/// agree on its names.
pub struct Registry {
  table : Map[String, Handler]
}

///|
/// A registry with nothing in it.
pub fn Registry::new() -> Registry {
  { table: Map([]), }
}

///|
/// Give a name to a task body. Adding the same name twice replaces the earlier
/// body, so a worker can start from a shared registry and override what it wants.
pub fn Registry::add(self : Registry, name : String, handler : Handler) -> Unit {
  self.table[name] = handler
}

///|
/// Whether a name is taken.
pub fn Registry::contains(self : Registry, name : String) -> Bool {
  self.table.contains(name)
}

///|
/// The names in the registry, in the order they were added.
pub fn Registry::names(self : Registry) -> Array[String] {
  self.table.keys().collect()
}

///|
/// Run the task under `name`.
pub fn Registry::run(
  self : Registry,
  name : String,
  inputs : Inputs,
) -> Json raise Error {
  match self.table.get(name) {
    Some(handler) => handler(inputs)
    None => raise Fault::Unknown(name~)
  }
}

///|
/// A registry of one: the smallest useful graph runs without a second name.
pub fn Registry::of(name : String, handler : Handler) -> Registry {
  let registry = Registry::new()
  registry.add(name, handler)
  registry
}
