require 'float'
require 'helpers'
require 's_expression_parser'
require 'sign'

def main
  unless ARGV.empty?
    s_expression = SExpressionParser.new.parse(ARGF.read)
    Interpreter.new.interpret(s_expression)
    puts
  end
end

class Interpreter
  include Helpers::Mask

  Parameter = Struct.new(:name, keyword_init: true)
  Local = Struct.new(:name, keyword_init: true)
  Function = Struct.new(:name, :parameters, :locals, :body, keyword_init: true)

  class Memory < Struct.new(:bytes, keyword_init: true)
    include Helpers::Mask
    include Helpers::SizeOf
    extend Helpers::SizeOf

    BITS_PER_BYTE = 8
    BYTES_PER_PAGE = 0xffff

    def self.from_string(string:)
      size_in_pages = size_of(string.bytesize, in: BYTES_PER_PAGE)
      bytes = "\0" * (size_in_pages * BYTES_PER_PAGE)
      bytes[0, string.length] = string
      new(bytes:)
    end

    def self.from_limits(minimum_size:, maximum_size:)
      bytes = "\0" * (minimum_size * BYTES_PER_PAGE)
      new(bytes:)
    end

    def load(offset:, bits:)
      size_of(bits, in: BITS_PER_BYTE).times
        .map { |index| bytes.getbyte(offset + index) }
        .map.with_index { |byte, index| byte << index * BITS_PER_BYTE }
        .inject(0, &:|)
    end

    def store(value:, offset:, bits:)
      size_of(bits, in: BITS_PER_BYTE).times do |index|
        byte = mask(value >> index * BITS_PER_BYTE, bits: BITS_PER_BYTE)
        bytes.setbyte(offset + index, byte)
      end
    end
  end

  def interpret(script)
    functions = nil
    @memory = nil

    script.each do |command|
      begin
        case command
        in ['module', 'binary', *]
          # TODO
        in ['module', *expressions]
          functions = []

          expressions.each do |expression|
            case expression
            in ['func', *expressions]
              functions << define_function(expressions:)
            in ['memory', ['data', *strings]]
              @memory = Memory.from_string(string: strings.map { parse_string(_1) }.join)
            in ['memory', minimum_size, maximum_size]
              minimum_size, maximum_size =
                [minimum_size, maximum_size].map { interpret_integer(_1, bits: 32) }
              @memory = Memory.from_limits(minimum_size:, maximum_size:)
            end
          end
        in ['invoke', name, *arguments]
          function = functions.detect { |function| function.name == name }
          if function.nil?
            puts
            puts "\e[33mWARNING: couldn’t find function #{name} (could be binary?), skipping\e[0m"
            next
          end

          invoke_function(function:, arguments:)
        in ['assert_return', ['invoke', name, *arguments], *expected]
          function = functions.detect { |function| function.name == name }
          if function.nil?
            puts
            puts "\e[33mWARNING: couldn’t find function #{name} (could be binary?), skipping\e[0m"
            next
          end

          actual_value = invoke_function(function:, arguments:)

          case expected.first
          in nil
            success = true
          in ['f32.const' | 'f64.const' => instruction, 'nan:canonical' | 'nan:arithmetic' => nan]
            expected_value = nan
            bits = instruction.slice(%r{\d+}).to_i(10)
            format = Wasminna::Float::Format.for(bits:)
            float = Wasminna::Float.decode(actual_value, format:).to_f
            success = float.nan? # TODO check whether canonical or arithmetic
          else
            expected_value = evaluate(expected.first, locals: [])
            success = actual_value == expected_value
          end

          if success
            print "\e[32m.\e[0m"
          else
            puts
            puts "\e[31mFAILED\e[0m: \e[33m#{pretty_print(command)}\e[0m"
            puts "expected #{expected_value.inspect}, got #{actual_value.inspect}"
            exit 1
          end
        in ['assert_malformed' | 'assert_trap' | 'assert_invalid', *]
          # TODO
          print "\e[33m.\e[0m"
        end
      rescue
        puts
        puts "\e[31mERROR\e[0m: \e[33m#{pretty_print(command)}\e[0m"
        raise
      end
    end
  end

  private

  using Sign::Conversion

  def define_function(expressions:)
    Function.new(parameters: [], locals: [], body: []).tap do |function|
      expressions.each do |expression|
        case expression
        in ['export', name]
          function.name = name
        in ['param', name, _]
          function.parameters << Parameter.new(name:)
        in ['param', _]
          function.parameters << Parameter.new
        in ['result', _]
        in ['local', %r{\A\$} => name, _]
          function.locals << Local.new(name:)
        in ['local', *types]
          types.each do
            function.locals << Local.new
          end
        else
          function.body << expression
        end
      end
    end
  end

  def pretty_print(expression)
    case expression
    in [*expressions]
      "(#{expressions.map { pretty_print(_1) }.join(' ')})"
    else
      expression
    end
  end

  def parse_string(string)
    encoding = string.encoding
    string.
      delete_prefix('"').delete_suffix('"').
      force_encoding(Encoding::ASCII_8BIT).
      gsub!(%r{\\\h{2}}) do |digits|
        digits.delete_prefix('\\').to_i(16).chr(Encoding::ASCII_8BIT)
      end.
      force_encoding(encoding)
  end

  def invoke_function(function:, arguments:)
    parameter_names = function.parameters.map(&:name)
    argument_values =
      arguments.map { |argument| evaluate(argument, locals: []) }
    parameters = parameter_names.zip(argument_values)
    locals = function.locals.map(&:name).map { [_1, 0] }
    locals = parameters + locals

    result = nil
    function.body.each do |instruction|
      result = evaluate(instruction, locals:)
    end
    result
  end

  def evaluate(expression, locals:)
    case expression
    in ['return', return_expression]
      evaluate(return_expression, locals:)
    in ['local.get', name]
      if name.start_with?('$')
        name, value = locals.assoc(name)
        value
      else
        name, value = locals.slice(name.to_i(10))
        value
      end
    in ['local.set' | 'local.tee', name, value]
      value = evaluate(value, locals:)

      if name.start_with?('$')
        locals.assoc(name)[1] = value
      else
        index = name.to_i(10)
        locals.slice(index)[1] = value
      end
    in ['block', %r{\A\$} => label, body]
      evaluate(body, locals:)
    in ['block', *instructions]
      catch(0) do
        instructions.each do |instruction|
          evaluate(instruction, locals:)
        end
      end
      0
    in ['loop', label, *instructions]
      loop do
        result =
          catch(label.to_sym) do
            instructions.each do |instruction|
              evaluate(instruction, locals:)
            end
          end
        break unless result == :branch
      end
      0
    in ['br_if', label, condition]
      unless evaluate(condition, locals:).zero?
        if label.start_with?('$')
          throw(label.to_sym, :branch)
        else
          throw(label.to_i(10), :branch)
        end
      end
      0
    in ['select', value_1, value_2, condition]
      value_1, value_2, condition =
        [value_1, value_2, condition].map { evaluate(_1, locals:) }

      if condition.zero?
        value_2
      else
        value_1
      end
    in ['if', ['result', _], condition, ['then', consequent], ['else', alternative]]
      if evaluate(condition, locals:).zero?
        evaluate(alternative, locals:)
      else
        evaluate(consequent, locals:)
      end
    in ['i32.const' | 'i64.const' => instruction, value]
      bits = instruction.slice(%r{\d+}).to_i(10)
      interpret_integer(value, bits:)
    in ['f32.const' | 'f64.const' => instruction, value]
      bits = instruction.slice(%r{\d+}).to_i(10)
      format = Wasminna::Float::Format.for(bits:)
      Wasminna::Float.parse(value).encode(format:)
    in ['i32.load' | 'i64.load' | 'f32.load' | 'f64.load' => instruction, offset]
      bits = instruction.slice(%r{\d+}).to_i(10)
      offset = evaluate(offset, locals:)
      @memory.load(offset:, bits:)
    in ['i32.load' | 'i64.load' | 'f32.load' | 'f64.load' => instruction, %r{\Aoffset=\d+\z} => static_offset, offset]
      bits = instruction.slice(%r{\d+}).to_i(10)
      _, static_offset = static_offset.split('=')
      static_offset = static_offset.to_i(10)
      offset = evaluate(offset, locals:)
      @memory.load(offset: offset + static_offset, bits:)
    in ['i32.store' | 'i64.store' | 'f32.store' | 'f64.store' => instruction, offset, value]
      bits = instruction.slice(%r{\d+}).to_i(10)
      offset, value = [offset, value].map { evaluate(_1, locals:) }
      @memory.store(value:, offset:, bits:)
      0
    in ['i32.store' | 'i64.store' | 'f32.store' | 'f64.store' => instruction, %r{\Aoffset=\d+\z} => static_offset, offset, value]
      bits = instruction.slice(%r{\d+}).to_i(10)
      _, static_offset = static_offset.split('=')
      static_offset = static_offset.to_i(10)
      offset, value = [offset, value].map { evaluate(_1, locals:) }
      @memory.store(value:, offset: offset + static_offset, bits:)
      0
    in [%r{\Ai(32|64)\.} => instruction, *arguments]
      type, operation = instruction.split('.')
      bits = type.slice(%r{\d+}).to_i(10)
      arguments = arguments.map { |arg| evaluate(arg, locals:) }

      case [operation, *arguments]
      in ['add', left, right]
        left + right
      in ['sub', left, right]
        left - right
      in ['mul', left, right]
        left * right
      in ['div_s', left, right]
        with_signed(left, right, bits:) do |left, right|
          divide(left, right)
        end
      in ['div_u', left, right]
        divide(left, right)
      in ['rem_s', left, right]
        with_signed(left, right, bits:) do |left, right|
          modulo(left, right)
        end
      in ['rem_u', left, right]
        modulo(left, right)
      in ['and', left, right]
        left & right
      in ['or', left, right]
        left | right
      in ['xor', left, right]
        left ^ right
      in ['shl', left, right]
        right %= bits
        left << right
      in ['shr_s', left, right]
        right %= bits
        with_signed(left, bits:) do |left|
          left >> right
        end
      in ['shr_u', left, right]
        right %= bits
        left >> right
      in ['rotl', left, right]
        right %= bits
        (left << right) | (left >> (bits - right))
      in ['rotr', left, right]
        right %= bits
        (left << (bits - right)) | (left >> right)
      in ['clz', value]
        0.upto(bits).take_while { |count| value[bits - count, count].zero? }.last
      in ['ctz', value]
        0.upto(bits).take_while { |count| value[0, count].zero? }.last
      in ['popcnt', value]
        0.upto(bits - 1).count { |position| value[position].nonzero? }
      in ['extend8_s' | 'extend16_s' | 'extend32_s' | 'extend_i32_s', value]
        extend_bits = operation.slice(%r{\d+}).to_i(10)
        unsigned(signed(value, bits: extend_bits), bits:)
      in ['extend_i32_u', value]
        value
      in ['eqz', value]
        bool(value.zero?)
      in ['eq', left, right]
        bool(left == right)
      in ['ne', left, right]
        bool(left != right)
      in ['lt_s', left, right]
        with_signed(left, right, bits:) do |left, right|
          bool(left < right)
        end
      in ['lt_u', left, right]
        bool(left < right)
      in ['le_s', left, right]
        with_signed(left, right, bits:) do |left, right|
          bool(left <= right)
        end
      in ['le_u', left, right]
        bool(left <= right)
      in ['gt_s', left, right]
        with_signed(left, right, bits:) do |left, right|
          bool(left > right)
        end
      in ['gt_u', left, right]
        bool(left > right)
      in ['ge_s', left, right]
        with_signed(left, right, bits:) do |left, right|
          bool(left >= right)
        end
      in ['ge_u', left, right]
        bool(left >= right)
      in ['wrap_i64', value]
        value
      in ['reinterpret_f32' | 'reinterpret_f64', value]
        float_bits = operation.slice(%r{\d+}).to_i(10)
        raise unless bits == float_bits
        value
      in ['trunc_f32_s' | 'trunc_f64_s', value]
        float_bits = operation.slice(%r{\d+}).to_i(10)
        format = Wasminna::Float::Format.for(bits: float_bits)
        float = Wasminna::Float.decode(value, format:).to_f
        unsigned(float.truncate, bits:)
      in ['trunc_sat_f32_s' | 'trunc_sat_f64_s', value]
        float_bits = operation.slice(%r{\d+}).to_i(10)
        format = Wasminna::Float::Format.for(bits: float_bits)
        result = Wasminna::Float.decode(value, format:).to_f
        result =
          if result.nan?
            0
          elsif result.infinite?
            result
          else
            result.truncate
          end

        size = 1 << bits
        min, max = -(size / 2), (size / 2) - 1
        result = result.clamp(min, max)

        unsigned(result, bits:)
      in ['trunc_f32_u' | 'trunc_f64_u', value]
        float_bits = operation.slice(%r{\d+}).to_i(10)
        format = Wasminna::Float::Format.for(bits: float_bits)
        Wasminna::Float.decode(value, format:).to_f.truncate
      in ['trunc_sat_f32_u' | 'trunc_sat_f64_u', value]
        float_bits = operation.slice(%r{\d+}).to_i(10)
        format = Wasminna::Float::Format.for(bits: float_bits)
        result = Wasminna::Float.decode(value, format:).to_f
        result =
          if result.nan?
            0
          elsif result.infinite?
            result
          else
            result.truncate
          end

        size = 1 << bits
        min, max = 0, size - 1
        result = result.clamp(min, max)

        result
      end.then { |value| mask(value, bits:) }
    in [%r{\Af(32|64)\.} => instruction, *arguments]
      type, operation = instruction.split('.')
      bits = type.slice(%r{\d+}).to_i(10)
      format = Wasminna::Float::Format.for(bits:)
      arguments = arguments.map { |arg| evaluate(arg, locals:) }

      case [operation, *arguments]
      in ['add' | 'sub' | 'mul' | 'div' | 'min' | 'max' | 'sqrt' | 'floor' | 'ceil' | 'trunc' | 'nearest', *]
        with_float(*arguments, format:) do |*arguments|
          case [operation, *arguments]
          in ['add', left, right]
            left + right
          in ['sub', left, right]
            left - right
          in ['mul', left, right]
            left * right
          in ['div', left, right]
            left / right
          in ['min' | 'max', _, _]
            if arguments.any?(&:nan?)
              ::Float::NAN
            elsif arguments.all?(&:zero?)
              arguments.send(:"#{operation}_by", &:sign)
            else
              arguments.send(operation)
            end
          in ['sqrt', value]
            if value.zero?
              value
            elsif value.negative?
              ::Float::NAN
            else
              Math.sqrt(value)
            end
          in ['floor' | 'ceil' | 'trunc' | 'nearest', value]
            if value.zero? || value.infinite? || value.nan?
              value
            else
              case operation
              in 'floor'
                value.floor
              in 'ceil'
                value.ceil
              in 'trunc'
                value.truncate
              in 'nearest'
                value.round(half: :even)
              end.then do |result|
                if result.zero? && value.negative?
                  -0.0
                else
                  result
                end
              end
            end
          end
        end
      in ['copysign', left, right]
        left, right =
          [left, right].map { Wasminna::Float.decode(_1, format:) }
        left.sign = right.sign
        left.encode(format:)
      in ['abs', value]
        value = Wasminna::Float.decode(value, format:)
        value.sign = Sign::PLUS
        value.encode(format:)
      in ['neg', value]
        value = Wasminna::Float.decode(value, format:)
        value.sign = !value.sign
        value.encode(format:)
      in ['eq' | 'ne' | 'lt' | 'le' | 'gt' | 'ge', left, right]
        left, right =
          [left, right].map { Wasminna::Float.decode(_1, format:).to_f }
        operation =
          {
            'eq' => '==', 'ne' => '!=',
            'lt' => '<', 'le' => '<=',
            'gt' => '>', 'ge' => '>='
          }.fetch(operation).to_sym.to_proc
        bool(operation.call(left, right))
      in ['convert_i32_s' | 'convert_i64_s', value]
        integer_bits = operation.slice(%r{\d+}).to_i(10)
        integer = signed(value, bits: integer_bits)
        Wasminna::Float.from_integer(integer).encode(format:)
      in ['convert_i32_u' | 'convert_i64_u', value]
        Wasminna::Float.from_integer(value).encode(format:)
      in ['promote_f32', value]
        raise unless bits == 64
        input_format = Wasminna::Float::Format.for(bits: 32)
        float = Wasminna::Float.decode(value, format: input_format)

        case float
        in Wasminna::Float::Nan
          Wasminna::Float::Nan.new(payload: 0, sign: float.sign)
        else
          float
        end.encode(format:)
      in ['demote_f64', value]
        raise unless bits == 32
        input_format = Wasminna::Float::Format.for(bits: 64)
        float = Wasminna::Float.decode(value, format: input_format)

        case float
        in Wasminna::Float::Nan
          Wasminna::Float::Nan.new(payload: 0, sign: float.sign)
        else
          float
        end.encode(format:)
      in ['reinterpret_i32' | 'reinterpret_i64', value]
        integer_bits = operation.slice(%r{\d+}).to_i(10)
        raise unless bits == integer_bits
        value
      end
    end
  end

  def with_signed(*unsigned_args, bits:)
    signed_args = unsigned_args.map { |arg| signed(arg, bits:) }
    signed_result = yield *signed_args
    unsigned(signed_result, bits:)
  end

  def with_float(*integer_args, format:)
    float_args = integer_args.map { |arg| Wasminna::Float.decode(arg, format:).to_f }
    float_result = yield *float_args
    Wasminna::Float.from_float(float_result).encode(format:)
  end

  def divide(dividend, divisor)
    quotient = dividend / divisor

    if quotient.negative? && (dividend % divisor).nonzero?
      quotient + 1
    else
      quotient
    end
  end

  def modulo(dividend, divisor)
    dividend - (divisor * divide(dividend, divisor))
  end

  def bool(value)
    value ? 1 : 0
  end

  def signed(unsigned, bits:)
    unsigned = mask(unsigned, bits:)
    size = 1 << bits

    if unsigned < size / 2
      unsigned
    else
      unsigned - size
    end
  end

  def unsigned(signed, bits:)
    signed = mask(signed, bits:)
    size = 1 << bits

    if signed.negative?
      signed + size
    else
      signed
    end
  end

  def interpret_integer(string, bits:)
    value =
      if string.delete_prefix('-').start_with?('0x')
        string.to_i(16)
      else
        string.to_i(10)
      end

    unsigned(value, bits:)
  end
end

main
