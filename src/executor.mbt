///|
/// A stop flag shared between the code running a graph and the code that wants
/// it stopped.
///
/// MoonBit runs one thread of control per event loop, so a plain flag is enough:
/// an executor reads it between nodes and gives up, and the values already
/// produced stay in the outcome.
pub struct Cancel {
  stopped : Ref[Bool]
}

///|
/// A flag that nothing has raised.
pub fn Cancel::new() -> Cancel {
  { stopped: Ref(false), }
}

///|
/// Ask the run to stop. Nodes already running finish; nodes not started do not.
pub fn Cancel::stop(self : Cancel) -> Unit {
  self.stopped.val = true
}

///|
/// Whether the run was asked to stop.
pub fn Cancel::is_stopped(self : Cancel) -> Bool {
  self.stopped.val
}

///|
/// Something that can run a graph: the one thing every back end provides.
///
/// An executor is handed a whole graph and runs it. Where the tasks run — the
/// current process, a pool of worker processes, a set of C threads — is the only
/// thing that differs between implementations, and the only thing a program has
/// to change to move from a laptop to a cluster.
///
/// The contract has five verbs. `submit` hands over a graph, `Run::wait` waits
/// for it, `Run::cancel` stops it, `map` applies one task to many values, and
/// `gather` reads the values of chosen keys. Only `run` has to be written; the
/// rest follow from it.
pub(open) trait Executor {
  ///|
  /// Run every node of `graph` and return what each produced. A task that raises
  /// is recorded in the outcome and its dependents are skipped; the fault raised
  /// here is about the graph as a whole — a cycle, a missing dependency, a worker
  /// that would not start.
  async fn run(Self, graph : Graph, cancel? : Cancel) -> Outcome raise Fault
  ///|
  /// A short name for timing tables and logs.
  fn label(Self) -> String
  ///|
  /// Apply one named task to each value and return the results in the order the
  /// values were given. Each value becomes the arguments of its own node.
  async fn map(Self, values : Array[Json], name~ : String) -> Array[Json] raise Fault = _
  ///|
  /// Run `graph` and read the values of `keys`. The whole graph runs, so a key
  /// that depends on nodes outside `keys` still finds them computed.
  async fn gather(Self, graph : Graph, keys~ : Array[Key]) -> Array[Json] raise Fault = _
}

///|
impl Executor with fn map(self, values, name~) {
  let graph = Graph::new()
  let keys = []
  for index, value in values {
    let key = "map-\{index}"
    graph.call(key, [], name~, args=value)
    keys.push(key)
  }
  let outcome = self.run(graph)
  outcome.gather(keys)
}

///|
impl Executor with fn gather(self, graph, keys~) {
  let outcome = self.run(graph)
  outcome.gather(keys)
}

///|
/// One hand-off of a graph to an executor: the plan, the stop flag, and the
/// outcome once it has been waited for.
///
/// The plan is not run by [`submit`]; it runs when [`Run::wait`] is called, which
/// is what makes a run cancellable before it starts and what lets a caller keep
/// adding nodes to a plan still being assembled.
pub struct Run {
  executor : &Executor
  graph : Graph
  cancel : Cancel
  outcome : Ref[Outcome?]
}

///|
/// Hand `graph` to `executor`. Nothing runs yet.
pub fn submit(executor : &Executor, graph : Graph) -> Run {
  { executor, graph, cancel: Cancel::new(), outcome: Ref(None), }
}

///|
/// Run the plan and return its outcome. Asking twice returns the first outcome
/// rather than running the graph again.
pub async fn Run::wait(self : Run) -> Outcome raise Fault {
  match self.outcome.val {
    Some(outcome) => outcome
    None => {
      let outcome = self.executor.run(self.graph, cancel=self.cancel)
      self.outcome.val = Some(outcome)
      outcome
    }
  }
}

///|
/// Stop the plan: nodes not started are not run. Before [`Run::wait`] the plan
/// never starts at all.
pub fn Run::cancel(self : Run) -> Unit {
  self.cancel.stop()
}

///|
/// Wait for the plan and read the values of `keys`.
pub async fn Run::gather(
  self : Run,
  keys : Array[Key],
) -> Array[Json] raise Fault {
  let outcome = self.wait()
  outcome.gather(keys)
}

///|
/// The plan being assembled, so more nodes can be added before it runs.
pub fn Run::graph(self : Run) -> Graph {
  self.graph
}

///|
/// The stop flag, for an executor that wants to watch it while running.
pub fn Run::cancel_flag(self : Run) -> Cancel {
  self.cancel
}
