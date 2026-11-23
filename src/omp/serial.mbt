///|
/// The kernels one element at a time, in MoonBit, with no threads.
///
/// These are the definition the parallel kernels are checked against, and they
/// are what to use on a target without threads. They are also fast enough to be
/// worth having on their own: the loop is the same, only the split is missing.
pub fn sum_serial(values : FixedArray[Double]) -> Double {
  let mut total = 0.0
  for index in 0..<values.length() {
    total = total + values[index]
  }
  total
}

///|
pub fn dot_serial(a : FixedArray[Double], b : FixedArray[Double]) -> Double {
  let mut total = 0.0
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  for index in 0..<len {
    total = total + a[index] * b[index]
  }
  total
}

///|
pub fn scale_serial(values : FixedArray[Double], alpha : Double) -> Unit {
  for index in 0..<values.length() {
    values[index] = values[index] * alpha
  }
}

///|
pub fn axpy_serial(
  alpha : Double,
  x : FixedArray[Double],
  y : FixedArray[Double],
) -> Unit {
  let len = if x.length() < y.length() { x.length() } else { y.length() }
  for index in 0..<len {
    y[index] = alpha * x[index] + y[index]
  }
}
