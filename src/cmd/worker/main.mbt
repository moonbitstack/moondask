///|
/// Serve the kernel registry on standard input and output until the executor
/// closes the pipe.
async fn main {
  @serve.serve_stdio(@kernels.registry())
}
