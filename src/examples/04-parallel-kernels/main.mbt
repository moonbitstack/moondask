///|
/// What the threads are worth: the same kernels with one thread, with four, and
/// with every core, timed.
///
/// The example is its own check: the last line says whether every thread count
/// produced the sum and the estimate that one thread produces, so the timings
/// above it are only printed for a build that agrees with itself.
fn main {
  let count = 20_000_000
  let values = FixedArray::make(count, 0.0)
  for index in 0..<count {
    values[index] = (index % 1000).to_double() / 8.0
  }
  println("cores: \{@omp.available_threads()}")
  println("backend: \{backend_name()}")
  println("")
  println("sum over \{count} doubles")
  for threads in [1, 2, 4, @omp.available_threads()] {
    let knobs = @omp.Knobs::new(threads~)
    let started = @bench.monotonic_clock_start()
    let total = @omp.sum(values, knobs~)
    let micros = @bench.monotonic_clock_end(started).to_int64()
    println(
      "  \{padded(threads.to_int64())} threads: \{padded(micros / 1000L)} ms  \{total}",
    )
  }
  println("")
  println("pi over 40 million samples")
  for threads in [1, 4, @omp.available_threads()] {
    let knobs = @omp.Knobs::new(threads~)
    let started = @bench.monotonic_clock_start()
    let estimate = @omp.monte_carlo_pi(40_000_000L, 2026UL, knobs~)
    let micros = @bench.monotonic_clock_end(started).to_int64()
    println(
      "  \{padded(threads.to_int64())} threads: \{padded(micros / 1000L)} ms  \{estimate}",
    )
  }
  println("")
  println("checks: \{checks()}")
}

///|
/// Whether every thread count agrees with one thread, on a sum and on an estimate.
fn checks() -> String {
  let values = FixedArray::make(1_000_000, 0.0)
  for index in 0..<values.length() {
    values[index] = (index % 997).to_double() / 3.0
  }
  let want = @omp.sum_serial(values)
  let mut same = true
  for threads in [1, 2, 3, @omp.available_threads()] {
    let got = @omp.sum(values, knobs=@omp.Knobs::new(threads~))
    let slack = 1.0e-9 * want
    let diff = if got > want { got - want } else { want - got }
    if diff > slack {
      same = false
    }
  }
  let estimate = @omp.monte_carlo_pi(2_000_000L, 99UL)
  let single = @omp.monte_carlo_pi(
    2_000_000L,
    99UL,
    knobs=@omp.Knobs::new(threads=1),
  )
  if estimate != single {
    same = false
  }
  if same {
    "every thread count agrees with one"
  } else {
    "MISMATCH"
  }
}

///|
fn backend_name() -> String {
  match @omp.backend() {
    @omp.Openmp => "OpenMP"
    @omp.Threads => "thread pool"
    @omp.Serial => "one thread"
  }
}

///|
fn padded(value : Int64) -> String {
  let text = value.to_string()
  if text.length() >= 4 {
    return text
  }
  let pad = 4 - text.length()
  let mut out = ""
  for _ in 0..<pad {
    out = out + " "
  }
  out + text
}
