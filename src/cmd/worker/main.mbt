///|
/// Serve the kernel registry on standard input and output until the executor
/// closes the pipe.
fn main {
  @async.run_async_main(async fn() { @serve.serve_stdio(@kernels.registry()) })
}
