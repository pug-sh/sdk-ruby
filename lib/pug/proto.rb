# frozen_string_literal: true

require "google/protobuf"
require "google/protobuf/well_known_types"
require_relative "gen/buf/validate/validate_pb"
require_relative "gen/common/v1/property_value_pb"
require_relative "gen/sdk/events/v1/events_pb"
require_relative "gen/sdk/profiles/v1/profiles_pb"
require_relative "gen/shared/activity/v1/activity_pb"
require_relative "gen/shared/insights/v1/insights_pb"
require_relative "gen/shared/profiles/v1/profiles_pb"
Dir.glob("gen/common/events/v1/*_pb.rb", base: __dir__).sort.each { |path| require_relative path }

module Pug
  module Proto
    # Ruby's protobuf has no extension API, so custom options (the event catalog's kind and
    # platforms, buf.validate's rules) survive only as unknown fields of a descriptor's options.
    # Re-encoding the options message keeps them, and they are read back off the wire here.
    module Options
      module_function

      def number(extension)
        ::Google::Protobuf::DescriptorPool.generated_pool.lookup(extension).number
      end

      def string(options, number)
        value = values(options, number).reverse_each.find { |wire_type, _| wire_type == 2 }&.last
        value&.dup&.force_encoding(Encoding::UTF_8)
      end

      def enums(options, number)
        values(options, number).flat_map do |wire_type, value|
          wire_type == 2 ? packed_varints(value) : [value]
        end
      end

      # Occurrences of a message-typed field merge, as concatenated encodings do.
      def message(options, number, klass)
        parts = values(options, number).filter_map { |wire_type, value| value if wire_type == 2 }
        parts.empty? ? nil : klass.decode(parts.join)
      end

      def values(options, number)
        return [] if options.nil?

        found = []
        each_field(options.class.encode(options)) do |field, wire_type, value|
          found << [wire_type, value] if field == number
        end
        found
      end

      def each_field(bytes)
        pos = 0
        while pos < bytes.bytesize
          key, pos = varint(bytes, pos)
          case key & 7
          when 0 then value, pos = varint(bytes, pos)
          when 1 then value = bytes.byteslice(pos, 8).tap { pos += 8 }
          when 2
            length, pos = varint(bytes, pos)
            value = bytes.byteslice(pos, length).tap { pos += length }
          when 5 then value = bytes.byteslice(pos, 4).tap { pos += 4 }
          else raise ArgumentError, "unsupported wire type #{key & 7}"
          end
          yield key >> 3, key & 7, value
        end
      end

      def packed_varints(bytes)
        pos = 0
        out = []
        while pos < bytes.bytesize
          value, pos = varint(bytes, pos)
          out << value
        end
        out
      end

      def varint(bytes, pos)
        result = 0
        shift = 0
        loop do
          byte = bytes.getbyte(pos) or raise ArgumentError, "truncated varint"
          pos += 1
          result |= (byte & 0x7f) << shift
          return [result, pos] if byte < 0x80

          shift += 7
        end
      end
    end
  end
end
