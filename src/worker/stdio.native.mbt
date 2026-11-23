///|
/// Serve requests from standard input on standard output, which is how an
/// executor starts a worker.
pub async fn serve_stdio(registry : @moondask.Registry) -> Unit {
  serve(registry, @stdio.stdin, @stdio.stdout)
}
