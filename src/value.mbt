///|
/// A JSON array as a vector of doubles. Anything that is not an array of numbers
/// is refused, so a mixed-up call shows up as an error rather than a silent zero.
pub fn doubles(value : Json) -> FixedArray[Double] raise Fault {
  match value {
    Array(items) => {
      let out = FixedArray::make(items.length(), 0.0)
      for index, item in items {
        match item {
          Number(number, ..) => out[index] = number
          _ => raise Fault::MissingResult(key="array of numbers")
        }
      }
      out
    }
    _ => raise Fault::MissingResult(key="array of numbers")
  }
}

///|
/// A vector of doubles as a JSON array.
pub fn numbers(values : FixedArray[Double]) -> Json {
  let out = []
  for value in values {
    out.push(Json::number(value))
  }
  Json::array(out)
}
