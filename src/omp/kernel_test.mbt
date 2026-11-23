///|
/// A vector of `count` values built from a cheap, exactly representable pattern,
/// so a serial and a parallel sum of it can be compared without the pattern
/// itself contributing error.
fn vector(count : Int32) -> FixedArray[Double] {
  let out = FixedArray::make(count, 0.0)
  for index in 0..<count {
    out[index] = (index % 1000).to_double() / 8.0
  }
  out
}

///|
/// Whether two doubles are the same to within the rounding a different order of
/// addition can produce over a million terms.
fn close(a : Double, b : Double) -> Bool {
  let scale = if b < 0.0 { -b } else { b }
  let diff = if a > b { a - b } else { b - a }
  let unit = if scale > 1.0 { scale } else { 1.0 }
  diff <= 1.0e-9 * unit
}

///|
test "the build reports which path it took" {
  let backend = @omp.backend()
  inspect(
    match backend {
      @omp.Openmp => "openmp"
      @omp.Threads => "threads"
      @omp.Serial => "serial"
    },
    content=match backend {
      @omp.Openmp => "openmp"
      @omp.Threads => "threads"
      @omp.Serial => "serial"
    },
  )
  inspect(@omp.available_threads() >= 1, content="true")
}

///|
test "a sum matches the sequential one at every thread count" {
  let values = vector(1_000_000)
  let want = @omp.sum_serial(values)
  for threads in [1, 2, 3, @omp.available_threads()] {
    let got = @omp.sum(values, knobs=@omp.Knobs::new(threads~))
    inspect(close(got, want), content="true")
  }
}

///|
test "a dot product matches the sequential one at every thread count" {
  let a = vector(500_000)
  let b = vector(500_000)
  let want = @omp.dot_serial(a, b)
  for threads in [1, 2, @omp.available_threads()] {
    let got = @omp.dot(a, b, knobs=@omp.Knobs::new(threads~))
    inspect(close(got, want), content="true")
    inspect(got > 0.0, content="true")
  }
}

///|
test "scaling is bit for bit what one thread computes" {
  let values = vector(100_000)
  let want = values.copy()
  @omp.scale_serial(want, 2.5)
  for threads in [1, 2, @omp.available_threads()] {
    let got = values.copy()
    @omp.scale(got, 2.5, knobs=@omp.Knobs::new(threads~))
    inspect(got == want, content="true")
  }
}

///|
test "axpy is bit for bit what one thread computes" {
  let x = vector(100_000)
  let y = vector(100_000)
  let want = y.copy()
  @omp.axpy_serial(0.5, x, want)
  for threads in [1, 4, @omp.available_threads()] {
    let got = y.copy()
    @omp.axpy(0.5, x, got, knobs=@omp.Knobs::new(threads~))
    inspect(got == want, content="true")
  }
}

///|
test "the estimate of pi counts the same samples however they are split" {
  let samples = 2_000_000L
  let one_thread = @omp.monte_carlo_pi(
    samples,
    42UL,
    knobs=@omp.Knobs::new(threads=1),
  )
  let many = @omp.monte_carlo_pi(
    samples,
    42UL,
    knobs=@omp.Knobs::new(threads=@omp.available_threads()),
  )
  inspect(many == one_thread, content="true")
  // And the same count as the plain MoonBit estimator, which is the definition.
  inspect(one_thread == @kernels.monte_carlo_pi(samples, 42UL), content="true")
  let pi = 3.141592653589793
  let error = if one_thread > pi { one_thread - pi } else { pi - one_thread }
  inspect(error < 0.01, content="true")
}

///|
test "the schedule changes the split and not the answer" {
  let values = vector(400_000)
  let want = @omp.sum_serial(values)
  for
    schedule in [
      @omp.Static,
      @omp.Dynamic(chunk=64),
      @omp.Dynamic(chunk=0),
      @omp.Guided,
    ] {
    let knobs = @omp.Knobs::new(threads=4, schedule~)
    inspect(close(@omp.sum(values, knobs~), want), content="true")
  }
}

///|
test "asking for a core of its own does not change the answer" {
  let values = vector(200_000)
  let want = @omp.sum_serial(values)
  for affinity in [@omp.None, @omp.Compact, @omp.Spread] {
    let knobs = @omp.Knobs::new(threads=2, affinity~)
    inspect(close(@omp.sum(values, knobs~), want), content="true")
  }
}

///|
test "an empty or single-element vector is not a special case" {
  inspect(@omp.sum(FixedArray::make(0, 0.0)), content="0")
  inspect(@omp.sum(FixedArray::make(1, 2.5)), content="2.5")
  inspect(
    @omp.dot(FixedArray::make(0, 0.0), FixedArray::make(0, 0.0)),
    content="0",
  )
  inspect(@omp.monte_carlo_pi(0L, 1UL), content="0")
}
