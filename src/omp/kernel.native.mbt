///|
/// The parallel kernels: each one spreads a flat range of doubles over the
/// threads the build provides.
///
/// Elementwise kernels write the same bytes whatever the split, so their results
/// are identical across the three builds. Reductions add the same numbers in a
/// different order, so they agree to rounding rather than to the bit; the
/// estimate of π counts integers, so it agrees exactly.
///
/// A build takes the OpenMP path when the stub is compiled with `-fopenmp` (gcc,
/// clang) or `/openmp` (the Microsoft compiler) **and** the program that links the
/// kernels is linked with the same flag: the kernels are an archive by then, so
/// the runtime they call is pulled in at the last step, which is the consumer's
/// link line. Without the flag the same loops run on the pool, and one thread
/// makes them run on the caller's.
#borrow(values)
extern "C" fn c_sum(values : FixedArray[Double]) -> Double = "moondask_sum"

///|
#borrow(a, b)
extern "C" fn c_dot(a : FixedArray[Double], b : FixedArray[Double]) -> Double = "moondask_dot"

///|
#borrow(values)
extern "C" fn c_scale(values : FixedArray[Double], alpha : Double) -> Unit = "moondask_scale"

///|
#borrow(x, y)
extern "C" fn c_axpy(
  alpha : Double,
  x : FixedArray[Double],
  y : FixedArray[Double],
) -> Unit = "moondask_axpy"

///|
extern "C" fn c_monte_carlo_pi(samples : Int64, seed : UInt64) -> Double = "moondask_monte_carlo_pi"

///|
extern "C" fn c_set_threads(threads : Int32) -> Unit = "moondask_set_threads"

///|
extern "C" fn c_set_schedule(schedule : Int32, chunk : Int32) -> Unit = "moondask_set_schedule"

///|
extern "C" fn c_set_affinity(affinity : Int32) -> Unit = "moondask_set_affinity"

///|
extern "C" fn c_threads() -> Int32 = "moondask_threads"

///|
extern "C" fn c_available_threads() -> Int32 = "moondask_available_threads"

///|
extern "C" fn c_backend() -> Int32 = "moondask_parallel_backend"

///|
/// Which build the kernels came from: OpenMP, our own pool, or one thread.
pub fn backend() -> Backend {
  match c_backend() {
    2 => Openmp
    1 => Threads
    _ => Serial
  }
}

///|
/// How many cores this machine reports, whatever the knobs say.
pub fn available_threads() -> Int32 {
  c_available_threads()
}

///|
/// How many threads the kernels will use right now.
pub fn threads() -> Int32 {
  c_threads()
}

///|
/// Hold the knobs for one call.
fn adjust(knobs : Knobs) -> Unit {
  c_set_threads(knobs.threads)
  match knobs.schedule {
    Static => c_set_schedule(0, 0)
    Dynamic(chunk~) => c_set_schedule(1, chunk)
    Guided => c_set_schedule(2, 0)
  }
  match knobs.affinity {
    None => c_set_affinity(0)
    Compact => c_set_affinity(1)
    Spread => c_set_affinity(2)
  }
}

///|
/// The sum of a vector.
pub fn sum(values : FixedArray[Double], knobs~ : Knobs = knobs) -> Double {
  adjust(knobs)
  c_sum(values)
}

///|
/// The dot product of two vectors, the shorter one deciding how far to go.
pub fn dot(
  a : FixedArray[Double],
  b : FixedArray[Double],
  knobs~ : Knobs = knobs,
) -> Double {
  adjust(knobs)
  c_dot(a, b)
}

///|
/// Multiply every element by `alpha`, in place.
pub fn scale(
  values : FixedArray[Double],
  alpha : Double,
  knobs~ : Knobs = knobs,
) -> Unit {
  adjust(knobs)
  c_scale(values, alpha)
}

///|
/// `y = alpha * x + y`, in place on `y`.
pub fn axpy(
  alpha : Double,
  x : FixedArray[Double],
  y : FixedArray[Double],
  knobs~ : Knobs = knobs,
) -> Unit {
  adjust(knobs)
  c_axpy(alpha, x, y)
}

///|
/// Estimate π by counting samples that land inside the quarter circle.
///
/// Draw `i` starts from `seed + i * φ`, so the count depends on which samples
/// were drawn and not on how they were split: the parallel estimate and the
/// sequential one are the same number, whichever thread count either used.
pub fn monte_carlo_pi(
  samples : Int64,
  seed : UInt64,
  knobs~ : Knobs = knobs,
) -> Double {
  adjust(knobs)
  c_monte_carlo_pi(samples, seed)
}
