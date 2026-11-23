///|
/// Why a graph could not be built, or a value could not be read out of a run.
///
/// A task that raises does not raise this: its failure is recorded against its
/// key in the [`Outcome`] and the nodes that depend on it are skipped, so one
/// broken branch does not throw away the rest of the run.
#derive(Debug)
pub(all) suberror Fault {
  ///
  /// A node with this key is already in the graph.
  Duplicate(key~ : Key)
  ///
  /// A node depends on a key no node of the graph provides.
  Missing(key~ : Key, dep~ : Key)
  ///
  /// The dependencies form a cycle, so no order runs them.
  Cycle(keys~ : Array[Key])
  ///
  /// No handler is registered under that name.
  Unknown(name~ : String)
  ///
  /// The body cannot cross a process boundary: only named tasks travel.
  NotPortable(key~ : Key)
  ///
  /// The key has no value: the task failed or was skipped.
  MissingResult(key~ : Key)
  ///
  /// The task under this key raised, and the reason is what it said.
  Failed(key~ : Key, reason~ : String)
  ///
  /// A task asked the process running it to end, and it did.
  Aborted(reason~ : String)
  ///
  /// The run was stopped before it finished.
  Stopped
}

///|
/// A sentence saying what went wrong, for a report or a log line.
pub fn Fault::message(self : Fault) -> String {
  match self {
    Duplicate(key~) => "node \"\{key}\" is already in the graph"
    Missing(key~, dep~) =>
      "node \"\{key}\" depends on \"\{dep}\", which no node provides"
    Cycle(keys~) => "the dependencies form a cycle through \{keys.join(", ")}"
    Unknown(name~) => "no task is registered under the name \"\{name}\""
    NotPortable(key~) =>
      "node \"\{key}\" carries a closure, which an out-of-process executor cannot send"
    MissingResult(key~) => "node \"\{key}\" produced no value"
    Failed(key~, reason~) => "node \"\{key}\" failed: \{reason}"
    Aborted(reason~) => "the task ended its process: \{reason}"
    Stopped => "the run was stopped before it finished"
  }
}

///|
/// A sentence saying what went wrong for any error, including the ones raised by
/// task bodies, whose own rendering carries no field values.
pub fn describe(error : Error) -> String {
  match error {
    Duplicate(key~) => Fault::Duplicate(key~).message()
    Missing(key~, dep~) => Fault::Missing(key~, dep~).message()
    Cycle(keys~) => Fault::Cycle(keys~).message()
    Unknown(name~) => Fault::Unknown(name~).message()
    NotPortable(key~) => Fault::NotPortable(key~).message()
    MissingResult(key~) => Fault::MissingResult(key~).message()
    Failed(key~, reason~) => Fault::Failed(key~, reason~).message()
    Aborted(reason~) => Fault::Aborted(reason~).message()
    Stopped => Fault::Stopped.message()
    _ => error.to_string()
  }
}
