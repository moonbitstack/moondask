///|
using @moondask {
  type Cancel,
  type Fault,
  type Graph,
  type Key,
  type Outcome,
  type Reply,
  type Request,
  type Task,
  trait Executor,
}

///|
/// Runs a graph across a pool of worker programs, one process per worker.
///
/// Only named tasks travel: a request carries the task's name, its arguments and
/// the values of its dependencies, all as JSON, and a reply carries the value or
/// the reason it raised. A node whose body is a closure cannot be sent, so a
/// graph holding one is refused before anything starts.
///
/// Work is handed out as dependencies are satisfied rather than in waves, so a
/// chunk that finishes early frees its worker for the next one. When a worker
/// exits holding a task, the task goes back on the queue and another worker
/// picks it up, up to `retries` times; a task that kills every worker it touches
/// is recorded as failed instead of taking the run down with it.
pub struct Process {
  worker : Array[String]
  workers : Int32
  retries : Int32
  timeout : Int32
}

///|
/// `worker` is the command that starts one worker, as the shell would see it —
/// program first, arguments after — and that program must serve the protocol in
/// `moondask/worker`.
///
/// `retries` is how many times one task may be put back after a worker died
/// holding it. `timeout` is how long a worker may hold one request before it is
/// killed and the request goes back on the queue, in milliseconds, with zero
/// meaning no limit.
pub fn Process::new(
  worker~ : Array[String],
  workers~ : Int32 = 1,
  retries~ : Int32 = 2,
  timeout~ : Int32 = 0,
) -> Process {
  if worker.is_empty() {
    abort("a worker command is required")
  }
  {
    worker,
    workers: if workers < 1 {
      1
    } else {
      workers
    },
    retries: if retries < 0 {
      0
    } else {
      retries
    },
    timeout: if timeout < 0 {
      0
    } else {
      timeout
    },
  }
}

///|
/// How many workers run at once.
pub fn Process::workers(self : Process) -> Int32 {
  self.workers
}

///|
/// The command one worker is started with.
pub fn Process::worker(self : Process) -> Array[String] {
  self.worker.copy()
}

///|
/// Whether the bodies of a graph can leave this process: a name and its
/// arguments can, a closure cannot.
pub fn Process::accepts(self : Process, graph : Graph) -> Bool {
  let _ = self
  for key in graph.keys() {
    if !@moondask.portable(graph.get(key).unwrap().body) {
      return false
    }
  }
  true
}

///|
pub impl Executor for Process with fn label(_self) {
  "process"
}

///|
pub extend Process with Executor::{label, run, map, gather}

///|
pub impl Executor for Process with fn run(self, graph, cancel?) -> Outcome raise Fault {
  let cancel = cancel.unwrap_or(Cancel::new())
  for key in graph.keys() {
    if !@moondask.portable(graph.get(key).unwrap().body) {
      raise Fault::NotPortable(key~)
    }
  }
  let started = @bench.monotonic_clock_start()
  let board = Board::new(graph)
  let queue = @aqueue.Queue::Queue(kind=@aqueue.Unbounded)
  let grouped = Ok(
    @async.with_task_group(group => {
      for _ in 0..<self.workers {
        group.spawn_bg(async fn() { self.slot(group, board, queue, cancel) })
      }
      board.seed(queue)
    }),
  ) catch {
    error => Err(error)
  }
  let outcome = board.to_outcome()
  outcome.elapsed_us = @bench.monotonic_clock_end(started).to_int64()
  match (grouped, board.fatal) {
    (Err(error), _) => raise Fault::Unknown(name=@moondask.describe(error))
    (_, Some(reason)) => raise Fault::Unknown(name=reason)
    (_, None) => outcome
  }
}

///|
/// A worker process and the two pipes it is spoken to through.
priv struct Worker {
  process : @subprocess.Process
  incoming : @subprocess.ReadFromProcess
  outgoing : @subprocess.WriteToProcess
}

///|
/// What came back for a request.
priv enum Incoming {
  Line(String)
  Ended
  Late
}

///|
/// Start one worker and wire its two pipes.
async fn Process::start(
  self : Process,
  group : @async.TaskGroup[Unit],
) -> Result[Worker, String] {
  let (incoming, child_stdout) = @subprocess.read_from_process()
  let (child_stdin, outgoing) = @subprocess.write_to_process()
  let command = self.worker[0]
  let args = self.worker[1:].to_owned()
  let process = Ok(
    @subprocess.spawn(
      group,
      command,
      args,
      stdin=child_stdin,
      stdout=child_stdout,
      stderr=@stdio.stderr,
    ),
  ) catch {
    error => Err(@moondask.describe(error))
  }
  match process {
    Ok(process) => Ok({ process, incoming, outgoing, })
    Err(reason) => {
      incoming.close()
      outgoing.close()
      Err(reason)
    }
  }
}

///|
/// Let a worker go: close its input first so a well-behaved one can exit, then
/// cancel it, then close the pipe it answered on.
fn Worker::stop(self : Worker) -> Unit {
  self.outgoing.close()
  self.process.cancel()
  self.incoming.close()
}

///|
/// One line from a worker, or the news that it will not come.
async fn Worker::next(self : Worker, timeout : Int32) -> Incoming {
  if timeout <= 0 {
    return next_blocking(self)
  } else {
    next_timed(self, timeout)
  }
}

///|
/// One line, waiting as long as the worker takes.
async fn next_blocking(worker : Worker) -> Incoming {
  match read_line(worker) {
    Some(text) => Line(text)
    None => Ended
  }
}

///|
/// One line, or the news that it did not come in time.
async fn next_timed(worker : Worker, timeout : Int32) -> Incoming {
  let line : String?? = @async.with_timeout_opt(timeout, async fn() -> String? {
    read_line(worker)
  })
  match line {
    Some(Some(text)) => Line(text)
    Some(None) => Ended
    None => Late
  }
}

///|
/// One line from a worker, or nothing when the pipe is at its end.
async fn read_line(worker : Worker) -> String? {
  worker.incoming.read_until("\n")
}

///|
/// One worker's place in the run: take a task, hand it to this worker, record
/// what comes back, and do it again until the queue is empty and shut.
async fn Process::slot(
  self : Process,
  group : @async.TaskGroup[Unit],
  board : Board,
  queue : @aqueue.Queue[Task],
  cancel : Cancel,
) -> Unit {
  let mut live : Worker? = None
  for ;; {
    if cancel.is_stopped() && !board.cancelled {
      board.cancelled = true
      board.close(queue)
    }
    let task = queue.get() catch { _ => break }
    let worker = match live {
      Some(worker) => worker
      None =>
        match self.start(group) {
          Ok(worker) => {
            live = Some(worker)
            worker
          }
          Err(reason) => {
            board.fatal = Some(reason)
            board.close(queue)
            break
          }
        }
    }
    let started = @bench.monotonic_clock_start()
    let attempt = board.attempts.get(task.key).unwrap_or(0)
    let id = board.take_id()
    let request = Ok(Request::of(id, attempt + 1, task, board.results)) catch {
      error => Err(@moondask.describe(error))
    }
    match request {
      Err(reason) => {
        board.resolve(queue, task.key, Err(reason), 0)
        continue
      }
      Ok(request) => {
        let sent = try {
          worker.outgoing.write(@moondask.encode(request.to_json()) + "\n")
          true
        } catch {
          _ => false
        }
        let incoming = if sent { worker.next(self.timeout) } else { Ended }
        let micros = @bench.monotonic_clock_end(started).to_int64()
        match incoming {
          Line(text) =>
            match read_reply(text) {
              Ok(reply) => board.resolve(queue, task.key, reply.outcome, micros)
              Err(reason) => board.resolve(queue, task.key, Err(reason), micros)
            }
          Ended | Late => {
            worker.stop()
            live = None
            let attempt = board.attempts.get(task.key).unwrap_or(0) + 1
            board.attempts[task.key] = attempt
            if attempt > self.retries {
              let reason = if incoming is Late {
                "the worker did not answer within \{self.timeout} ms"
              } else {
                "the worker exited while running this task"
              }
              board.resolve(queue, task.key, Err(reason), micros)
            } else {
              board.put(queue, task)
            }
          }
        }
      }
    }
  }
  match live {
    Some(worker) => worker.stop()
    None => ()
  }
}

///|
/// A reply line read back, or the reason it could not be.
fn read_reply(text : String) -> Result[Reply, String] {
  Ok(Reply::from_json(@moondask.decode(text))) catch {
    error => Err(@moondask.describe(error))
  }
}

///|
/// What a worker and the run share: which nodes still wait for a dependency,
/// what each produced, and how much is left.
priv struct Board {
  graph : Graph
  waiting : Map[Key, Int32]
  children : Map[Key, Array[Key]]
  results : Map[Key, Json]
  failures : Map[Key, String]
  skipped : Array[Key]
  timings : Map[Key, Int64]
  attempts : Map[Key, Int32]
  mut unresolved : Int32
  mut cancelled : Bool
  mut fatal : String?
  mut last_id : Int32
}

///|
fn Board::new(graph : Graph) -> Board {
  let waiting : Map[Key, Int32] = Map([])
  let children : Map[Key, Array[Key]] = Map([])
  for key in graph.keys() {
    let task = graph.get(key).unwrap()
    waiting[key] = task.deps.length()
    for dep in task.deps {
      match children.get(dep) {
        Some(list) => list.push(key)
        None => children[dep] = [key]
      }
    }
  }
  {
    graph,
    waiting,
    children,
    results: Map([]),
    failures: Map([]),
    skipped: [],
    timings: Map([]),
    attempts: Map([]),
    unresolved: graph.size(),
    cancelled: false,
    fatal: None,
    last_id: 0,
  }
}

///|
/// A number no two requests share, so a reply can be matched to its request.
fn Board::take_id(self : Board) -> Int32 {
  self.last_id = self.last_id + 1
  self.last_id
}

///|
/// Put every node that waits for nothing on the queue.
fn Board::seed(self : Board, queue : @aqueue.Queue[Task]) -> Unit {
  for key in self.graph.keys() {
    if self.waiting.get(key).unwrap() == 0 {
      self.put(queue, self.graph.get(key).unwrap())
    }
  }
}

///|
/// Add work, unless the run is over and the queue is already shut.
fn Board::put(_self : Board, queue : @aqueue.Queue[Task], task : Task) -> Unit {
  try queue.try_put(task) |> ignore catch {
    _ => ()
  }
}

///|
/// Record what a node produced, hand out the nodes it unblocks, and shut the
/// queue once nothing is left.
fn Board::resolve(
  self : Board,
  queue : @aqueue.Queue[Task],
  key : Key,
  result : Result[Json, String],
  micros : Int64,
) -> Unit {
  self.timings[key] = micros
  match result {
    Ok(value) => self.results[key] = value
    Err(reason) => self.failures[key] = reason
  }
  self.unresolved = self.unresolved - 1
  match self.children.get(key) {
    Some(list) =>
      for child in list {
        let left = self.waiting.get(child).unwrap() - 1
        self.waiting[child] = left
        if result is Err(_) {
          self.skip(queue, child, key)
        } else if left == 0 {
          self.put(queue, self.graph.get(child).unwrap())
        }
      }
    None => ()
  }
  self.finish(queue)
}

///|
/// Mark a node and everything below it as not run, because something it reads
/// produced nothing.
fn Board::skip(
  self : Board,
  queue : @aqueue.Queue[Task],
  key : Key,
  cause : Key,
) -> Unit {
  if self.results.contains(key) || self.failures.contains(key) {
    return
  }
  self.failures[key] = "skipped: \"\{cause}\" produced no value"
  self.skipped.push(key)
  self.unresolved = self.unresolved - 1
  match self.children.get(key) {
    Some(list) =>
      for child in list {
        let left = self.waiting.get(child).unwrap() - 1
        self.waiting[child] = left
        self.skip(queue, child, key)
      }
    None => ()
  }
  self.finish(queue)
}

///|
fn Board::finish(self : Board, queue : @aqueue.Queue[Task]) -> Unit {
  if self.unresolved <= 0 {
    self.close(queue)
  }
}

///|
fn Board::close(_self : Board, queue : @aqueue.Queue[Task]) -> Unit {
  queue.close(error=Fault::Stopped)
}

///|
fn Board::to_outcome(self : Board) -> Outcome {
  let outcome = Outcome::new()
  for key in self.results.keys() {
    outcome.results[key] = self.results.get(key).unwrap()
  }
  for key in self.failures.keys() {
    outcome.failures[key] = self.failures.get(key).unwrap()
  }
  for key in self.timings.keys() {
    outcome.timings[key] = self.timings.get(key).unwrap()
  }
  for key in self.skipped {
    outcome.skipped.push(key)
  }
  outcome.cancelled = self.cancelled
  outcome
}
