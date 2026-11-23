///|
/// A registry that answers with what it was given, so a test can see the whole
/// request arrive.
fn echoing() -> @moondask.Registry {
  let registry = @moondask.Registry::new()
  registry.add("echo", fn(inputs) {
    Json::object({
      "attempt": Json::number(inputs.attempt.to_double()),
      "args": inputs.args,
      "deps": Json::object(inputs.deps),
    })
  })
  registry.add("boom", fn(_inputs) raise { raise @moondask.Fault::Stopped })
  registry.add("end", fn(_inputs) raise {
    raise @moondask.Fault::Aborted(reason="test")
  })
  registry
}

///|
/// One request line, as the executor writes it: written out by hand so the test
/// pins the wire format rather than the encoder that produces it.
fn request_line() -> String {
  let line =
    #|{"id":7,"key":"a","attempt":2,"name":"echo","args":{"x":1},"deps":{"b":2}}
  line
}

///|
test "a request is answered with the task's value" {
  let line = @worker.handle(echoing(), request_line())
  let reply = @moondask.Reply::from_json(@moondask.decode(line))
  inspect(reply.id, content="7")
  match reply.outcome {
    Ok(Object(fields)) => {
      match fields.get("attempt") {
        Some(Number(value, ..)) => inspect(value, content="2")
        _ => inspect("no attempt", content="2")
      }
      match fields.get("args") {
        Some(Object(args)) => inspect(args.contains("x"), content="true")
        _ => inspect("no args", content="false")
      }
      match fields.get("deps") {
        Some(Object(deps)) => inspect(deps.contains("b"), content="true")
        _ => inspect("no deps", content="false")
      }
    }
    _ => inspect("no value", content="value")
  }
}

///|
test "a task that raises is a reply, not a dead worker" {
  let line =
    #|{"id":1,"key":"a","attempt":1,"name":"boom","args":null,"deps":{}}

  let reply = @moondask.Reply::from_json(
    @moondask.decode(@worker.handle(echoing(), line)),
  )
  inspect(reply.id, content="1")
  match reply.outcome {
    Err(reason) => inspect(reason.contains("stopped"), content="true")
    Ok(_) => inspect("a value", content="an error")
  }
}

///|
test "an unknown name is refused with a reason" {
  let line =
    #|{"id":3,"key":"a","attempt":1,"name":"nobody","args":null,"deps":{}}

  let reply = @moondask.Reply::from_json(
    @moondask.decode(@worker.handle(echoing(), line)),
  )
  match reply.outcome {
    Err(reason) => inspect(reason.contains("nobody"), content="true")
    Ok(_) => inspect("a value", content="an error")
  }
}

///|
test "a line that is not a request is refused rather than ignored" {
  let reply = @moondask.Reply::from_json(
    @moondask.decode(@worker.handle(echoing(), "not json at all")),
  )
  inspect(reply.id, content="0")
  inspect(reply.outcome is Err(_), content="true")
}

///|
test "a task that asks to end its worker ends it" {
  let line =
    #|{"id":4,"key":"a","attempt":1,"name":"end","args":null,"deps":{}}
  match @worker.answer(echoing(), line) {
    Ended => inspect(true, content="true")
    Written(_) => inspect(false, content="true")
  }
}
