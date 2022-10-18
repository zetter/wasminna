require 'float'

def main
  assert_float_encoding 0x4049_0fdb, 3141592653589793, 10 ** 15, bits: 32
end

def assert_float_encoding(expected, numerator, denominator, negated: false, bits:)
  actual = Wasminna::Float.encode(numerator, denominator, negated:, bits:)
  raise "expected #{expected}, got #{actual}" unless actual == expected
end

main
