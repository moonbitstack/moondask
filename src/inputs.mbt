///|
/// What a task is handed when it runs: its own arguments, and the values of the
/// dependencies it declared, keyed by their names.
///
/// Values are JSON because that is what crosses a worker boundary, so a task
/// written against this struct runs unchanged under every executor.
pub(all) struct Inputs {
  ///
  /// The task's own arguments.
  args : Json
  ///
  /// The values of its dependencies, by key.
  deps : Map[Key, Json]
  ///
  /// Which attempt this is, counting from one. An executor that retries a task
  /// after a worker died runs it again with a larger attempt, so a task can tell
  /// the first try from a repeat — which is all it takes to make a retry safe.
  attempt : Int32
}

///|
/// Inputs for a task that has no arguments and no dependencies, or for one built
/// by hand in a test.
pub fn Inputs::new(
  args~ : Json = Json::null(),
  deps~ : Map[Key, Json] = Map([]),
  attempt~ : Int32 = 1,
) -> Inputs {
  { args, deps, attempt, }
}

///|
/// The value a dependency produced.
pub fn Inputs::dep(self : Inputs, key : Key) -> Json raise Fault {
  match self.deps.get(key) {
    Some(value) => value
    None => raise Fault::MissingResult(key~)
  }
}

///|
/// A field of the task's own arguments.
pub fn Inputs::arg(self : Inputs, name : String) -> Json raise Fault {
  match self.args {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => raise Fault::Unknown(name~)
      }
    _ => raise Fault::Unknown(name~)
  }
}

///|
/// A field of the task's own arguments, as a number.
pub fn Inputs::number(self : Inputs, name : String) -> Double raise Fault {
  match self.arg(name) {
    Number(value, ..) => value
    _ => raise Fault::Unknown(name~)
  }
}

///|
/// A field of the task's own arguments, as a whole number. Arguments are JSON
/// numbers, so counts above 2^53 arrive rounded; sample counts and ranges stay
/// far below that.
pub fn Inputs::integer(self : Inputs, name : String) -> Int64 raise Fault {
  self.number(name).to_int64()
}

///|
/// A field of the task's own arguments, as text.
pub fn Inputs::text(self : Inputs, name : String) -> String raise Fault {
  match self.arg(name) {
    String(value) => value
    _ => raise Fault::Unknown(name~)
  }
}
