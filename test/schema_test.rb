# frozen_string_literal: true

require_relative "test_helper"

class WellKnownCatalogTest < Minitest::Test
  GOLDEN = File.expand_path("fixtures/well_known_events.golden", __dir__)

  # The catalog is read from the vendored protos at runtime, so this golden file is what makes a
  # proto sync that adds, drops or re-targets an event show up in review. Accept a reviewed
  # change with UPDATE_GOLDEN=1.
  def test_matches_the_golden_file
    lines = Pug::WellKnown::CATALOG.map { |kind, klass| "#{kind} #{klass.descriptor.name}" }.sort
    actual = "#{lines.join("\n")}\n"
    File.write(GOLDEN, actual) if ENV["UPDATE_GOLDEN"]
    assert_equal File.read(GOLDEN), actual, "well-known catalog drifted; review it and rerun with UPDATE_GOLDEN=1"
  end

  def test_holds_server_events_only
    %w[purchase feature_used signup video_play error_occurred].each do |kind|
      assert Pug::WellKnown[kind], "#{kind} missing"
    end
    %w[page_view screen_view click app_open app_crashed].each do |kind|
      assert_nil Pug::WellKnown[kind], "#{kind} is not a server event"
    end
  end

  # options.proto's contract for the event options themselves, over every event message.
  def test_event_options_contract
    namespace = Pug::Proto::Common::Events::V1
    seen = {}
    namespace.constants.map { |name| namespace.const_get(name) }.grep(Class).each do |klass|
      options = klass.descriptor.options
      next unless Pug::WellKnown::KIND.has?(options)

      kind = Pug::WellKnown::KIND.get(options)
      refute seen.key?(kind), "kind #{kind} is on both #{seen[kind]} and #{klass.descriptor.name}"
      seen[kind] = klass.descriptor.name
      refute_includes Pug::WellKnown::PLATFORMS.get(options), :PLATFORM_UNSPECIFIED,
                      "#{klass.descriptor.name} lists UNSPECIFIED"
    end
    assert_operator seen.size, :>, Pug::WellKnown::CATALOG.size
  end

  # The well-known lookup relies on it, and on an event the catalog leaves out a custom key lands where the field would.
  def test_camel_cases_keys_as_protobuf_names_fields_in_json
    namespace = Pug::Proto::Common::Events::V1
    namespace.constants.map { |name| namespace.const_get(name) }.grep(Class).each do |klass|
      klass.descriptor.each { |field| assert_equal field.json_name, Pug::EventBuilder.camel_case(field.name) }
    end
  end
end

class ValidatorTest < Minitest::Test
  V = Pug::Validator
  Rules = Pug::Proto::Buf::Validate

  def violations(rules, type, value)
    V.type_checks(type, rules).filter_map { |check| check.call(value) }.map { |id, message| "f: #{message} [#{id}]" }
  end

  # A rule the validator can't evaluate would otherwise go silently unenforced.
  def test_supports_every_rule_on_the_schemas_the_sdk_validates
    roots = [Pug::Proto::Sdk::Events::V1::Event, Pug::Proto::Sdk::Profiles::V1::IdentifyRequest,
             *Pug::WellKnown::CATALOG.values]
    assert_empty(roots.flat_map { |klass| V.unsupported_rules(klass.descriptor) })
  end

  def test_reports_rules_it_cannot_evaluate
    unsupported = V.unsupported_rules(Pug::Proto::Shared::Activity::V1::GetActivityFeedRequest.descriptor)
    assert_includes unsupported,
                    "shared.activity.v1.GetActivityFeedRequest: cel activity_feed.events_non_empty_in_multi"
    assert_includes V.unsupported_rules(Pug::Proto::Common::V1::GetFilterSchemaRequest.descriptor),
                    "common.v1.GetFilterSchemaRequest.allowed_types: repeated"
  end

  # RE2 anchors at the ends of the text; Ruby's ^ and $ match at every line.
  def test_patterns_anchor_like_re2
    rules = Rules::StringRules.new(pattern: "^[A-Z]{3}$")
    assert_empty violations(rules, :string, "USD")
    assert_equal ["f: value does not match regex pattern `^[A-Z]{3}$` [string.pattern]"],
                 violations(rules, :string, "USD\nEUR")
    assert_empty violations(Rules::StringRules.new(pattern: "^[^$]+$"), :string, "a^b")
  end

  def test_string_rules
    rules = Rules::StringRules.new(min_len: 2, max_len: 3, max_bytes: 3, prefix: "a", suffix: "z", contains: "b",
                                   not_contains: "q", in: %w[abz aéz], not_in: %w[aqz])
    assert_empty violations(rules, :string, "abz")
    assert_equal ["f: value length must be at most 3 bytes [string.max_bytes]",
                  "f: value does not contain substring `b` [string.contains]"],
                 violations(rules, :string, "aéz")
    assert_includes violations(rules, :string, "a"), "f: value length must be at least 2 characters [string.min_len]"
  end

  def test_uuid_rules
    rules = Rules::StringRules.new(uuid: true)
    assert_empty violations(rules, :string, Pug::TestSupport::UUID)
    assert_equal ["f: value must be a valid UUID [string.uuid]"], violations(rules, :string, "nope")
    assert_equal ["f: value is empty, which is not a valid UUID [string.uuid_empty]"], violations(rules, :string, "")
  end

  def test_single_bounds
    assert_equal ["f: value must be greater than 0 [double.gt]"],
                 violations(Rules::DoubleRules.new(gt: 0), :double, 0.0)
    assert_equal ["f: value must be less than or equal to 1.5 [double.lte]"],
                 violations(Rules::DoubleRules.new(lte: 1.5), :double, 2.0)
    assert_empty violations(Rules::Int64Rules.new(gte: 0), :int64, 0)
  end

  def test_nan_fails_every_bound
    assert_equal ["f: value must be greater than 0 [double.gt]"],
                 violations(Rules::DoubleRules.new(gt: 0), :double, Float::NAN)
  end

  def test_ranges
    rules = Rules::Int32Rules.new(gte: 0, lte: 10)
    assert_empty violations(rules, :int32, 10)
    assert_equal ["f: value must be greater than or equal to 0 and less than or equal to 10 [int32.gte_lte]"],
                 violations(rules, :int32, 11)
  end

  # A lower bound above the upper one means "outside the gap".
  def test_exclusive_ranges
    rules = Rules::Int32Rules.new(gt: 10, lt: 5)
    assert_empty violations(rules, :int32, 3)
    assert_empty violations(rules, :int32, 12)
    assert_equal ["f: value must be greater than 10 or less than 5 [int32.gt_lt_exclusive]"],
                 violations(rules, :int32, 7)
  end

  def test_const_and_lists
    assert_equal ["f: value must equal 3 [uint32.const]"], violations(Rules::UInt32Rules.new(const: 3), :uint32, 4)
    assert_equal ["f: value must be in list [1, 2] [int64.in]"],
                 violations(Rules::Int64Rules.new(in: [1, 2]), :int64, 3)
    assert_equal ["f: value must not be in list [3] [int64.not_in]"],
                 violations(Rules::Int64Rules.new(not_in: [3]), :int64, 3)
  end

  def test_in_and_not_in_on_one_field
    rules = Rules::Int64Rules.new(in: [1, 2, 3], not_in: [2])
    assert_empty violations(rules, :int64, 1)
    assert_equal ["f: value must not be in list [2] [int64.not_in]"], violations(rules, :int64, 2)
    assert_equal ["f: value must be in list [1, 2, 3] [int64.in]"], violations(rules, :int64, 4)
  end

  def test_duration_bounds
    rules = Rules::DurationRules.new(gte: { seconds: 0 }, lt: { seconds: 1, nanos: 500_000_000 })
    assert_empty violations(rules, :duration, Rational(1))
    assert_equal ["f: value must be greater than or equal to 0s and less than 1.5s [duration.gte_lt]"],
                 violations(rules, :duration, Rational(3, 2))
  end

  def test_formats_violations_like_protovalidate
    event = Pug::Proto::Sdk::Events::V1::Event.new(
      event_id: Pug::TestSupport::UUID, kind: "k", occur_time: Time.now, distinct_id: "u",
      session_id: Pug::TestSupport::UUID,
      custom_properties: { "s" => Pug::Proto::Common::V1::PropertyValue.new }
    )
    assert_equal 'custom_properties["s"].value: exactly one field is required in oneof [required]',
                 V.format(V.validate(event))
  end

  # TimestampRules has no in/not_in, and lt_now/gt_now/within compare with the clock, so they are
  # reported, as anything a schema adopts that the validator can't evaluate must be.
  def test_reports_timestamp_rules_instead_of_crashing
    [{ gt: { seconds: 0 } }, { lt_now: true }].each do |timestamp|
      rules = Rules::FieldRules.new(timestamp: timestamp)
      assert_equal ["timestamp"], V.unsupported_field_rules(rules, :single)
      assert_empty V.field_checks(rules)
    end
  end

  def test_required_on_a_list_or_map_whose_elements_have_no_rules
    message = required_collections
    assert_equal ["tags: value is required [required]", "items: value is required [required]",
                  "attrs: value is required [required]"], V.validate(message.new).map(&:to_s)
    assert_empty V.validate(message.new(tags: ["a"], items: [{ x: "y" }], attrs: { "k" => "v" }))
    assert_empty V.unsupported_rules(message.descriptor)
  end

  def required_collections
    pool = Google::Protobuf::DescriptorPool.generated_pool
    name = "pug_test.RequiredCollections"
    return pool.lookup(name).msgclass if pool.lookup(name)

    required = Google::Protobuf::FieldOptions.new
    V::FIELD_RULES.set(required, Rules::FieldRules.new(required: true))
    entry = { name: "AttrsEntry", options: { map_entry: true },
              field: [{ name: "key", number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL },
                      { name: "value", number: 2, type: :TYPE_STRING, label: :LABEL_OPTIONAL }] }
    repeated = { label: :LABEL_REPEATED, options: required }
    file = Google::Protobuf::FileDescriptorProto.new(
      name: "pug_test/required_collections.proto", package: "pug_test", syntax: "proto3",
      message_type: [
        { name: "Plain", field: [{ name: "x", number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL }] },
        { name: "RequiredCollections", nested_type: [entry], field: [
          { name: "tags", number: 1, type: :TYPE_STRING, **repeated },
          { name: "items", number: 2, type: :TYPE_MESSAGE, type_name: ".pug_test.Plain", **repeated },
          { name: "attrs", number: 3, type: :TYPE_MESSAGE, type_name: ".pug_test.RequiredCollections.AttrsEntry",
            **repeated }
        ] }
      ]
    )
    pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
    pool.lookup(name).msgclass
  end

  def test_skips_messages_without_rules
    refute V.plan(Google::Protobuf::Struct.descriptor).active
    request = Pug::Proto::Sdk::Profiles::V1::IdentifyRequest.new(
      external_id: "u", traits: Google::Protobuf::Struct.from_hash("a" => { "b" => [1, 2, { "c" => nil }] })
    )
    assert_empty V.validate(request)
  end
end

class ProceduresTest < Minitest::Test
  FILES = [Pug::Proto::Sdk::Events::V1::Event, Pug::Proto::Sdk::Profiles::V1::IdentifyRequest,
           Pug::Proto::Shared::Profiles::V1::Profile, Pug::Proto::Shared::Activity::V1::GetActivityFeedRequest,
           Pug::Proto::Shared::Insights::V1::QueryRequest].map { |klass| klass.descriptor.file_descriptor.to_proto }

  # The procedure table is hand-written, since Ruby's protobuf generates no service stubs.
  def test_every_procedure_matches_its_service_definition
    methods = FILES.flat_map do |file|
      file.service.flat_map do |service|
        service["method"].map { |method| ["#{file.package}.#{service.name}/#{method.name}", method] }
      end
    end.to_h
    Pug::RPC::PROCEDURES.each do |name, (path, request, response)|
      method = methods.fetch(path) { flunk "#{name}: no such procedure #{path}" }
      assert_equal ".#{request.descriptor.name}", method.input_type, name
      assert_equal ".#{response.descriptor.name}", method.output_type, name
      assert_equal name == :profiles_list, method.server_streaming, name
    end
  end
end

class ErrorTest < Minitest::Test
  def test_message_carries_the_code
    assert_equal "not_found: no profile", Pug::Error.new("no profile", code: :not_found).message
    assert_equal "unavailable", Pug::Error.new("", code: :unavailable).message
    assert_equal "kaboom", Pug::Error.new("kaboom").message
    assert_nil Pug::Error.new("kaboom").code
  end

  def test_reads_return_a_pug_error_unchanged
    original = Pug::Error.new("boom", code: :not_found)
    error = assert_raises(Pug::Error) { Pug::Reads.call { raise original } }
    assert_same original, error
  end

  def test_reads_wrap_any_other_error_keeping_the_cause
    generic = ArgumentError.new("kaboom")
    error = assert_raises(Pug::Error) { Pug::Reads.call { raise generic } }
    assert_equal "kaboom", error.message
    assert_nil error.code
    assert_same generic, error.cause
  end

  def test_reads_let_the_callers_own_errors_through
    mine = IOError.new("mine")
    raised = assert_raises(IOError) { Pug::Reads.call { raise Pug::Connect::Passthrough, mine } }
    assert_same mine, raised
    assert_nil raised.cause
  end
end
