# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "date"

module EventBuilding
  include Pug::TestSupport

  # Keyword-free, so a braceless Hash is the properties: build("my.custom", plan: "pro").
  def build(kind, properties = nil)
    build_with(kind, properties)
  end

  def build_with(kind, properties, session_id: UUID, **)
    event, = Pug::EventBuilder.new(Pug::Log.new(logs)).build(kind, session_id, "user_1", properties, **)
    event
  end

  def property(properties, key)
    value = properties[key]
    value && [value.value, value.public_send(value.value)]
  end

  def custom(event, key)
    property(event.custom_properties, key)
  end

  def auto(event, key)
    property(event.auto_properties, key)
  end
end

class EventBuilderTest < Minitest::Test
  include EventBuilding

  def test_maps_property_types_into_the_custom_properties_oneof
    event = build("my.custom", amount: 5, ratio: 1.5, ok: true, name: "hello", when: Time.at(0))
    assert_equal [:int_value, 5], custom(event, "amount")
    assert_equal [:double_value, 1.5], custom(event, "ratio")
    assert_equal [:bool_value, true], custom(event, "ok")
    assert_equal [:string_value, "hello"], custom(event, "name")
    assert_equal :timestamp_value, custom(event, "when").first
    assert_equal "my.custom", event.kind
    assert_equal "user_1", event.distinct_id
  end

  def test_sets_the_sdk_auto_properties
    event = build("my.custom")
    assert_equal [:string_value, "pug-ruby"], auto(event, "$lib")
    assert_equal [:string_value, Pug::VERSION], auto(event, "$sdkVersion")
    assert_equal [:string_value, "server"], auto(event, "$platform")
    assert_match(/\A\h{8}-\h{4}-7\h{3}-\h{4}-\h{12}\z/, event.event_id)
    assert_equal UUID, event.session_id
  end

  def test_drops_an_event_failing_validation
    assert_nil build_with("my.custom", nil, session_id: "not-a-uuid")
    assert_match(/failed Event-level validation: session_id: value must be a valid UUID/, logs.errors.last)
  end

  def test_drops_a_kind_outside_the_charset
    assert_nil build("order completed")
    assert_nil build("valid\n$$$")
    assert_match(/kind: value does not match regex pattern/, logs.errors.last)
  end

  def test_a_dollar_prefixed_custom_key_drops_the_event
    assert_nil build("my.custom", "$plan" => "pro")
    assert_match(/custom_properties keys must not start with '\$'/, logs.errors.last)
  end

  def test_drops_non_representable_property_values
    event = build("my.custom", bad: Float::INFINITY, nan: Float::NAN, big: 2**64, odd: Object.new, good: "x")
    assert_equal %w[good], event.custom_properties.keys
    assert_equal 4, logs.warnings.grep(/not representable/).size
  end

  def test_omits_nil_values_silently
    event = build("my.custom", gone: nil, kept: 1)
    assert_equal %w[kept], event.custom_properties.keys
    assert_empty logs.warnings
  end

  def test_sends_zero_values
    event = build("my.custom", off: false, zero: 0, none: 0.0, blank: "", negative: -5)
    assert_equal({ "off" => false, "zero" => 0, "none" => 0.0, "blank" => "", "negative" => -5 },
                 event.custom_properties.keys.to_h { |key| [key, custom(event, key).last] })
  end

  def test_keeps_the_int64_extremes_and_drops_just_past_them
    event = build("my.custom", max: (2**63) - 1, min: -(2**63), over: 2**63, under: -(2**63) - 1)
    assert_equal [[:int_value, -(2**63)], [:int_value, (2**63) - 1]], [custom(event, "min"), custom(event, "max")]
    assert_equal %w[max min], event.custom_properties.keys.sort
    assert_equal 2, logs.warnings.grep(/overflows int64/).size
  end

  def test_drops_a_time_outside_the_timestamp_range
    event = build("my.custom", far: Time.utc(10_000), ok: 1)
    assert_equal %w[ok], event.custom_properties.keys
    assert_match(/"far" .* out of the timestamp range/, logs.warnings.last)
  end

  def test_maps_ruby_values_by_type
    event = build("my.custom",
                  sym: :pro, float_whole: 10.0, decimal: BigDecimal("1.25"), rational: Rational(1, 4),
                  date: Date.new(2026, 10, 10), datetime: DateTime.new(2026, 10, 10, 12),
                  duration: Google::Protobuf::Duration.new(seconds: 90, nanos: 500_000_000),
                  stamp: Google::Protobuf::Timestamp.new(seconds: 5),
                  list: [1, "a", nil], hash: { a: { b: true } })
    assert_equal [:string_value, "pro"], custom(event, "sym")
    assert_equal [:double_value, 10.0], custom(event, "float_whole")
    assert_equal [:double_value, 1.25], custom(event, "decimal")
    assert_equal [:double_value, 0.25], custom(event, "rational")
    assert_equal [:string_value, "2026-10-10"], custom(event, "date")
    assert_equal :timestamp_value, custom(event, "datetime").first
    assert_equal [:string_value, "90.5s"], custom(event, "duration")
    assert_equal 5, event.custom_properties["stamp"].timestamp_value.seconds
    assert_equal [:string_value, '[1,"a",null]'], custom(event, "list")
    assert_equal [:string_value, '{"a":{"b":true}}'], custom(event, "hash")
  end

  def test_leaves_a_time_property_in_its_zone
    local = Time.new(2026, 10, 12, 9, 30, 0, "+05:30")
    event = build("my.custom", local: local, frozen: local.dup.freeze)
    refute local.utc?
    assert_equal local.to_i, event.custom_properties["local"].timestamp_value.seconds
    assert_equal local.to_i, event.custom_properties["frozen"].timestamp_value.seconds
  end

  def test_keys_may_be_symbols_or_strings
    event = build("my.custom", :a => 1, "b" => 2, 3 => 3)
    assert_equal %w[3 a b], event.custom_properties.keys.sort
  end

  def test_repairs_and_truncates_strings
    event = build("my.custom",
                  bad: "ok\xFF".dup.force_encoding(Encoding::UTF_8),
                  latin: "Jos\xE9".dup.force_encoding(Encoding::ISO_8859_1),
                  binary: "caf\xC3\xA9".b,
                  long: "é" * 600,
                  "k\xFF".dup.force_encoding(Encoding::UTF_8) => 1)
    assert_equal "ok\uFFFD", custom(event, "bad").last
    assert_equal "José", custom(event, "latin").last
    assert_equal "café", custom(event, "binary").last
    long = custom(event, "long").last
    assert_equal 512, long.length
    assert long.valid_encoding?
    assert_includes event.custom_properties.keys, "k\uFFFD"
    assert_match(/exceeds 1024 bytes/, logs.warnings.last)
  end

  def test_truncation_never_splits_a_character
    value = custom(build("my.custom", s: "a#{"é" * 600}"), "s").last
    assert_equal 1023, value.bytesize
    assert value.valid_encoding?
  end

  def test_a_value_that_is_not_json_serializable_is_skipped
    cyclic = []
    cyclic << cyclic
    event = build("my.custom", cyclic: cyclic, nan: { x: Float::NAN }, set: [Set[1]], ok: 1)
    assert_equal %w[ok], event.custom_properties.keys
    assert_equal 3, logs.warnings.grep(/not JSON-serializable/).size
    assert_match(/Set has no JSON form/, logs.warnings.last)
  end

  # JSON.generate alone would write each of these as its to_s: "1970-01-01 00:00:00 UTC", "0.15e1".
  def test_maps_nested_values_as_it_would_on_their_own
    event = build("my.custom", nested: { at: Time.at(0).utc, on: Date.new(2026, 10, 12), price: BigDecimal("1.5"),
                                         plan: :pro, 1 => [nil] })
    assert_equal '{"at":"1970-01-01T00:00:00.000Z","on":"2026-10-12","price":1.5,"plan":"pro","1":[null]}',
                 custom(event, "nested").last
  end

  def test_a_kind_named_like_an_object_method_is_a_custom_event
    event = build("to_s", a: 1)
    assert_equal "to_s", event.kind
    assert_equal [:int_value, 1], custom(event, "a")
  end

  def test_a_symbol_kind_is_its_name
    assert_equal "my.custom", build(:"my.custom").kind
  end

  def test_drops_an_event_too_large_to_send
    huge = (1..5000).to_h { |i| ["k#{i}", "x" * 1000] }
    assert_nil build("my.custom", huge)
    assert_match(/too large to send/, logs.errors.last)
  end
end

class WellKnownEventTest < Minitest::Test
  include EventBuilding

  PURCHASE = { product_id: "p1", amount: 9.99, currency: "USD", quantity: 2 }.freeze

  def test_maps_known_fields_through_their_proto_type
    event = build("purchase", amount: 9.99, quantity: 2, currency: "USD")
    assert_equal [:double_value, 9.99], custom(event, "amount")
    assert_equal [:int_value, 2], custom(event, "quantity")
    assert_equal [:string_value, "USD"], custom(event, "currency")
  end

  # The core well-known invariant: a whole-number double stays a double.
  def test_keeps_double_vs_int_from_the_field_type
    event = build("purchase", amount: 10, quantity: 1.0, currency: "USD")
    assert_equal [:double_value, 10.0], custom(event, "amount")
    assert_equal [:int_value, 1], custom(event, "quantity")
  end

  def test_sends_typed_fields_under_their_json_names
    event = build("purchase", PURCHASE)
    assert_equal [:string_value, "p1"], custom(event, "productId")
    assert_nil event.custom_properties["product_id"]
  end

  def test_accepts_json_names_and_string_keys
    event = build("purchase", "productId" => "p1", "amount" => 9.99)
    assert_equal [:string_value, "p1"], custom(event, "productId")
  end

  def test_refuses_a_field_given_under_both_names
    assert_nil build("purchase", product_id: "p1", productId: "p2")
    assert_match(/product_id: given twice, as product_id and productId/, logs.errors.last)
  end

  def test_routes_unknown_properties_through_the_heuristic_and_skips_unset_fields
    event = build("purchase", amount: 5, currency: "USD", referrer: "news")
    assert_equal [:string_value, "news"], custom(event, "referrer")
    assert_nil event.custom_properties["productId"]
    assert_nil event.custom_properties["quantity"]
  end

  def test_a_nil_field_is_unset
    event = build("purchase", amount: 5, quantity: nil)
    assert_nil event.custom_properties["quantity"]
  end

  def test_accepts_a_symbol_for_a_string_field
    assert_equal [:string_value, "USD"], custom(build("purchase", currency: :USD), "currency")
  end

  [
    [:quantity, 1.5, "quantity: expected int32, got 1.5"],
    [:quantity, 2**31, "quantity: expected int32, got 2147483648"],
    [:quantity, "2", "quantity: expected int32, got String"],
    [:quantity, true, "quantity: expected int32, got TrueClass"],
    [:amount, "9.99", "amount: expected double, got String"],
    [:product_id, 123, "product_id: expected string, got Integer"]
  ].each do |field, value, message|
    define_method("test_drops_the_event_when_#{field}_is_#{value.inspect.gsub(/\W/, "_")}") do
      assert_nil build("purchase", PURCHASE.merge(field => value))
      assert_equal "[Pug SDK] Event \"purchase\" dropped: invalid properties for " \
                   "\"common.events.v1.PurchaseProperties\": #{message}", logs.errors.last
    end
  end

  def test_drops_the_event_when_a_field_fails_validation
    assert_nil build("purchase", PURCHASE.merge(currency: "usd"))
    assert_match(/validation failed for "common.events.v1.PurchaseProperties": currency: value does not match/,
                 logs.errors.last)
  end

  def test_drops_the_event_when_a_required_field_is_missing
    assert_nil build("product_viewed", price: 1.0)
    assert_match(/product_id: value is required \[required\]/, logs.errors.last)
  end

  def test_drops_the_event_when_a_double_is_not_finite
    assert_nil build("purchase", PURCHASE.merge(amount: Float::INFINITY))
    assert_match(/custom_properties\["amount"\]\.double_value: value must be finite \[double\.finite\]/,
                 logs.errors.last)
  end

  def test_sends_a_false_bool_field
    event = build("error_occurred", error_code: "E1", unhandled: false)
    assert_equal [:bool_value, false], custom(event, "unhandled")
  end

  def test_sends_int64_fields_as_ints
    assert_equal [:int_value, 1024], custom(build("file_uploaded", file_id: "f1", size_bytes: 1024), "sizeBytes")
    assert_equal [:int_value, 2**53], custom(build("file_uploaded", file_id: "f1", size_bytes: 2**53), "sizeBytes")
  end

  def test_refuses_an_int64_that_may_already_be_rounded
    assert_nil build("file_uploaded", file_id: "f1", size_bytes: 2.0**53)
    assert_match(/size_bytes: expected a safe integer, got 9.007199254740992e\+15/, logs.errors.last)
  end

  def test_refuses_a_string_in_an_int64_field_instead_of_parsing_it
    assert_nil build("file_uploaded", file_id: "f1", size_bytes: " ")
    assert_match(/size_bytes: expected int64, got String/, logs.errors.last)
  end

  def test_keeps_a_string_with_invalid_utf8_repaired
    event = build("purchase", PURCHASE.merge(product_id: "gift \xF0\x9F".dup.force_encoding(Encoding::UTF_8)))
    assert_equal [:string_value, "gift \uFFFD"], custom(event, "productId")
  end

  [
    [{ seconds: 0 }, "0s"],
    [{ seconds: 0, nanos: 500_000_000 }, "0.5s"],
    [{ seconds: 1, nanos: 5_000_000 }, "1.005s"],
    [{ seconds: 90 }, "90s"],
    [{ seconds: 90, nanos: 500_000_000 }, "90.5s"],
    [{ seconds: 1, nanos: -500_000_000 }, "0.5s"],
    [{ seconds: 1, nanos: 1_000_000_000 }, "2s"],
    [{ "seconds" => 3 }, "3s"],
    [Google::Protobuf::Duration.new(seconds: 2, nanos: 250_000_000), "2.25s"],
    [90, "90s"],
    [1.5, "1.5s"],
    [0.1, "0.1s"],
    [Rational(1, 3), "0.333333333s"]
  ].each_with_index do |(position, wire), i|
    define_method("test_sends_duration_#{i}_as_#{wire.tr(".", "_")}") do
      event = build("video_play", video_id: "v1", position: position)
      assert_equal [:string_value, wire], custom(event, "position")
    end
  end

  [
    ["90s", "expected a Duration (seconds, { seconds:, nanos: } or Google::Protobuf::Duration), got String"],
    [{ ms: 90_000 }, "expected a Duration ({ seconds:, nanos: }), got keys ms"],
    [Time.at(90), "expected a Duration (seconds, { seconds:, nanos: } or Google::Protobuf::Duration), got Time"],
    [Float::NAN, "expected a finite number of seconds, got NaN"]
  ].each_with_index do |(position, message), i|
    define_method("test_drops_the_event_when_a_duration_is_invalid_#{i}") do
      assert_nil build("video_play", video_id: "v1", position: position)
      assert logs.errors.last.end_with?("\": position: #{message}"), logs.errors.last
    end
  end

  def test_names_the_duration_field_a_nested_error_came_from
    assert_nil build("video_seeked", video_id: "v1", from_position: { seconds: 5 }, to_position: { seconds: "9" })
    assert_match(/to_position: seconds: expected int64, got String\z/, logs.errors.last)
  end

  def test_a_negative_duration_fails_validation
    assert_nil build("video_play", video_id: "v1", position: -1)
    assert_match(/position: value must be greater than or equal to 0s \[duration.gte\]/, logs.errors.last)
  end

  def test_does_not_warn_about_an_unset_duration
    refute_nil build("video_play", video_id: "v1")
    assert_empty logs.warnings
  end

  def test_formats_durations
    assert_equal "0s", Pug::EventBuilder.format_duration(0, 0)
    assert_equal "-1.5s", Pug::EventBuilder.format_duration(-1, -500_000_000)
    assert_equal "0.000000001s", Pug::EventBuilder.format_duration(0, 1)
  end
end

class OccurTimeTest < Minitest::Test
  include EventBuilding

  def occur_time(timestamp)
    build_with("my.custom", nil, timestamp: timestamp).occur_time
  end

  def test_honors_an_explicit_time
    time = occur_time(Time.at(1_700_000_000, 123_456_789, :nsec))
    assert_equal 1_700_000_000, time.seconds
    assert_equal 123_456_789, time.nanos
  end

  # Regression guard from sdk-node: the epoch is a real timestamp, not "unset".
  def test_keeps_the_epoch
    assert_equal 0, occur_time(Time.at(0)).seconds
  end

  def test_accepts_a_datetime
    assert_equal 1_700_000_000, occur_time(Time.at(1_700_000_000).to_datetime).seconds
  end

  def test_falls_back_to_now_with_a_warning_for_an_out_of_range_or_non_time_value
    [Time.at(-1), Time.utc(10_000), 1_700_000_000_000, "2026-10-10"].each do |timestamp|
      logs.clear
      now = Time.now.to_i
      seconds = occur_time(timestamp).seconds
      assert_match(/Ignoring invalid track timestamp/, logs.warnings.last)
      assert_in_delta now, seconds, 60
    end
  end
end

class LocationTest < Minitest::Test
  include EventBuilding

  BASE_KEYS = %w[$lib $platform $sdkVersion].freeze

  def location(value)
    build_with("my.custom", nil, location: value).auto_properties
  end

  def value(properties, key)
    property(properties, key)&.last
  end

  def test_renders_every_field_as_a_geo_auto_property
    props = location(continent: "EU", country: "DE", region: "Berlin", city: " Berlin ", postal_code: "10115",
                     metro_code: "807", timezone: "Europe/Berlin", latitude: 52.52, longitude: 13.405)
    expected = { "$continent" => "EU", "$country" => "DE", "$region" => "Berlin", "$city" => "Berlin",
                 "$postalCode" => "10115", "$metroCode" => "807", "$timezone" => "Europe/Berlin",
                 "$latitude" => 52.52, "$longitude" => 13.405 }
    expected.each { |key, want| assert_equal want, value(props, key), key }
    assert_empty logs.warnings
  end

  def test_accepts_camel_case_and_string_keys
    props = location("postalCode" => "10115", "metroCode" => "807")
    assert_equal "10115", value(props, "$postalCode")
    assert_equal "807", value(props, "$metroCode")
  end

  def test_warns_about_a_field_given_twice
    props = location(postal_code: "10115", postalCode: "10117")
    assert_equal "10115", value(props, "$postalCode")
    assert_match(/postal_code is already set/, logs.warnings.last)
  end

  # Every other writer of these keys uses Float64, a different ClickHouse Variant slot.
  def test_always_renders_coordinates_as_doubles
    props = location(latitude: 52, longitude: BigDecimal("13"))
    assert_equal :double_value, props["$latitude"].value
    assert_equal :double_value, props["$longitude"].value
  end

  def test_accepts_the_poles_and_the_antimeridian
    props = location(latitude: -90, longitude: 180)
    assert_equal(-90.0, value(props, "$latitude"))
    assert_equal 180.0, value(props, "$longitude")
  end

  def test_bounds_latitude_at_90_and_longitude_at_180
    assert_nil location(latitude: 100, longitude: 13)["$latitude"]
    assert_equal 100.0, value(location(latitude: 45, longitude: 100), "$longitude")
  end

  def test_drops_a_coordinate_that_lost_its_pair
    props = location(latitude: 52.52, city: "Berlin")
    assert_nil props["$latitude"]
    assert_equal "Berlin", value(props, "$city")
    assert_match(/must be set together/, logs.warnings.last)
  end

  def test_normalizes_country_case_and_spacing
    assert_equal "DE", value(location(country: " de "), "$country")
    assert_equal "DE", value(location(country: :de), "$country")
  end

  def test_drops_a_country_outside_the_iso_set
    props = location(country: "XX", city: "Berlin")
    assert_nil props["$country"]
    assert_equal "Berlin", value(props, "$city")
    assert_match(/ISO 3166-1/, logs.warnings.last)
  end

  def test_drops_a_wrong_typed_field_and_keeps_the_event
    props = location(country: 49, latitude: "52", city: "Berlin")
    assert_nil props["$country"]
    assert_nil props["$latitude"]
    assert_equal "Berlin", value(props, "$city")
    assert_equal 2, logs.warnings.size
  end

  def test_warns_about_a_key_that_is_not_a_location_field
    props = location(country: "DE", citty: "Berlin")
    assert_equal "DE", value(props, "$country")
    assert_match(/unknown location field "citty"/, logs.warnings.last)
  end

  def test_warns_when_location_is_not_a_hash
    assert_equal BASE_KEYS, location("Berlin").keys.sort
    assert_match(/expected a Hash, got String/, logs.warnings.last)
  end

  # nil means "unknown", not a mistake: it costs the field, never the event.
  def test_treats_a_nil_field_as_absent
    props = location(country: "DE", city: nil)
    assert_nil props["$city"]
    assert_empty logs.warnings
  end

  def test_omits_empty_out_of_range_and_non_finite_values
    props = location(city: "  ", latitude: Float::NAN, longitude: 200, country: "DE")
    assert_equal (BASE_KEYS + ["$country"]).sort, props.keys.sort
    assert_equal 2, logs.warnings.size
  end

  # Silence would look identical to sending no location, while the event ships with no geo.
  def test_warns_when_no_field_is_usable
    assert_equal BASE_KEYS, location(city: "", country: "").keys.sort
    assert_match(/no usable fields/, logs.warnings.last)
  end

  def test_writes_no_geo_keys_without_a_location
    assert_equal BASE_KEYS, location(nil).keys.sort
  end
end
