///|
/// One step of xorshift64*: the whole generator state is a single word, so a
/// worker that dies loses nothing but the numbers it had not drawn yet, and two
/// workers given different seeds never draw the same points.
fn step(state : UInt64) -> UInt64 {
  let mut x = state
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  x
}

///|
/// A number in `[0, 1)` from the top bits of a word: 53 bits, the most a double
/// holds exactly.
fn unit(word : UInt64) -> Double {
  (word >> 11).to_double() / 9007199254740992.0
}

///|
/// Estimate π by counting points that land inside the quarter circle.
///
/// Draw `i` starts from `seed + i * φ` rather than from the previous draw, so the
/// count depends on the range of indices and not on how that range was cut: any
/// partition of the samples adds up to the same estimate, which is what lets the
/// estimate be computed in parallel and still match the sequential one exactly.
///
/// The standard error is about `1.6 / sqrt(samples)`, so a million samples land
/// within about 0.002 of the true value.
pub fn monte_carlo_pi(samples : Int64, seed : UInt64) -> Double {
  if samples <= 0L {
    return 0.0
  }
  let base = if seed == 0UL { 0x9E3779B97F4A7C15UL } else { seed }
  let mut hits = 0L
  for index in 0L..<samples {
    let first = step(
      base + index.reinterpret_as_uint64() * 0x9E3779B97F4A7C15UL,
    )
    let second = step(first)
    let x = unit(first)
    let y = unit(second)
    if x * x + y * y <= 1.0 {
      hits = hits + 1L
    }
  }
  4.0 * hits.to_double() / samples.to_double()
}

///|
/// The sum of `sin(i)` for `i` in `[start, start + count)`.
///
/// The terms stand in for a chunk of a real array: the work grows with `count`,
/// and two chunks added together give the same total as one range, so the sum
/// can be cut up any way an executor likes.
pub fn sum_range(start : Int64, count : Int64) -> Double {
  let mut total = 0.0
  for index in start..<(start + count) {
    total = total + @math.sin(index.to_double())
  }
  total
}

///|
/// The dot product of two vectors, the shorter one deciding how far to go.
pub fn dot(a : FixedArray[Double], b : FixedArray[Double]) -> Double {
  let mut total = 0.0
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  for index in 0..<len {
    total = total + a[index] * b[index]
  }
  total
}
