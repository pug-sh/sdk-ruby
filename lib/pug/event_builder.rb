# frozen_string_literal: true

require "date"
require "json"
require "securerandom"
require "time"
require_relative "batcher"
require_relative "countries"
require_relative "log"
require_relative "proto"
require_relative "validator"
require_relative "version"
require_relative "well_known"

module Pug
  # Builds and validates the Event for a track call. build returns [event, encoded bytesize],
  # or nil, having logged why, when the event must be dropped.
  class EventBuilder
    LIB = "pug-ruby"
    PLATFORM = "server"

    # PropertyValue.string_value is capped at 1024 code points. A UTF-8 byte count is always at
    # least the code-point count, so a 1024-byte cap is stricter, never looser.
    MAX_STRING_BYTES = 1024

    # An event too big for a batch of its own would be retried forever.
    MAX_EVENT_BYTES = Batcher::MAX_BATCH_BYTES

    NANOS = 1_000_000_000
    # Past 2^53 a Float may already have been rounded, so it can't stand for an exact integer.
    MAX_SAFE_FLOAT = 2**53

    SNAKE_CASE = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)+\z/

    INTEGER_RANGES = {
      int32: (-(2**31))..((2**31) - 1),
      sint32: (-(2**31))..((2**31) - 1),
      sfixed32: (-(2**31))..((2**31) - 1),
      int64: (-(2**63))..((2**63) - 1),
      sint64: (-(2**63))..((2**63) - 1),
      sfixed64: (-(2**63))..((2**63) - 1),
      uint32: 0..((2**32) - 1),
      fixed32: 0..((2**32) - 1),
      uint64: 0..((2**64) - 1),
      fixed64: 0..((2**64) - 1)
    }.freeze

    # Proto Timestamp tops out at year 9999. A time past it, or before the epoch, is almost
    # certainly a unit mistake.
    MIN_OCCUR_TIME = Time.at(0).utc
    MAX_OCCUR_TIME = Time.utc(9999, 12, 31, 23, 59, 59)

    LOCATION_STRINGS = {
      "continent" => "$continent",
      "country" => "$country",
      "region" => "$region",
      "city" => "$city",
      "postal_code" => "$postalCode",
      "metro_code" => "$metroCode",
      "timezone" => "$timezone"
    }.freeze
    LOCATION_COORDINATES = { "latitude" => 90, "longitude" => 180 }.freeze
    LOCATION_ALIASES = { "postalCode" => "postal_code", "metroCode" => "metro_code" }.freeze
    LOCATION_FIELD_NAMES = (LOCATION_STRINGS.keys + LOCATION_COORDINATES.keys).join(", ")

    Event = Proto::Sdk::Events::V1::Event
    Duration = ::Google::Protobuf::Duration
    Timestamp = ::Google::Protobuf::Timestamp

    SchemaField = Struct.new(:descriptor, :name, :json_name, :type)
    Schema = Struct.new(:klass, :name, :by_json_name, :fields)

    # Field lookups for every well-known schema, by JSON name, worked out once.
    SCHEMAS = WellKnown::CATALOG.transform_values do |klass|
      fields = klass.descriptor.map do |field|
        SchemaField.new(field, field.name, field.json_name, field.type).freeze
      end
      by_json_name = fields.to_h { |field| [field.json_name, field] }
      Schema.new(klass, klass.descriptor.name, by_json_name.freeze, fields.freeze).freeze
    end.freeze

    class FieldError < StandardError
      attr_reader :field

      def initialize(field, message)
        @field = field
        super(message)
      end

      def to_s
        "#{field}: #{super}"
      end
    end

    class NotRepresentable < StandardError; end

    Unsupported = Object.new.freeze

    # options.proto's wire form for a Duration: "1.5s", never "1.500s". Summing first fixes nanos
    # that are out of range or signed against the seconds.
    def self.format_duration(seconds, nanos)
      total = (seconds * NANOS) + nanos
      whole, fraction = total.abs.divmod(NANOS)
      fraction = format("%09d", fraction).sub(/0+\z/, "")
      "#{"-" if total.negative?}#{whole}#{".#{fraction}" unless fraction.empty?}s"
    end

    # JSON.generate writes an object it doesn't know, such as a Set, as its to_s. Here times become
    # ISO 8601 and other real numbers floats, as they would on their own, and anything else is
    # refused, as is an integer past max_integer. Like JSON, it stops at 100 levels, for cycles.
    def self.json_ready(value, max_integer: nil, depth: 0)
      raise NotRepresentable, "nested more than 100 levels deep" if depth > 100

      case value
      when Hash then value.to_h { |key, item| [key.to_s, json_ready(item, max_integer:, depth: depth + 1)] }
      when Array then value.map { |item| json_ready(item, max_integer:, depth: depth + 1) }
      when String, Float, true, false, nil then value
      when Integer
        raise NotRepresentable, "#{value} is out of range (±#{max_integer})" if max_integer && value.abs > max_integer

        value
      when Symbol then value.to_s
      when Time, DateTime then value.iso8601(3)
      when Date then value.iso8601
      else
        raise NotRepresentable, "#{value.class} has no JSON form" unless value.is_a?(Numeric) && value.real?

        Float(value)
      end
    end

    # Protobuf's JSON-name rule, so order_total lands on a well-known field's JSON name. Only
    # lowercase snake_case is renamed, since the full rule would turn ORDER_ID into ORDERID; the
    # ascii_only? check keeps match? from raising on a UTF-16 or broken key.
    def self.camel_case(key)
      key.ascii_only? && key.match?(SNAKE_CASE) ? key.gsub(/_[a-z0-9]/) { |pair| pair[1].upcase } : key
    end

    def initialize(log)
      @log = log
    end

    def build(kind, session_id, distinct_id, properties = nil, timestamp: nil, location: nil)
      kind = utf8(kind.to_s)
      schema = SCHEMAS[kind]
      custom = if schema
                 well_known_properties(schema, kind, properties || {})
               else
                 custom_properties(properties || {}, kind)
               end
      return if custom.nil?

      auto = {
        "$lib" => string_value(LIB),
        "$sdkVersion" => string_value(VERSION),
        "$platform" => string_value(PLATFORM),
        **location_properties(location, kind)
      }
      event = new_event(kind, session_id, distinct_id, auto, custom, timestamp)
      return if event.nil?

      violations = Validator.validate(event)
      unless violations.empty?
        @log.error("Event \"#{kind}\" (#{schema ? "well-known" : "custom"}) failed Event-level validation: " \
                   "#{Validator.format(violations)}")
        return
      end
      bytesize = Event.encode(event).bytesize
      if bytesize > MAX_EVENT_BYTES
        @log.error("Event \"#{kind}\" dropped: #{bytesize} bytes is too large to send (limit #{MAX_EVENT_BYTES})")
        return
      end
      [event, bytesize]
    end

    private

    def utf8(string)
      unless [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(string.encoding)
        string = string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      end
      string = string.dup.force_encoding(Encoding::UTF_8) unless string.encoding == Encoding::UTF_8
      string.valid_encoding? ? string : string.scrub("\uFFFD")
    end

    def time?(value)
      value.is_a?(Time) || value.is_a?(DateTime)
    end

    def real_number?(value)
      value.is_a?(Numeric) && value.real?
    end

    def type_name(value)
      value.nil? ? "nil" : value.class.name
    end

    def new_event(kind, session_id, distinct_id, auto, custom, timestamp)
      Event.new(
        event_id: SecureRandom.uuid_v7,
        auto_properties: auto,
        custom_properties: custom,
        kind: kind,
        session_id: session_id,
        distinct_id: distinct_id,
        occur_time: occur_time(timestamp)
      )
    rescue StandardError => e
      @log.error("Event \"#{kind}\" dropped: failed to create Event proto: #{Log.describe(e)}")
      nil
    end

    def occur_time(timestamp)
      return Timestamp.from_time(Time.now) if timestamp.nil?

      time = timestamp.to_time if time?(timestamp)
      return Timestamp.from_time(time) if time&.between?(MIN_OCCUR_TIME, MAX_OCCUR_TIME)

      @log.warn("Ignoring invalid track timestamp #{timestamp.inspect}; expected a Time between 1970 and 9999. " \
                "Using current time.")
      Timestamp.from_time(Time.now)
    end

    # Typed fields render by their proto type rather than their Ruby value, so a whole-number
    # double stays a double. A key names a field once camel-cased, so the proto name works as well
    # as the JSON name; unknown keys ride along as custom properties.
    def well_known_properties(schema, kind, properties)
      message, extras = typed_message(schema, properties)
      violations = Validator.validate(message)
      unless violations.empty?
        @log.error("Event \"#{kind}\" dropped: properties validation failed for \"#{schema.name}\": " \
                   "#{Validator.format(violations)}")
        return
      end
      known_properties(schema, message).merge(custom_properties(extras, kind))
    rescue FieldError => e
      @log.error("Event \"#{kind}\" dropped: invalid properties for \"#{schema.name}\": #{e}")
      nil
    end

    def typed_message(schema, properties)
      given = {}
      extras = {}
      properties.each do |key, value|
        name = utf8(key.to_s)
        field = schema.by_json_name[self.class.camel_case(name)]
        if field.nil?
          extras[key] = value
        elsif given.key?(field)
          raise FieldError.new(field.name, "given twice, as #{given[field].first} and #{name}")
        else
          given[field] = [name, value]
        end
      end
      init = given.each_with_object({}) do |(field, (_, value)), out|
        next if value.nil?

        coerced = coerce(field.descriptor, value)
        out[field.name] = coerced unless coerced.equal?(Unsupported)
      end
      [build_message(schema.klass, init), extras]
    end

    def build_message(klass, init)
      klass.new(init)
    rescue ArgumentError, TypeError, RangeError, ::Google::Protobuf::TypeError => e
      raise FieldError.new(init.keys.join(", "), e.message)
    end

    # Ruby's protobuf type-checks assignments too, but coercing first keeps the messages uniform
    # and decides the Ruby-specific cases: a Symbol is a string, an integral Float is an integer.
    def coerce(field, value)
      return unsupported(field) if field.label == :repeated

      case field.type
      when :string
        return utf8(value.to_s) if value.is_a?(String) || value.is_a?(Symbol)

        raise FieldError.new(field.name, "expected string, got #{type_name(value)}")
      when :bool
        return value if [true, false].include?(value)

        raise FieldError.new(field.name, "expected bool, got #{type_name(value)}")
      when :double, :float
        return Float(value) if real_number?(value)

        raise FieldError.new(field.name, "expected #{field.type}, got #{type_name(value)}")
      when *INTEGER_RANGES.keys
        integer(field.name, field.type, value)
      when :message
        return duration(field.name, value) if field.subtype.name == "google.protobuf.Duration"

        unsupported(field)
      else
        unsupported(field)
      end
    end

    def unsupported(field)
      @log.warn("Field \"#{field.name}\" has unsupported type #{field.subtype&.name || field.type}, skipping")
      Unsupported
    end

    def integer(name, type, value)
      number = case value
               when Integer then value
               when Float then integral_float(name, type, value)
               else
                 unless real_number?(value) && value.finite? && value == value.truncate
                   raise FieldError.new(name, "expected #{type}, got #{type_name(value)}")
                 end

                 value.to_i
               end
      return number if INTEGER_RANGES.fetch(type).cover?(number)

      raise FieldError.new(name, "expected #{type}, got #{number}")
    end

    def integral_float(name, type, value)
      raise FieldError.new(name, "expected #{type}, got #{value}") unless value.finite? && value == value.truncate
      raise FieldError.new(name, "expected a safe integer, got #{value}") if value.abs >= MAX_SAFE_FLOAT

      value.to_i
    end

    # A Numeric is seconds, Ruby's unit for time spans (and what google-protobuf itself accepts
    # for a Duration field).
    def duration(name, value)
      case value
      when Duration then value
      when Hash then duration_from_hash(name, value)
      else
        unless real_number?(value)
          raise FieldError.new(name, "expected a Duration (seconds, { seconds:, nanos: } or " \
                                     "Google::Protobuf::Duration), got #{type_name(value)}")
        end
        raise FieldError.new(name, "expected a finite number of seconds, got #{value}") unless value.finite?

        total = (Rational(value) * NANOS).round
        seconds, nanos = total.abs.divmod(NANOS)
        sign = total.negative? ? -1 : 1
        Duration.new(seconds: sign * seconds, nanos: sign * nanos)
      end
    end

    def duration_from_hash(name, value)
      parts = value.transform_keys(&:to_s)
      unless (parts.keys - %w[seconds nanos]).empty?
        raise FieldError.new(name, "expected a Duration ({ seconds:, nanos: }), got keys #{parts.keys.join(", ")}")
      end

      Duration.new(
        seconds: parts["seconds"].nil? ? 0 : integer("#{name}: seconds", :int64, parts["seconds"]),
        nanos: parts["nanos"].nil? ? 0 : integer("#{name}: nanos", :int32, parts["nanos"])
      )
    end

    def known_properties(schema, message)
      schema.fields.each_with_object({}) do |field, out|
        next if field.descriptor.label == :repeated || !Validator.set?(message, field.descriptor)

        property = known_value(field, field.descriptor.get(message))
        if property
          out[field.json_name] = property
        else
          @log.warn("Field \"#{schema.name}.#{field.name}\" has unsupported type #{field.type}, skipping")
        end
      end
    end

    def known_value(field, value)
      case field.type
      when :string then string_value(value)
      when :bool then { bool_value: value }
      when :double, :float then { double_value: value }
      when *INTEGER_RANGES.keys
        { int_value: value } if INTEGER_RANGES[:int64].cover?(value)
      when :message
        string_value(self.class.format_duration(value.seconds, value.nanos)) if value.is_a?(Duration)
      end
    end

    def custom_properties(properties, kind)
      given = {}
      properties.each_with_object({}) do |(key, value), out|
        name = self.class.camel_case(utf8(key.to_s))
        mapped = custom_value(value)
        next unless mapped

        if given.key?(name)
          @log.warn("Properties #{given[name].inspect} and #{key.inspect} on event \"#{kind}\" both go out as " \
                    "#{name.inspect}; sending the last")
        end
        given[name] = key
        out[name] = mapped
      rescue NotRepresentable => e
        @log.warn("Property \"#{key}\" on event \"#{kind}\" not representable (#{e.message}), skipping")
      end
    end

    # A nil result means the value is absent and the property is omitted.
    def custom_value(value)
      case value
      when nil then nil
      when String, Symbol then string_value(value.to_s)
      when true, false then { bool_value: value }
      when Integer
        raise NotRepresentable, "#{value} overflows int64" unless INTEGER_RANGES[:int64].cover?(value)

        { int_value: value }
      when Float then double_value(value)
      when Timestamp then { timestamp_value: value }
      when Duration then string_value(self.class.format_duration(value.seconds, value.nanos))
      when Hash, Array then json_value(value)
      else other_value(value)
      end
    end

    def other_value(value)
      if time?(value)
        time = value.to_time
        raise NotRepresentable, "#{value} is out of the timestamp range" unless time.getutc.year.between?(1, 9999)

        { timestamp_value: Timestamp.from_time(time) }
      elsif value.is_a?(Date)
        string_value(value.iso8601)
      elsif real_number?(value)
        double_value(Float(value))
      else
        raise NotRepresentable, "unsupported type #{type_name(value)}"
      end
    end

    def double_value(value)
      raise NotRepresentable, "non-finite number #{value}" unless value.finite?

      { double_value: value }
    end

    def json_value(value)
      string_value(JSON.generate(self.class.json_ready(value)))
    rescue StandardError => e
      raise NotRepresentable, "not JSON-serializable: #{e.message}"
    end

    def string_value(raw)
      value = utf8(raw)
      if value.bytesize > MAX_STRING_BYTES
        @log.warn("Property string exceeds #{MAX_STRING_BYTES} bytes, truncating")
        value = value.byteslice(0, MAX_STRING_BYTES).scrub("")
      end
      { string_value: value }
    end

    # The server skips geo enrichment on private-key requests, which is all this SDK makes, so
    # these keys are the only geo the event will ever carry: a dropped field is a permanent hole,
    # not one filled in later.
    def location_properties(location, kind)
      return {} if location.nil?

      unless location.is_a?(Hash)
        @log.warn("Ignoring location on event \"#{kind}\": expected a Hash, got #{type_name(location)}")
        return {}
      end
      fields = location_fields(location, kind)
      props = location_strings(fields, kind).merge(location_coordinates(fields, kind))
      @log.warn("Ignoring location on event \"#{kind}\": no usable fields; the event will carry no geo") if props.empty?
      props
    end

    def location_fields(location, kind)
      location.each_with_object({}) do |(key, value), fields|
        name = LOCATION_ALIASES.fetch(key.to_s, key.to_s)
        if !LOCATION_STRINGS.key?(name) && !LOCATION_COORDINATES.key?(name)
          @log.warn("Ignoring unknown location field \"#{key}\" on event \"#{kind}\"; expected one of " \
                    "#{LOCATION_FIELD_NAMES}")
        elsif fields.key?(name)
          @log.warn("Ignoring location field \"#{key}\" on event \"#{kind}\": #{name} is already set")
        else
          fields[name] = value
        end
      end
    end

    def location_strings(fields, kind)
      LOCATION_STRINGS.each_with_object({}) do |(name, property), props|
        value = fields[name]
        next if value.nil?

        unless value.is_a?(String) || value.is_a?(Symbol)
          @log.warn("Ignoring location.#{name} on event \"#{kind}\": expected a String, got " \
                    "#{type_name(value)}")
          next
        end
        trimmed = utf8(value.to_s).gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
        next if trimmed.empty?

        if name == "country"
          trimmed = trimmed.upcase
          unless COUNTRY_CODES.include?(trimmed)
            @log.warn("Ignoring location.country #{value.to_s.inspect} on event \"#{kind}\"; expected an " \
                      "ISO 3166-1 alpha-2 code like \"DE\"")
            next
          end
        end
        props[property] = string_value(trimmed)
      end
    end

    # Always doubles: a whole-number coordinate in the int slot would split the column every
    # other writer of $latitude/$longitude files as Float64. A lone coordinate reads as a real
    # position with the other axis at 0, so they are sent together or not at all.
    def location_coordinates(fields, kind)
      coordinates = LOCATION_COORDINATES.each_with_object({}) do |(name, limit), found|
        value = fields[name]
        next if value.nil?

        unless real_number?(value)
          @log.warn("Ignoring location.#{name} on event \"#{kind}\": expected a number, got " \
                    "#{type_name(value)}")
          next
        end
        number = Float(value)
        unless number.finite? && number.abs <= limit
          @log.warn("Ignoring location.#{name} #{value} on event \"#{kind}\"; expected a number within ±#{limit}")
          next
        end
        found[name] = number
      end
      if coordinates.size == 1
        @log.warn("Ignoring location coordinates on event \"#{kind}\": latitude and longitude must be set together")
      end
      return {} unless coordinates.size == 2

      { "$latitude" => { double_value: coordinates["latitude"] },
        "$longitude" => { double_value: coordinates["longitude"] } }
    end
  end
end
