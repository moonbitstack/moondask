///|
/// Runs the tasks a worker is asked for, one line at a time.
///
/// This is the other end of the executor's protocol: a request names a task, the
/// registry turns the name into a function, and the reply carries the value or
/// the reason it raised. A worker holds no state between requests, so a graph
/// split across several workers gives the same answer as one worker, and a
/// worker that dies loses nothing but the request in flight.
///
/// ```text
/// {"id":1,"key":"a","attempt":1,"name":"sum_range","args":{...},"deps":{}}
/// {"id":1,"ok":true,"value":3.14159}
/// ```
/// A line that cannot be read is answered with an error rather than ignored, so
/// the executor sees a refusal instead of waiting for a reply that will not come.
pub fn handle(registry : @moondask.Registry, line : StringView) -> String {
  match answer(registry, line) {
    Written(reply) => reply
    Ended => "{\"id\":0,\"ok\":false,\"error\":\"the worker is ending\"}"
  }
}

///|
/// What one request comes to: a line to write back, or the end of this worker
/// because the task asked for it.
pub(all) enum Answer {
  ///
  /// A reply line.
  Written(String)
  ///
  /// The task ended its worker, so the process is to stop here.
  Ended
}

///|
/// Answer one request. A task that raises is a reply with `ok` false, except one
/// that asks for its process to end, which ends it.
pub fn answer(registry : @moondask.Registry, line : StringView) -> Answer {
  let parsed = Ok(@moondask.Request::from_json(@moondask.decode(line))) catch {
    error => Err(@moondask.describe(error))
  }
  match parsed {
    Err(reason) =>
      Written(
        @moondask.encode(
          @moondask.Reply::{ id: 0, outcome: Err(reason), }.to_json(),
        ),
      )
    Ok(request) =>
      match attempt(registry, request) {
        Done(value) =>
          Written(
            @moondask.encode(
              @moondask.Reply::{ id: request.id, outcome: value, }.to_json(),
            ),
          )
        Over => Ended
      }
  }
}

///|
/// The value a request came to, or the news that it ended the worker.
priv enum Attempt {
  Done(Result[Json, String])
  Over
}

///|
fn attempt(
  registry : @moondask.Registry,
  request : @moondask.Request,
) -> Attempt {
  let value = Ok(registry.run(request.name, request.inputs())) catch {
    @moondask.Aborted(_) => return Over
    error => Err(@moondask.describe(error))
  }
  Done(value)
}

///|
/// Serve requests until the reader is at its end, which is what happens when the
/// executor closes the pipe or exits. A task that asks for its process to end
/// leaves with code 70 instead of answering.
pub async fn serve(
  registry : @moondask.Registry,
  reader : &@io.Reader,
  writer : &@io.Writer,
) -> Unit {
  for ;; {
    match reader.read_until("\n") {
      Some(line) =>
        match answer(registry, line) {
          Written(reply) => writer.write(reply + "\n")
          Ended => @env.exit(70)
        }
      None => break
    }
  }
}
