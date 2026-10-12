# frozen_string_literal: true

require_relative "test_helper"
require "date"

class ClientTest < Minitest::Test
  include Pug::TestSupport

  BatchCreateResponse = Pug::Proto::Sdk::Events::V1::BatchCreateResponse

  def teardown
    @client&.close(timeout: 5)
  end

  # endpoint is never dialed: these tests stub the RPC layer or stop before any send.
  def client(**)
    @client = new_client(**)
  end

  def stub_rpc(client, &handler)
    FakeRPC.new(&handler).tap { |rpc| client.instance_variable_set(:@rpc, rpc) }
  end

  def sent_events(client, rpc)
    client.flush(timeout: 5)
    rpc.recorded.flat_map { |name, request| name == :batch_create ? request.events.to_a : [] }
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

  def test_track_session_id_option
    pug = client
    rpc = stub_rpc(pug) { BatchCreateResponse.new }
    pug.track("u", "my.custom", nil, session_id: "")
    pug.track("u", "my.custom", nil, session_id: 7)
    pug.track("u", "my.custom", nil, session_id: "nope")
    events = sent_events(pug, rpc)
    assert_equal 1, events.size
    assert_equal pug.instance_variable_get(:@session_id), events.first.session_id
    assert_match(/session_id must be a String/, logs.errors[0])
    assert_match(/session_id: value must be a valid UUID/, logs.errors[1])
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
    @client = Pug::Client.new(api_key: "prv_test", endpoint: "http://localhost:1", logger: logger)
    assert_nil @client.track("", "my.custom")
  end

  def test_on_error_receives_undeliverable_events
    failures = Queue.new
    pug = client(on_error: ->(error, events) { failures << [error, events] })
    stub_rpc(pug) { raise Pug::Error.new("denied", code: :permission_denied) }
    pug.track("u", "my.custom")
    pug.flush(timeout: 5)
    error, events = failures.pop(timeout: 5)
    assert_equal :permission_denied, error.code
    assert_equal ["my.custom"], events.map(&:kind)
  end

  def test_logs_events_the_server_dropped
    pug = client
    stub_rpc(pug) { BatchCreateResponse.new(accepted: 1, dropped: 2, dropped_by_reason: { "day_out_of_range" => 2 }) }
    3.times { pug.track("u", "my.custom") }
    pug.flush(timeout: 5)
    assert_equal ['[Pug SDK] Server dropped 2 of 3 event(s): {"day_out_of_range" => 2}'], logs.warnings
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
    assert_empty rpc.recorded
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
    client.identify("user_1", score: Float::NAN)
    assert_match(/traits must be JSON-serializable/, logs.errors.last)
  end

  def test_identify_sends_the_request
    pug = client
    rpc = stub_rpc(pug)
    pug.identify(7, { plan: "pro", seats: 3, tags: [:a], nested: { ok: true } },
                 anonymous_id: "anon-1", device_id: "d1")
    name, request = rpc.recorded.first
    assert_equal :identify, name
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
    _, request = rpc.recorded.first
    refute request.has_traits?
    refute request.has_anonymous_id?
    refute request.has_device_id?
  end

  def test_identify_logs_failures
    pug = client
    stub_rpc(pug) { raise Pug::Error.new("down", code: :unavailable) }
    assert_nil pug.identify("user_1")
    assert_equal '[Pug SDK] Failed to identify "user_1": Pug::Error: unavailable: down', logs.errors.last
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

    def stream(_name, _request, &)
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
end
