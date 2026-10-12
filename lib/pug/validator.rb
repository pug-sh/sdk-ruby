# frozen_string_literal: true

require "time"
require_relative "proto"

module Pug
  # The subset of protovalidate the SDK's schemas use, driven by the buf.validate rules in the
  # descriptors' options, since Ruby has no protovalidate. A rule it can't evaluate is skipped
  # and reported by unsupported_rules, which the tests require to be empty for every schema the
  # SDK validates: a proto sync that adopts a new rule fails CI instead of going unenforced.
  #
  # Each message's rules are compiled once into plain closures, since reading them back off the
  # protobuf rule messages on every call costs more than the checks themselves.
  module Validator
    Violation = Struct.new(:path, :rule_id, :message) do
      def initialize(path, rule_id, message)
        super(path.to_s, rule_id, message)
      end

      def to_s
        path.empty? ? "#{message} [#{rule_id}]" : "#{path}: #{message} [#{rule_id}]"
      end
    end

    FieldPlan = Struct.new(:field, :name, :presence, :required, :ignore, :shape, :subtype, :nested, :convert,
                           :checks, :unsupported)
    MessagePlan = Struct.new(:name, :fields, :oneofs, :checks, :unsupported, :active, :checked_fields)

    # A map entry's path, rendered only if a violation needs it.
    MapEntryPath = Struct.new(:parent, :name, :key) do
      def empty? = false

      def to_s
        "#{Validator.join(parent, name)}[#{key.inspect}]"
      end
    end

    MESSAGE_RULES = Proto.extension("buf.validate.message")
    ONEOF_RULES = Proto.extension("buf.validate.oneof")
    FIELD_RULES = Proto.extension("buf.validate.field")

    NUMERIC = %i[float double int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64].freeze
    RANGE = %w[const lt lte gt gte in not_in example].freeze
    SUPPORTED = {
      string: %w[const len min_len max_len len_bytes min_bytes max_bytes pattern prefix suffix contains
                 not_contains in not_in uuid tuuid example],
      bool: %w[const example],
      duration: RANGE,
      **NUMERIC.to_h { |type| [type, %i[float double].include?(type) ? [*RANGE, "finite"] : RANGE] }
    }.freeze

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    TUUID = /\A\h{32}\z/
    NANOS = 1_000_000_000
    BOUNDS = { lt: "less than", lte: "less than or equal to", gt: "greater than",
               gte: "greater than or equal to" }.freeze

    # Ruby has no CEL interpreter, so each expression the schemas use is implemented by hand and
    # keyed by its exact text: an expression changed upstream stops matching and shows up in
    # unsupported_rules rather than being enforced with stale semantics.
    CEL = {
      "this.auto_properties.all(key, key.startsWith('$'))" =>
        ->(event) { event.auto_properties.keys.all? { |key| key.start_with?("$") } },
      "this.custom_properties.all(key, !key.startsWith('$'))" =>
        ->(event) { event.custom_properties.keys.none? { |key| key.start_with?("$") } },
      "this.cookieless || (this.distinct_id != '' && this.session_id != '')" =>
        ->(event) { event.cookieless || (event.distinct_id != "" && event.session_id != "") },
      "!this.startsWith('cookieless-')" =>
        ->(value) { !value.start_with?("cookieless-") }
    }.freeze

    @plans = {}.freeze
    @lock = Mutex.new

    module_function

    def validate(message)
      violations = []
      check_message(message, plan(message.class.descriptor), "", violations)
      violations
    end

    def format(violations)
      violations.join(", ")
    end

    def unsupported_rules(descriptor)
      seen = {}
      pending = [plan(descriptor)]
      found = []
      while (current = pending.pop)
        next if seen[current.name]

        seen[current.name] = true
        found.concat(current.unsupported)
        current.fields.each do |field_plan|
          found.concat(field_plan.unsupported)
          pending << plan(field_plan.subtype) if field_plan.subtype
        end
      end
      found
    end

    # Plans are built under the lock and published copy-on-write, so readers never lock.
    def plan(descriptor)
      @plans[descriptor.name] || @lock.synchronize { build_plans(descriptor) }
    end

    def check_message(message, message_plan, path, out)
      return unless message_plan.active

      message_plan.checked_fields.each { |field_plan| check_field(message, field_plan, path, out) }
      message_plan.oneofs.each do |name|
        next unless message.public_send(name).nil?

        out << Violation.new(join(path, name), "required", "exactly one field is required in oneof")
      end
      message_plan.checks.each do |check|
        failure = check.call(message)
        out << Violation.new(path, *failure) if failure
      end
    end

    def check_field(message, field_plan, path, out)
      field = field_plan.field
      present = case field_plan.presence
                when :explicit then field.has?(message)
                when :repeated then field.get(message).length.positive?
                else field.get(message) != field.default
                end
      if field_plan.required && !present
        out << Violation.new(join(path, field_plan.name), "required", "value is required")
        return
      end
      return unless present || (field_plan.presence == :implicit && field_plan.ignore != :IGNORE_IF_ZERO_VALUE)

      value = field.get(message)
      nested = field_plan.nested && plan(field_plan.nested)
      # A list or map is planned only for required, then, which its presence has satisfied.
      return if nested.nil? && field_plan.shape != :single

      case field_plan.shape
      when :map
        value.each { |key, item| check_message(item, nested, MapEntryPath.new(path, field_plan.name, key), out) }
      when :list
        value.each_with_index { |item, i| check_message(item, nested, "#{join(path, field_plan.name)}[#{i}]", out) }
      else
        run_checks(field_plan, value, path, out) unless field_plan.checks.empty?
        check_message(value, nested, join(path, field_plan.name), out) if nested
      end
    end

    def run_checks(field_plan, value, path, out)
      value = field_plan.convert.call(value) if field_plan.convert
      field_plan.checks.each do |check|
        failure = check.call(value)
        out << Violation.new(join(path, field_plan.name), *failure) if failure
      end
    end

    def set?(message, field)
      if field.label == :repeated
        field.get(message).length.positive?
      elsif field.has_presence?
        field.has?(message)
      else
        field.get(message) != field.default
      end
    end

    def join(path, name)
      path.empty? ? name : "#{path}.#{name}"
    end

    def build_plans(root)
      return @plans[root.name] if @plans.key?(root.name)

      built = {}
      pending = [root]
      while (descriptor = pending.pop)
        next if @plans.key?(descriptor.name) || built.key?(descriptor.name)

        built[descriptor.name] = build_plan(descriptor)
        built[descriptor.name].fields.each { |field_plan| pending << field_plan.subtype if field_plan.subtype }
      end
      mark_active(built)
      @plans = @plans.merge(built.transform_values(&:freeze)).freeze
      @plans[root.name]
    end

    def build_plan(descriptor)
      rules = MESSAGE_RULES.get(descriptor.options)
      cel = rules&.cel.to_a
      unsupported = cel.reject { |rule| CEL.key?(rule.expression) }.map { |rule| "#{descriptor.name}: cel #{rule.id}" }
      unsupported << "#{descriptor.name}: message oneof rule" if rules&.oneof&.any?
      unsupported << "#{descriptor.name}: cel_expression" if rules&.cel_expression&.any?
      oneofs = []
      descriptor.each_oneof do |oneof|
        oneofs << oneof.name if ONEOF_RULES.get(oneof.options)&.required
      end
      fields = descriptor.map { |field| build_field_plan(descriptor, field) }
      MessagePlan.new(descriptor.name, fields.freeze, oneofs.freeze, cel.filter_map { |rule| cel_check(rule) }.freeze,
                      unsupported.freeze, false, nil)
    end

    def build_field_plan(descriptor, field)
      rules = FIELD_RULES.get(field.options)
      shape = if field.label != :repeated then :single
              elsif field.type == :message && field.subtype.options.map_entry then :map
              else :list
              end
      subtype = if shape == :map
                  value = field.subtype.lookup("value")
                  value.subtype if value.type == :message
                elsif field.type == :message
                  field.subtype
                end
      unsupported = unsupported_field_rules(rules, shape).map { |rule| "#{descriptor.name}.#{field.name}: #{rule}" }
      checks = shape == :single && rules ? field_checks(rules) : []
      convert = method(:seconds) if rules&.type == :duration
      presence = if field.label == :repeated then :repeated
                 elsif field.has_presence? then :explicit
                 else :implicit
                 end
      FieldPlan.new(field, field.name, presence, rules&.required || false, rules&.ignore, shape, subtype, nil, convert,
                    checks.freeze, unsupported.freeze)
    end

    def unsupported_field_rules(rules, shape)
      return [] if rules.nil?

      found = rules.cel.reject { |rule| shape == :single && CEL.key?(rule.expression) }.map { |rule| "cel #{rule.id}" }
      found << "cel_expression" if rules.cel_expression.any?
      type = rules.type
      return found if type.nil?
      return found << type.to_s if !SUPPORTED.key?(type) || shape != :single

      typed = rules.public_send(type)
      typed.class.descriptor.each do |rule|
        found << "#{type}.#{rule.name}" if !SUPPORTED[type].include?(rule.name) && set?(typed, rule)
      end
      found
    end

    # A message is worth walking only if some rule is reachable from it; recursive schemas such
    # as google.protobuf.Struct, used for identify traits, have none and are skipped whole.
    def mark_active(built)
      lookup = ->(name) { built[name] || @plans[name] }
      reaches_rule = ->(field_plan) { field_plan.subtype && lookup.call(field_plan.subtype.name).active }
      built.each_value do |message_plan|
        message_plan.active = message_plan.checks.any? || message_plan.oneofs.any? ||
                              message_plan.fields.any? { |field_plan| field_plan.required || field_plan.checks.any? }
      end
      loop do
        reached = built.each_value.reject(&:active).select { |message_plan| message_plan.fields.any?(&reaches_rule) }
        break if reached.empty?

        reached.each { |message_plan| message_plan.active = true }
      end
      # Only fields with a rule, or leading to one, are walked; nested messages without any are
      # dropped from the plan.
      built.each_value do |message_plan|
        message_plan.checked_fields = message_plan.fields.filter_map do |field_plan|
          next if field_plan.ignore == :IGNORE_ALWAYS

          field_plan.nested = field_plan.subtype if reaches_rule.call(field_plan)
          field_plan if field_plan.nested || field_plan.required || field_plan.checks.any?
        end.freeze
      end
    end

    # Checks take the value and return nil, or the failed rule's [id, message].
    def field_checks(rules)
      checks = rules.cel.filter_map { |rule| cel_check(rule) }
      type = rules.type
      SUPPORTED.key?(type) ? checks + type_checks(type, rules.public_send(type)) : checks
    end

    def cel_check(rule)
      check = CEL[rule.expression]
      failure = [rule.id, rule.message].freeze
      check && ->(value) { failure unless check.call(value) }
    end

    def type_checks(type, rules)
      case type
      when :string then string_checks(rules)
      when :bool then const_checks(type, rules)
      else
        checks = const_checks(type, rules) + bounds_checks(type, rules) + list_checks(type, rules)
        if rules.respond_to?(:finite) && rules.finite
          failure = ["#{type}.finite", "value must be finite"].freeze
          checks << ->(value) { failure unless value.finite? }
        end
        checks
      end
    end

    def string_checks(rules)
      checks = const_checks(:string, rules)
      rule = lambda do |id, message, &failed|
        failure = ["string.#{id}", message].freeze
        checks << ->(value) { failure if failed.call(value) }
      end
      { len: "", min_len: "at least ", max_len: "at most " }.each do |name, bound|
        next unless rules.public_send(:"has_#{name}?")

        limit = rules.public_send(name)
        rule.call(name, "value length must be #{bound}#{limit} characters") do |value|
          length_violated?(name, value.length, limit)
        end
      end
      { len_bytes: "", min_bytes: "at least ", max_bytes: "at most " }.each do |name, bound|
        next unless rules.public_send(:"has_#{name}?")

        limit = rules.public_send(name)
        rule.call(name, "value length must be #{bound}#{limit} bytes") do |value|
          length_violated?(name, value.bytesize, limit)
        end
      end
      if rules.has_pattern?
        pattern = Regexp.new(re2_anchors(rules.pattern))
        rule.call(:pattern, "value does not match regex pattern `#{rules.pattern}`") { |value| !pattern.match?(value) }
      end
      if rules.has_prefix?
        prefix = rules.prefix
        rule.call(:prefix, "value does not have prefix `#{prefix}`") { |value| !value.start_with?(prefix) }
      end
      if rules.has_suffix?
        suffix = rules.suffix
        rule.call(:suffix, "value does not have suffix `#{suffix}`") { |value| !value.end_with?(suffix) }
      end
      if rules.has_contains?
        needle = rules.contains
        rule.call(:contains, "value does not contain substring `#{needle}`") { |value| !value.include?(needle) }
      end
      if rules.has_not_contains?
        excluded = rules.not_contains
        rule.call(:not_contains, "value contains substring `#{excluded}`") { |value| value.include?(excluded) }
      end
      checks.concat(list_checks(:string, rules))
      checks.concat(uuid_checks(rules))
    end

    def length_violated?(name, length, limit)
      if name.start_with?("min") then length < limit
      elsif name.start_with?("max") then length > limit
      else length != limit
      end
    end

    def uuid_checks(rules)
      shape, name, id = if rules.uuid then [UUID, "UUID", "uuid"]
                        elsif rules.tuuid then [TUUID, "trimmed UUID", "tuuid"]
                        end
      return [] unless shape

      empty = ["string.#{id}_empty", "value is empty, which is not a valid #{name}"].freeze
      invalid = ["string.#{id}", "value must be a valid #{name}"].freeze
      check = lambda do |value|
        if value.empty? then empty
        elsif !shape.match?(value) then invalid
        end
      end
      [check]
    end

    def const_checks(type, rules)
      return [] unless rules.has_const?

      expected = comparable(type, rules.const)
      shown = type == :string ? "`#{rules.const}`" : show(type, rules.const)
      failure = ["#{type}.const", "value must equal #{shown}"].freeze
      [->(value) { failure unless value == expected }]
    end

    # protovalidate's lt/lte/gt/gte family in one place. With both bounds, a lower bound above
    # the upper one means "outside the gap" (the *_exclusive rules). NaN fails every comparison,
    # which is what the double rules' explicit isNan() checks amount to.
    def bounds_checks(type, rules)
      lower_op = rules.greater_than
      upper_op = rules.less_than
      return [] if lower_op.nil? && upper_op.nil?

      lower = lower_op && rules.public_send(lower_op)
      upper = upper_op && rules.public_send(upper_op)
      lower_bound = lower && comparable(type, lower)
      upper_bound = upper && comparable(type, upper)
      if lower && upper
        exclusive = upper_bound < lower_bound
        failure = ["#{type}.#{lower_op}_#{upper_op}#{"_exclusive" if exclusive}",
                   "value must be #{BOUNDS[lower_op]} #{show(type, lower)} #{exclusive ? "or" : "and"} " \
                   "#{BOUNDS[upper_op]} #{show(type, upper)}"].freeze
        [lambda do |value|
          lower_ok = satisfies?(value, lower_op, lower_bound)
          upper_ok = satisfies?(value, upper_op, upper_bound)
          failure unless exclusive ? lower_ok || upper_ok : lower_ok && upper_ok
        end]
      else
        op = lower_op || upper_op
        bound = lower_bound || upper_bound
        failure = ["#{type}.#{op}", "value must be #{BOUNDS[op]} #{show(type, lower || upper)}"].freeze
        [->(value) { failure unless satisfies?(value, op, bound) }]
      end
    end

    def list_checks(type, rules)
      checks = []
      unless rules.in.empty?
        allowed = rules.in.map { |item| comparable(type, item) }
        missing = ["#{type}.in", "value must be in list #{list(rules.in, type)}"].freeze
        checks << ->(value) { missing unless allowed.include?(value) }
      end
      unless rules.not_in.empty?
        denied = rules.not_in.map { |item| comparable(type, item) }
        forbidden = ["#{type}.not_in", "value must not be in list #{list(rules.not_in, type)}"].freeze
        checks << ->(value) { forbidden if denied.include?(value) }
      end
      checks
    end

    def satisfies?(value, operator, bound)
      case operator
      when :lt then value < bound
      when :lte then value <= bound
      when :gt then value > bound
      else value >= bound
      end
    end

    def comparable(type, value)
      type == :duration ? seconds(value) : value
    end

    def seconds(message)
      Rational((message.seconds * NANOS) + message.nanos, NANOS)
    end

    def show(type, value)
      case type
      when :duration
        total = seconds(value)
        "#{total.denominator == 1 ? total.to_i : total.to_f}s"
      when :float, :double then value.finite? && value == value.truncate ? value.to_i.to_s : value.to_s
      else value.to_s
      end
    end

    def list(values, type)
      "[#{values.map { |value| show(type, value) }.join(", ")}]"
    end

    # RE2 anchors ^ and $ at the ends of the text, Ruby at the ends of every line: left as is,
    # "USD\nEUR" would pass ^[A-Z]{3}$ here and fail on the server.
    def re2_anchors(pattern)
      source = +""
      escaped = in_class = false
      pattern.each_char do |char|
        if escaped
          escaped = false
        elsif char == "\\"
          escaped = true
        elsif char == "["
          in_class = true
        elsif char == "]"
          in_class = false
        elsif !in_class && ["^", "$"].include?(char)
          char = char == "^" ? "\\A" : "\\z"
        end
        source << char
      end
      source
    end
  end
end
