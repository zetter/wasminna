require 'float'

def main
  assert_float_encoding 0x4049_0fdb, 3141592653589793, 10 ** 15, bits: 32
  assert_float_encoding 0x5eff_ffff, 0x7fffff4000000001, 1, bits: 32
  assert_float_encoding 0x0000_0000, 0, 1, bits: 32
  assert_float_encoding 0x4f00_0000, 0x7fffffff, 1, bits: 32

  assert_float_encoding 0x3ff0_0000_0000_0000, 1, 1, bits: 64

  assert_float_decoding 0, 1, false, 0x0000_0000, bits: 32
end

def assert_float_encoding(expected, numerator, denominator, negated: false, bits:)
  actual = Wasminna::Float.encode(numerator, denominator, negated:, bits:)
  raise "expected #{expected}, got #{actual}" unless actual == expected
end

def assert_float_decoding(expected_numerator, expected_denominator, expected_negated, encoded, bits:)
  actual = Wasminna::Float.decode(encoded, bits:)
  raise actual.inspect unless actual == [expected_numerator, expected_denominator, expected_negated]
end

main
