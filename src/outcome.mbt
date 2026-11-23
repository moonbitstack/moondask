///|
/// What a run produced: a value per key that ran, a reason per key that failed,
/// and the keys that were skipped because something they read failed.
///
/// A run does not stop at the first failure. A node whose dependency failed is
/// skipped, and the branches that do not read it still run, so one bad chunk
/// costs its own branch and no more.
pub(all) struct Outcome {
  ///
  /// The value every key that ran produced.
  results : Map[Key, Json]
  ///
  /// The reason every key that did not produce a value gave.
  failures : Map[Key, String]
  ///
  /// The keys not run because something they read produced nothing.
  skipped : Array[Key]
  ///
  /// Whether the run stopped because it was asked to.
  mut cancelled : Bool
  ///
  /// How long the whole run took, in microseconds.
  mut elapsed_us : Int64
  ///
  /// How long each key took, in microseconds.
  timings : Map[Key, Int64]
}

///|
/// An empty outcome, which is also what a run of an empty graph gives.
pub fn Outcome::new(elapsed_us~ : Int64 = 0) -> Outcome {
  {
    results: Map([]),
    failures: Map([]),
    skipped: [],
    cancelled: false,
    elapsed_us,
    timings: Map([]),
  }
}

///|
/// The value a key produced.
pub fn Outcome::get(self : Outcome, key : Key) -> Json raise Fault {
  match self.results.get(key) {
    Some(value) => value
    None =>
      match self.failures.get(key) {
        Some(reason) => raise Fault::Failed(key~, reason~)
        None => raise Fault::MissingResult(key~)
      }
  }
}

///|
/// The values for the given keys, in the order asked for. A key that did not
/// produce a value raises, so a partial run is never mistaken for a whole one.
pub fn Outcome::gather(
  self : Outcome,
  keys : Array[Key],
) -> Array[Json] raise Fault {
  let values = []
  for key in keys {
    values.push(self.get(key))
  }
  values
}

///|
/// Whether a key has a value.
pub fn Outcome::has(self : Outcome, key : Key) -> Bool {
  self.results.contains(key)
}

///|
/// The keys that produced a value, in the order they ran.
pub fn Outcome::keys(self : Outcome) -> Array[Key] {
  self.results.keys().collect()
}

///|
/// The keys that failed, with the reason each gave.
pub fn Outcome::failures(self : Outcome) -> Map[Key, String] {
  self.failures.copy()
}

///|
/// The keys that were skipped because a dependency failed.
pub fn Outcome::skipped(self : Outcome) -> Array[Key] {
  self.skipped.copy()
}

///|
/// Whether every node ran and produced a value.
pub fn Outcome::is_ok(self : Outcome) -> Bool {
  self.failures.is_empty() && self.skipped.is_empty() && !self.cancelled
}

///|
/// How long the run took, in microseconds.
pub fn Outcome::elapsed_us(self : Outcome) -> Int64 {
  self.elapsed_us
}

///|
/// How long one node took, in microseconds, as `None` when it did not run.
pub fn Outcome::timing_us(self : Outcome, key : Key) -> Int64? {
  self.timings.get(key)
}

///|
/// The whole run as one JSON value: the values, the failures and the skipped
/// keys. Two runs of the same graph produce the same value, which is how an
/// executor swap is checked.
pub fn Outcome::to_json(self : Outcome) -> Json {
  let results : Map[String, Json] = Map([])
  for key in self.results.keys() {
    results[key] = self.results.get(key).unwrap()
  }
  let failures : Map[String, Json] = Map([])
  for key in self.failures.keys() {
    failures[key] = Json::string(self.failures.get(key).unwrap())
  }
  Json::object({
    "results": Json::object(results),
    "failures": Json::object(failures),
    "skipped": Json::array(self.skipped.map(fn(key) { Json::string(key) })),
    "cancelled": Json::boolean(self.cancelled),
  })
}
