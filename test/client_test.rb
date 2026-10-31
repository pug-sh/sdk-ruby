# frozen_string_literal: true

require_relative "test_helper"
require "date"

class ClientTest < Minitest::Test
  include Pug::TestSupport

  BatchCreateResponse = Pug::Proto::Sdk::Events::V1::BatchCreateResponse
  UNIMPLEMENTED = Pug::Error.new("HTTP 404", code: :unimplemented)

  def teardown
    @client&.close(timeout: 5)
  end

  # endpoint is never dialed: these tests stub the RPC layer or stop before any send.
  def client(**)
    @client = Pug::Client.new(api_key: "prv_test", endpoint: "http://localhost:1", logger: logs, **)
  end

  def stub_rpc(client, &handler)
    FakeRPC.new(&handler).tap { |rpc| client.instance_variable_set(:@rpc, rpc) }
  end

  def sent_events(client, rpc)
    client.flush(timeout: 5)
    rpc.recorded.flat_map { |name, request| name == :batch_create ? request.events.to_a : [] }
  end

  def sent_identifies(client, rpc)
    client.flush(timeout: 5)
    rpc.recorded.flat_map do |name, request|
      case name
      when :batch_identify then request.identifies.to_a
      when :identify then [request]
      else []
      end
    end
  end

  def test_requires_an_api_key
    [nil, "", 42].each do |key|
      error = assert_raises(ArgumentError) { Pug::Client.new(api_key: key) }
      assert_match(/api_key is required/, error.message)
    end
  end

  def test_rejects_a_key_that_is_not_private
    error = assert_raises(ArgumentError) { Pug::Client.new(api_key: "pub_test") }
    assert_match(/private key/, error.message)
  end

  # Net::HTTP would refuse the header on every request.
  def test_rejects_a_key_with_whitespace_or_other_unprintable_characters
    ["prv_test\n", "prv_te st", "prv_tést", "prv_\xFF".b].each do |key|
      error = assert_raises(ArgumentError) { Pug::Client.new(api_key: key) }
      assert_match(/printable ASCII without spaces/, error.message)
    end
  end

  # An IO's warn is Kernel#warn, which is private, so every log line would vanish.
  def test_rejects_a_logger_without_public_warn_and_error
    [$stderr, Object.new].each do |logger|
      error = assert_raises(ArgumentError) { Pug::Client.new(api_key: "prv_test", logger: logger) }
      assert_match(/logger must respond to warn and error/, error.message)
    end
  end

  def test_on_error_must_take_the_error_and_what_was_lost
    [->(_) {}, ->(_, _, _) {}, Class.new { def call(_) = nil }.new].each do |on_error|
      error = assert_raises(ArgumentError) { Pug::Client.new(api_key: "prv_test", on_error: on_error) }
      assert_match(/on_error must take two arguments/, error.message)
    end
    [->(_, _) {}, ->(*) {}, ->(_error, _events, _extra = nil) {}, proc { |_| },
     Class.new { def call(_, _) = nil }.new].each do |on_error|
      Pug::Client.new(api_key: "prv_test", on_error: on_error, logger: logs).close
    end
  end

  def test_inspect_leaves_out_the_key_and_the_events
    pug = client
    pug.track("u", "my.custom", note: "buffered-event")
    [pug, pug.profiles, pug.activity, pug.insights].each do |object|
      refute_match(/prv_test|buffered-event/, object.inspect)
    end
  end

  def test_rejects_an_endpoint_that_is_not_an_absolute_http_url
    ["ftp://pug.example.com", "pug.example.com", "http://", "http://exa mple.com"].each do |endpoint|
      error = assert_raises(ArgumentError) { Pug::Client.new(api_key: "prv_test", endpoint: endpoint) }
      assert_match(/endpoint must be an absolute http\(s\) URL/, error.message)
    end
  end

  def test_rejects_an_on_error_that_cannot_be_called
    assert_raises(ArgumentError) { Pug::Client.new(api_key: "prv_test", on_error: "nope") }
  end

  def test_rejects_batch_options_that_are_not_a_hash
    assert_raises(ArgumentError) { Pug::Client.new(api_key: "prv_test", batch: [100]) }
  end

  def test_falls_back_on_an_invalid_timeout
    client(timeout: -1)
    assert_match(/timeout must be a positive number/, logs.warnings.last)
  end

  def test_track_is_raise_free_on_an_invalid_distinct_id
    pug = client
    ["", nil, Object.new, :sym].each { |id| assert_nil pug.track(id, "my.custom", a: 1) }
    assert_equal 4, logs.errors.grep(/requires a non-empty distinct_id/).size
  end

  def test_track_accepts_an_integer_distinct_id
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track(42, "signup")
    assert_equal ["42"], sent_events(pug, rpc).map(&:distinct_id)
  end

  def test_track_refuses_an_id_that_is_not_utf8_and_transcodes_other_encodings
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("u\xFF".b, "my.custom")
    pug.track("Jos\xE9".dup.force_encoding(Encoding::ISO_8859_1), "my.custom")
    assert_match(/distinct_id must be valid UTF-8/, logs.errors.last)
    assert_equal ["José"], sent_events(pug, rpc).map(&:distinct_id)
  end

  def test_track_drops_a_distinct_id_with_the_reserved_prefix
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("cookieless-abc", "my.custom")
    assert_empty sent_events(pug, rpc)
    assert_match(/reserved 'cookieless-' prefix/, logs.errors.last)
  end

  def test_track_refuses_a_bad_kind_or_properties
    pug = client
    pug.track("u", nil)
    pug.track("u", "")
    pug.track("u", "my.custom", "not a hash")
    assert_equal 3, logs.errors.size
  end

  def test_track_warns_and_drops_after_close
    pug = client
    pug.close(timeout: 5)
    assert_nil pug.track("user_1", "my.custom")
    assert_match(/track\(\) called after close\(\)/, logs.warnings.last)
  end

  def test_close_returns_true_on_an_empty_buffer
    assert client.close(timeout: 5)
  end

  def test_track_carries_options_through_to_the_event
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("user_1", "my.custom", nil, timestamp: Time.at(0), location: { country: "DE" }, session_id: UUID)
    event = sent_events(pug, rpc).first
    assert_equal "DE", event.auto_properties["$country"].string_value
    assert_equal 0, event.occur_time.seconds
    assert_equal UUID, event.session_id
  end

  def test_braceless_properties_and_string_keyed_options
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("user_1", "my.custom", plan: "pro")
    pug.track("user_1", "my.custom", { plan: "team" }, "session_id" => UUID)
    first, second = sent_events(pug, rpc)
    assert_equal "pro", first.custom_properties["plan"].string_value
    assert_equal UUID, second.session_id
  end

  # Braceless, timestamp: t looks just like a property; braces keep a property named like an option.
  def test_braceless_keywords_named_after_an_option_set_it
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("u", "my.custom", timestamp: Time.at(0), session_id: UUID)
    pug.track("u", "my.custom", plan: "pro", location: { country: "DE" })
    pug.track("u", "my.custom", { location: "Berlin" })
    options_only, mixed, braced = sent_events(pug, rpc)
    assert_equal [0, UUID, {}], [options_only.occur_time.seconds, options_only.session_id,
                                 options_only.custom_properties.to_h]
    assert_equal %w[pro DE],
                 [mixed.custom_properties["plan"].string_value, mixed.auto_properties["$country"].string_value]
    assert_equal "Berlin", braced.custom_properties["location"].string_value
    assert_empty logs.warnings
  end

  def test_identify_takes_braceless_options_too
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", anonymous_id: "anon-1")
    pug.identify("user_1", plan: "pro", device_id: "d1")
    first, second = sent_identifies(pug, rpc)
    assert_equal ["anon-1", false], [first.anonymous_id, first.has_traits?]
    assert_equal ["d1", { "plan" => "pro" }], [second.device_id, second.traits.to_h]
  end

  def test_flush_and_close_warn_about_a_timeout_that_is_not_a_number_and_still_drain
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("u", "my.custom")
    assert pug.flush(timeout: "5")
    pug.track("u", "my.custom")
    assert pug.close(timeout: Float::NAN)
    assert_equal 2, rpc.recorded.size
    assert_equal ["[Pug SDK] flush() timeout must be a number of seconds; waiting without one.",
                  "[Pug SDK] close() timeout must be a number of seconds; waiting without one."], logs.warnings
  end

  def test_close_releases_connections_even_when_draining_raises
    pug = client
    pug.instance_variable_get(:@event_queue).define_singleton_method(:finish_close) { |*| raise "boom" }
    released = false
    pug.instance_variable_get(:@connect).define_singleton_method(:close) { released = true }
    assert_raises(RuntimeError) { pug.close }
    assert released
    @client = nil
  end

  def test_track_keeps_the_clients_session_for_an_empty_or_invalid_session_id
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    ["", 7, "nope", "{#{UUID}}", UUID.delete("-"), UUID.encode(Encoding::UTF_16LE)].each do |session_id|
      pug.track("u", "my.custom", nil, session_id: session_id)
    end
    assert_equal [pug.instance_variable_get(:@session_id)] * 6, sent_events(pug, rpc).map(&:session_id)
    assert_equal 5, logs.warnings.grep(/Ignoring invalid track session_id .+; expected a UUID String/).size
    assert_empty logs.errors
  end

  def test_track_ignores_unknown_options
    pug = client
    pug.track("u", "my.custom", nil, sessionId: UUID)
    pug.track("u", "my.custom", nil, "not a hash")
    assert_match(/unknown track\(\) option :sessionId/, logs.warnings.first)
    assert_match(/track\(\) options: expected a Hash/, logs.warnings.last)
  end

  def test_track_contains_unexpected_errors
    pug = client
    pug.instance_variable_get(:@events).define_singleton_method(:build) { |*, **| raise "kaboom" }
    assert_nil pug.track("u", "my.custom")
    assert_match(/Unexpected error in track\("my.custom"\): RuntimeError: kaboom/, logs.errors.last)
  end

  def test_a_raising_logger_cannot_break_track
    logger = Object.new
    def logger.error(*) = raise("logger down")
    def logger.warn(*) = raise("logger down")
    assert_nil client(logger: logger).track("", "my.custom")
  end

  def test_on_error_receives_undeliverable_events
    failures = Queue.new
    pug = client(on_error: ->(error, lost) { failures << [error, lost] })
    stub_rpc(pug) { raise Pug::Error.new("denied", code: :permission_denied) }
    pug.track("u", "my.custom")
    pug.flush(timeout: 5)
    error, lost = failures.pop(timeout: 5)
    assert_equal :permission_denied, error.code
    assert_equal [["my.custom"], []], [lost.events.map(&:kind), lost.identifies]
  end

  def test_on_error_receives_undeliverable_identifies
    failures = Queue.new
    pug = client(on_error: ->(error, lost) { failures << [error, lost] })
    stub_rpc(pug) { raise Pug::Error.new("denied", code: :permission_denied) }
    pug.identify("user_1")
    pug.flush(timeout: 5)
    error, lost = failures.pop(timeout: 5)
    assert_equal :permission_denied, error.code
    assert_equal [[], ["user_1"]], [lost.events, lost.identifies.map(&:external_id)]
    assert_match(/Permanent error, 1 identify dropped/, logs.errors.last)
  end

  def test_logs_events_the_server_dropped
    pug = client
    reasons = { "day_out_of_range" => 2 }
    stub_rpc(pug) { BatchCreateResponse.new(accepted: 1, dropped: 2, dropped_by_reason: reasons) }
    3.times { pug.track("u", "my.custom") }
    pug.flush(timeout: 5)
    assert_equal ["[Pug SDK] Server dropped 2 of 3 event(s): #{reasons}"], logs.warnings
  end

  def test_identify_is_raise_free_and_logs_an_invalid_external_id
    assert_nil client.identify("")
    assert_match(/identify\(\) requires a non-empty external_id/, logs.errors.last)
  end

  def test_identify_validates_without_dialing
    pug = client
    rpc = stub_rpc(pug)
    assert_nil pug.identify("user_1", nil, anonymous_id: "nope")
    assert_match(/Invalid identify request: anonymous_id: value does not match regex pattern/, logs.errors.last)
    pug.flush(timeout: 5)
    assert_empty rpc.recorded
  end

  def test_identify_drops_the_call_on_an_unusable_anonymous_id
    pug = client
    rpc = stub_rpc(pug)
    [5, "anon-\xFF".b].each { |anonymous_id| assert_nil pug.identify("user_1", nil, anonymous_id: anonymous_id) }
    pug.flush(timeout: 5)
    assert_empty rpc.recorded
    assert_equal 2, logs.errors.grep(/anonymous_id/).size
  end

  def test_identify_names_the_reserved_prefix
    client.identify("cookieless-abc")
    assert_match(/external_id must not start with the reserved 'cookieless-' prefix/, logs.errors.last)
  end

  # A non-Hash would otherwise reach the server as an empty Struct.
  def test_identify_drops_traits_that_are_not_a_hash
    pug = client
    ['{"plan":"pro"}', ["pro"], Date.new(2026, 1, 1)].each do |traits|
      assert_nil pug.identify("user_1", traits)
      assert_match(/traits must be a Hash/, logs.errors.last)
    end
  end

  def test_identify_drops_traits_that_are_not_json_serializable
    pug = client
    rpc = stub_rpc(pug)
    [{ tags: Set["a"] }, { id: (2**53) + 1 }].each { |traits| pug.identify("user_1", traits) }
    pug.flush(timeout: 5)
    assert_empty rpc.recorded
    assert_equal 2, logs.errors.grep(/traits must be JSON-serializable/).size
    assert_match(/9007199254740993 is out of range/, logs.errors.last)
  end

  def test_identify_skips_a_trait_holding_nan_or_infinity
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", { score: Float::NAN, best: { lap: Float::INFINITY }, laps: [1.5, -Float::INFINITY],
                             ratio: Rational(1, 3), plan: "pro" })
    traits = sent_identifies(pug, rpc).map { |request| request.traits.to_h }
    assert_equal [{ "ratio" => 1.0 / 3, "plan" => "pro" }], traits
    skipped = logs.warnings.map { |warning| warning[/trait (\S+) is not representable \(NaN or Infinity\)/, 1] }
    assert_equal ['"score"', '"best"', '"laps"'], skipped
  end

  def test_identify_sends_nested_times_as_iso8601
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", { signed_up: { at: Time.at(0).utc }, seats: 2**53 })
    assert_equal({ "signedUp" => { "at" => "1970-01-01T00:00:00.000Z" }, "seats" => 2.0**53 },
                 sent_identifies(pug, rpc).first.traits.to_h)
  end

  def test_identify_sends_snake_case_trait_keys_in_camel_case
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", { "first_name" => "Ada", firstName: "Grace", plan: "pro", "plan" => "team",
                             address: { postal_code: "10115" } })
    assert_equal({ "firstName" => "Grace", "plan" => "team", "address" => { "postal_code" => "10115" } },
                 sent_identifies(pug, rpc).first.traits.to_h)
    assert_equal ['[Pug SDK] identify() traits "first_name" and :firstName both go out as "firstName"; ' \
                  "sending the last",
                  '[Pug SDK] identify() traits :plan and "plan" both go out as "plan"; sending the last'],
                 logs.warnings
  end

  def test_identify_sends_a_utf16_trait_key_in_camel_case
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", { "first_name".encode(Encoding::UTF_16LE) => "Ada" })
    assert_equal({ "firstName" => "Ada" }, sent_identifies(pug, rpc).first.traits.to_h)
  end

  def test_identify_sends_the_request
    pug = client
    rpc = stub_rpc(pug)
    pug.identify(7, { plan: "pro", seats: 3, tags: [:a], nested: { ok: true } },
                 anonymous_id: "anon-1", device_id: "d1")
    pug.flush(timeout: 5)
    name, batch = rpc.recorded.first
    assert_equal :batch_identify, name
    assert_equal 1, batch.identifies.size
    request = batch.identifies.first
    assert_equal "7", request.external_id
    assert_equal "anon-1", request.anonymous_id
    assert_equal "d1", request.device_id
    assert_equal({ "plan" => "pro", "seats" => 3.0, "tags" => ["a"], "nested" => { "ok" => true } },
                 request.traits.to_h)
  end

  def test_identify_omits_unset_fields
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", nil, anonymous_id: "", device_id: nil)
    request = sent_identifies(pug, rpc).first
    refute request.has_traits?
    refute request.has_anonymous_id?
    refute request.has_device_id?
  end

  def test_identify_queues_until_flush
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_1", plan: "pro")
    pug.identify("user_2")
    assert_empty rpc.recorded
    pug.flush(timeout: 5)
    batches = rpc.recorded
    assert_equal [:batch_identify], batches.map(&:first)
    assert_equal %w[user_1 user_2], batches.first.last.identifies.map(&:external_id)
  end

  def test_identify_retries_a_transient_failure
    pug = client
    calls = 0
    rpc = stub_rpc(pug) do
      calls += 1
      raise Pug::Error.new("down", code: :unavailable) if calls == 1
    end
    pug.identify("user_1")
    pug.flush(timeout: 5)
    assert_equal ["[Pug SDK] Transient error sending 1 identify, will retry: Pug::Error: unavailable: down"],
                 logs.warnings
    pug.flush(timeout: 5)
    assert_equal([%w[user_1], %w[user_1]], rpc.recorded.map { |_, batch| batch.identifies.map(&:external_id) })
    assert_empty logs.errors
  end

  def test_identify_falls_back_to_one_call_each_without_batch_identify
    pug = client
    rpc = stub_rpc(pug) { |name, _| raise UNIMPLEMENTED if name == :batch_identify }
    pug.identify("user_1")
    pug.identify("user_2")
    pug.flush(timeout: 5)
    pug.identify("user_3")
    pug.flush(timeout: 5)
    calls = rpc.recorded
    assert_equal %i[batch_identify identify identify identify], calls.map(&:first)
    assert_equal(%w[user_1 user_2 user_3], calls.drop(1).map { |_, request| request.external_id })
    assert_equal ["[Pug SDK] Server has no BatchIdentify; sending identifies one at a time."], logs.warnings
  end

  def test_identify_fallback_retries_only_what_it_did_not_deliver
    pug = client
    failed = false
    rpc = stub_rpc(pug) do |name, request|
      raise UNIMPLEMENTED if name == :batch_identify
      next if failed || request.external_id != "user_2"

      failed = true
      raise Pug::Error.new("down", code: :unavailable)
    end
    %w[user_1 user_2 user_3].each { |id| pug.identify(id) }
    pug.flush(timeout: 5)
    assert_match(/Transient error sending 2 identifies, will retry/, logs.warnings.last)
    pug.flush(timeout: 5)
    sent = rpc.recorded.filter_map { |name, request| request.external_id if name == :identify }
    assert_equal %w[user_1 user_2 user_2 user_3], sent
  end

  def test_identify_fallback_dead_letters_only_what_it_did_not_deliver
    failures = Queue.new
    pug = client(on_error: ->(error, lost) { failures << [error, lost] })
    stub_rpc(pug) do |name, request|
      raise UNIMPLEMENTED if name == :batch_identify
      raise Pug::Error.new("bad", code: :invalid_argument) if request.external_id == "user_2"
    end
    %w[user_1 user_2 user_3].each { |id| pug.identify(id) }
    pug.flush(timeout: 5)
    error, lost = failures.pop(timeout: 5)
    assert_equal :invalid_argument, error.code
    assert_equal %w[user_2 user_3], lost.identifies.map(&:external_id)
  end

  def test_identify_drops_one_too_large_to_send
    pug = client
    rpc = stub_rpc(pug)
    pug.identify("user_big", blob: "x" * (2 * 1024 * 1024))
    pug.identify("user_small")
    assert_equal %w[user_small], sent_identifies(pug, rpc).map(&:external_id)
    assert_match(/Identify "user_big" dropped: \d+ bytes is too large to send \(limit 921600\)/, logs.errors.last)
  end

  def test_identify_contains_unexpected_errors
    pug = client
    pug.instance_variable_get(:@identify_queue).define_singleton_method(:enqueue) { |*| raise "kaboom" }
    assert_nil pug.identify("user_1")
    assert_match(/Unexpected error in identify\("user_1"\): RuntimeError: kaboom/, logs.errors.last)
  end

  def test_close_drains_events_and_identifies
    pug = client
    rpc = stub_rpc(pug) { |name, _| BatchCreateResponse.new if name == :batch_create }
    pug.track("user_1", "my.custom")
    pug.identify("user_1")
    assert pug.close(timeout: 5)
    assert_equal %i[batch_create batch_identify], rpc.recorded.map(&:first).sort
  end

  def test_warns_about_bad_batch_settings_once_for_both_queues
    client(batch: { max_size: 5000, max_wait: -1, extra: 1 })
    assert_equal 3, logs.warnings.size, logs.warnings.inspect
  end

  def test_flush_and_close_from_on_error_do_not_wait_on_the_other_queue
    gate = Queue.new
    results = Queue.new
    pug = client(on_error: ->(_, _) { results << [pug.flush, pug.close] })
    stub_rpc(pug) do |name, _|
      next gate.pop && BatchCreateResponse.new if name == :batch_create

      raise Pug::Error.new("bad", code: :invalid_argument)
    end
    pug.track("u", "my.custom")
    pug.identify("user_1")
    pug.flush(timeout: 0)
    assert_equal [false, false], results.pop(timeout: 5)
    gate << :go
  end

  def test_flush_from_on_error_on_the_closing_thread_does_not_wait
    gate = Queue.new
    flushed = Queue.new
    pug = client(on_error: ->(_, _) { flushed << pug.flush })
    stub_rpc(pug) { gate.pop }
    pug.track("u", "my.custom")
    pug.identify("user_1")
    closer = Thread.new { pug.close(timeout: 0.2) }
    assert closer.join(5), "close overran its timeout"
    refute closer.value
    assert_equal [false, true], Array.new(flushed.size) { flushed.pop }
  ensure
    2.times { gate << :go }
  end

  def test_concurrent_closes_leave_both_queues_to_the_first
    failures = Queue.new
    pug = client(on_error: ->(error, lost) { failures << [error, lost] })
    gate = Queue.new
    rpc = stub_rpc(pug) { |name, _| name == :batch_create ? BatchCreateResponse.new : gate.pop }
    pug.track("u", "my.custom")
    pug.identify("user_1")
    identify_queue = pug.instance_variable_get(:@identify_queue)
    start_close = identify_queue.method(:start_close)
    paused = Queue.new
    resume = Queue.new
    identify_queue.define_singleton_method(:start_close) do
      if Thread.current.name == "first"
        paused << true
        resume.pop
      end
      start_close.call
    end
    first = Thread.new do
      Thread.current.name = "first"
      pug.close(timeout: 5)
    end
    paused.pop
    second = Thread.new { pug.close(timeout: 0.05) }
    wait_until { second.status == "sleep" }
    resume << true
    refute second.value
    gate << :go
    assert first.value
    assert_empty Array.new(failures.size) { failures.pop }
    assert_equal %i[batch_create batch_identify], rpc.recorded.map(&:first).sort
  end

  def test_close_from_on_error_during_a_close_leaves_the_drain_to_it
    calls = Queue.new
    pug = client(on_error: ->(_, _) { calls << pug.close })
    rpc = stub_rpc(pug) do |name, _|
      raise Pug::Error.new("down", code: :unavailable) if name == :batch_create
    end
    pug.track("u", "my.custom")
    pug.identify("user_1")
    closer = Thread.new { pug.close }
    assert closer.join(5), "close deadlocked"
    assert_equal [false], Array.new(calls.size) { calls.pop }
    assert_equal %i[batch_create batch_identify], rpc.recorded.map(&:first).sort
  end

  def test_identify_warns_and_drops_after_close
    pug = client
    pug.close(timeout: 5)
    assert_nil pug.identify("user_1")
    assert_match(/identify\(\) called after close\(\)/, logs.warnings.last)
  end
end

class ReadsTest < Minitest::Test
  include Pug::TestSupport

  ProfilesV1 = Pug::Proto::Shared::Profiles::V1

  class StreamingRPC < FakeRPC
    def initialize(pages: [], error: nil)
      super()
      @pages = pages
      @error = error
    end

    def stream(name, request, timeout: nil, &)
      @calls << [name, request, timeout]
      @pages.each(&)
      raise @error if @error
    end
  end

  def test_reads_pass_through_to_the_rpc
    rpc = FakeRPC.new do |name, _|
      name == :profiles_get ? ProfilesV1::GetResponse.new(profile: { id: "p1" }) : :response
    end
    assert_equal "p1", Pug::Profiles.new(rpc).get("p1", include_bots: true).id
    assert_equal :response, Pug::Activity.new(rpc).profile_sessions(distinct_id: "p1", include_bots: true)
    assert_equal :response, Pug::Insights.new(rpc).filter_schema
    calls = rpc.recorded
    assert_equal [:profiles_get, { id: "p1", include_bots: true }], calls[0]
    assert_equal [:activity_profile_sessions, { distinct_id: "p1", include_bots: true }], calls[1]
    assert_equal [:insights_filter_schema, nil], calls[2]
  end

  def test_get_leaves_include_bots_unset_by_default
    rpc = FakeRPC.new { ProfilesV1::GetByExternalIdResponse.new }
    assert_nil Pug::Profiles.new(rpc).get_by_external_id("user_42")
    assert_equal [:profiles_get_by_external_id, { external_id: "user_42" }], rpc.recorded.first
  end

  def test_reads_normalize_errors
    rpc = FakeRPC.new { raise TypeError, "bad request" }
    error = assert_raises(Pug::Error) { Pug::Insights.new(rpc).query({}) }
    assert_equal "bad request", error.message
    assert_kind_of TypeError, error.cause
  end

  def test_reads_build_requests_from_hashes_or_messages
    request = Pug::RPC.request(:profiles_list, filter_groups: [{ filters: [] }])
    assert_kind_of ProfilesV1::ListRequest, request
    message = ProfilesV1::ListRequest.new
    assert_same message, Pug::RPC.request(:profiles_list, message)
    assert_raises(ArgumentError) { Pug::RPC.request(:profiles_list, "nope") }
  end

  def test_list_iterates_every_page
    pages = [ProfilesV1::ListResponse.new(profiles: [{ id: "a" }, { id: "b" }]),
             ProfilesV1::ListResponse.new(profiles: [{ id: "c" }])]
    profiles = Pug::Profiles.new(StreamingRPC.new(pages: pages))
    assert_equal %w[a b c], profiles.list.map(&:id)
    assert_equal %w[a], profiles.list.first(1).map(&:id)
  end

  def test_list_surfaces_stream_errors_as_pug_errors
    error = Pug::Error.new("denied", code: :permission_denied)
    raised = assert_raises(Pug::Error) { Pug::Profiles.new(StreamingRPC.new(error: error)).list.to_a }
    assert_equal :permission_denied, raised.code
    raised = assert_raises(Pug::Error) { Pug::Profiles.new(StreamingRPC.new(error: RuntimeError.new("bug"))).list.next }
    assert_nil raised.code
  end

  def test_list_takes_a_braceless_request_and_a_timeout
    rpc = StreamingRPC.new
    profiles = Pug::Profiles.new(rpc)
    profiles.list(include_bots: true).to_a
    profiles.list({ include_bots: true }, timeout: 60).to_a
    profiles.list(timeout: 0.5) { nil }
    assert_equal [[:profiles_list, { include_bots: true }, nil], [:profiles_list, { include_bots: true }, 60],
                  [:profiles_list, {}, 0.5]], rpc.recorded
  end

  def test_list_refuses_a_bad_timeout_or_a_request_given_twice
    profiles = Pug::Profiles.new(StreamingRPC.new)
    assert_raises(Pug::Error) { profiles.list(timeout: "60").to_a }
    assert_raises(Pug::Error) { profiles.list({ include_bots: true }, page_token: "t").to_a }
  end
end
