///|
/// One node, packed for a worker: its key, the task to call, the arguments it
/// carries, and the values of its dependencies.
///
/// This is the whole of the wire format between an executor and its workers: one
/// request in, one reply out, one JSON object each, one line each.
pub(all) struct Request {
  ///
  /// Which request this is, so a reply can be matched to it.
  id : Int32
  ///
  /// The node this work belongs to.
  key : Key
  ///
  /// Which attempt at this node this is, counting from one.
  attempt : Int32
  ///
  /// The name to look up in the worker's registry.
  name : String
  ///
  /// What the task reads as its own arguments.
  args : Json
  ///
  /// The values of the dependencies, by their keys.
  deps : Map[Key, Json]
}

///|
/// A request for one node, with the values its dependencies produced.
pub fn Request::of(
  id : Int32,
  attempt : Int32,
  task : Task,
  values : Map[Key, Json],
) -> Request raise Fault {
  match task.body {
    Call(name~, args~) =>
      { id, key: task.key, attempt, name, args, deps: deps_of(task, values), }
    _ => raise Fault::NotPortable(key=task.key)
  }
}

///|
/// The inputs the request describes: its arguments, and its dependencies by name.
pub fn Request::inputs(self : Request) -> Inputs {
  Inputs::new(args=self.args, deps=self.deps, attempt=self.attempt)
}

///|
/// The request as a JSON object.
pub fn Request::to_json(self : Request) -> Json {
  let deps : Map[String, Json] = Map([])
  for key in self.deps.keys() {
    deps[key] = self.deps.get(key).unwrap()
  }
  Json::object({
    "id": Json::number(self.id.to_double()),
    "key": Json::string(self.key),
    "attempt": Json::number(self.attempt.to_double()),
    "name": Json::string(self.name),
    "args": self.args,
    "deps": Json::object(deps),
  })
}

///|
/// A request read back from its JSON object. A field that is missing or of the
/// wrong shape is refused rather than defaulted, so a version mismatch shows up
/// as an error instead of a wrong answer.
pub fn Request::from_json(json : Json) -> Request raise Fault {
  let id = number_field(json, "id").to_int()
  let key = text_field(json, "key")
  let name = text_field(json, "name")
  let attempt = number_field(json, "attempt").to_int()
  let args = match json {
    Object(fields) =>
      match fields.get("args") {
        Some(args) => args
        None => Json::null()
      }
    _ => raise Fault::Unknown(name="request")
  }
  let deps : Map[Key, Json] = Map([])
  match json {
    Object(fields) =>
      match fields.get("deps") {
        Some(Object(values)) =>
          for entry in values.keys() {
            deps[entry] = values.get(entry).unwrap()
          }
        Some(_) => raise Fault::Unknown(name="deps")
        None => ()
      }
    _ => raise Fault::Unknown(name="request")
  }
  { id, key, attempt, name, args, deps, }
}

///|
/// What the node it was asked about produced.
pub(all) struct Reply {
  ///
  /// The id of the request being answered.
  id : Int32
  ///
  /// The value, or the reason the task gave.
  outcome : Result[Json, String]
}

///|
/// The reply as a JSON object.
pub fn Reply::to_json(self : Reply) -> Json {
  match self.outcome {
    Ok(value) =>
      Json::object({
        "id": Json::number(self.id.to_double()),
        "ok": Json::boolean(true),
        "value": value,
      })
    Err(reason) =>
      Json::object({
        "id": Json::number(self.id.to_double()),
        "ok": Json::boolean(false),
        "error": Json::string(reason),
      })
  }
}

///|
/// A reply read back from its JSON object.
pub fn Reply::from_json(json : Json) -> Reply raise Fault {
  let id = number_field(json, "id").to_int()
  let ok = match json {
    Object(fields) =>
      match fields.get("ok") {
        Some(True) => true
        Some(False) => false
        _ => raise Fault::Unknown(name="reply")
      }
    _ => raise Fault::Unknown(name="reply")
  }
  if ok {
    let value = match json {
      Object(fields) =>
        match fields.get("value") {
          Some(value) => value
          None => Json::null()
        }
      _ => Json::null()
    }
    { id, outcome: Ok(value), }
  } else {
    { id, outcome: Err(text_field(json, "error")), }
  }
}

///|
/// A value as one line of text: no newlines, so a reader can split on them.
pub fn encode(value : Json) -> String {
  @moonjson.dumps(value)
}

///|
/// One line of text as a value.
pub fn decode(line : StringView) -> Json raise Fault {
  @moonjson.loads(line, @moonjson.strict) catch {
    error => raise Fault::Unknown(name=describe(error))
  }
}

///|
/// A number field of a JSON object.
fn number_field(json : Json, name : String) -> Double raise Fault {
  match json {
    Object(fields) =>
      match fields.get(name) {
        Some(Number(value, ..)) => value
        _ => raise Fault::Unknown(name~)
      }
    _ => raise Fault::Unknown(name~)
  }
}

///|
/// A text field of a JSON object.
fn text_field(json : Json, name : String) -> String raise Fault {
  match json {
    Object(fields) =>
      match fields.get(name) {
        Some(String(value)) => value
        _ => raise Fault::Unknown(name~)
      }
    _ => raise Fault::Unknown(name~)
  }
}
