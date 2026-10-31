# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "zlib"

# Drives the SDK against an in-process HTTP server: the wire format, the API key header,
# streaming list, error mapping and timeouts.
class ConnectTest < Minitest::Test
  include Pug::TestSupport

  EventsV1 = Pug::Proto::Sdk::Events::V1
  ProfilesV1 = Pug::Proto::Shared::Profiles::V1
  ActivityV1 = Pug::Proto::Shared::Activity::V1
  SdkProfilesV1 = Pug::Proto::Sdk::Profiles::V1
  PROTO = { "Content-Type" => "application/proto" }.freeze
  STREAM = { "Content-Type" => "application/connect+proto" }.freeze
  JSON_TYPE = { "Content-Type" => "application/json" }.freeze

  def teardown
    @client&.close(timeout: 5)
    @server&.close
  end

  def serve(&)
    @server = FakeServer.new(&)
  end

  def client(path: "", **)
    @client = Pug::Client.new(api_key: "prv_test", endpoint: "#{@server.url}#{path}", logger: logs, **)
  end

  def ok(message)
    [200, PROTO, message.class.encode(message)]
  end

  def error_json(status, code, message)
    [status, JSON_TYPE, JSON.generate(code: code, message: message)]
  end

  def test_track_delivers_over_the_wire
    serve { ok(EventsV1::BatchCreateResponse.new(accepted: 1)) }
    pug = client
    pug.track("user_42", "purchase", { amount: 9.99, currency: "USD" }, location: { country: "DE" })
    assert pug.flush(timeout: 5)
    request = @server.next_request
    assert_equal "POST", request.verb
    assert_equal "/sdk.events.v1.EventsService/BatchCreate", request.path
    assert_equal "application/proto", request.headers["content-type"]
    assert_equal "1", request.headers["connect-protocol-version"]
    assert_equal "prv_test", request.headers["x-api-key"]
    assert_equal "10000", request.headers["connect-timeout-ms"]
    assert_equal "pug-ruby/#{Pug::VERSION}", request.headers["user-agent"]
    event = EventsV1::BatchCreateRequest.decode(request.body).events.first
    assert_equal %w[purchase user_42], [event.kind, event.distinct_id]
    assert_equal 9.99, event.custom_properties["amount"].double_value
    assert_equal "DE", event.auto_properties["$country"].string_value
  end

  def test_keeps_an_endpoint_path_prefix
    serve { ok(EventsV1::BatchCreateResponse.new) }
    pug = client(path: "/pug/")
    pug.track("u", "my.custom")
    pug.flush(timeout: 5)
    assert_equal "/pug/sdk.events.v1.EventsService/BatchCreate", @server.next_request.path
  end

  def test_identify
    serve { ok(SdkProfilesV1::BatchIdentifyResponse.new(accepted: 2)) }
    pug = client
    pug.identify("user_42", { plan: "pro" }, anonymous_id: "anon-7")
    pug.identify("user_43")
    assert pug.close(timeout: 5)
    request = @server.next_request
    assert_equal "/sdk.profiles.v1.ProfilesSDKService/BatchIdentify", request.path
    assert_equal "prv_test", request.headers["x-api-key"]
    first, second = SdkProfilesV1::BatchIdentifyRequest.decode(request.body).identifies
    assert_equal ["user_42", "anon-7", { "plan" => "pro" }], [first.external_id, first.anonymous_id, first.traits.to_h]
    assert_equal "user_43", second.external_id
    assert_empty @server.requests
    assert_empty logs.errors
  end

  def test_identify_on_a_server_without_batch_identify
    serve do |request|
      next [200, PROTO, ""] unless request.path.end_with?("/BatchIdentify")

      [404, { "Content-Type" => "text/plain" }, "404 page not found"]
    end
    pug = client
    pug.identify("user_1")
    pug.identify("user_2")
    pug.flush(timeout: 5)
    pug.identify("user_3")
    assert pug.close(timeout: 5)
    requests = @server.requests
    assert_equal(%w[BatchIdentify Identify Identify Identify], requests.map { |request| request.path.split("/").last })
    assert_equal(%w[user_1 user_2 user_3],
                 requests.drop(1).map { |request| SdkProfilesV1::IdentifyRequest.decode(request.body).external_id })
    assert_equal ["[Pug SDK] Server has no BatchIdentify; sending identifies one at a time."], logs.warnings
    assert_empty logs.errors
  end

  def test_reads_hit_their_procedures
    serve do |request|
      case request.path
      when "/shared.profiles.v1.ProfilesService/Get" then ok(ProfilesV1::GetResponse.new(profile: { id: "p1" }))
      else [200, PROTO, ""]
      end
    end
    pug = client
    assert_equal "p1", pug.profiles.get("p1", include_bots: true).id
    pug.profiles.get_by_external_id("user_42")
    pug.profiles.delete("p1")
    pug.activity.feed(distinct_id: "p1")
    pug.activity.event_explorer({})
    pug.activity.heatmap(distinct_id: "p1")
    pug.activity.profile_sessions(distinct_id: "p1")
    pug.activity.profile_stats(distinct_id: "p1")
    pug.activity.filter_schema
    pug.activity.property_values({})
    pug.insights.query({})
    pug.insights.segment_users({})
    pug.insights.filter_schema(event_kind: "purchase")
    pug.insights.property_values({})
    requests = @server.requests
    assert_equal %w[
      /shared.profiles.v1.ProfilesService/Get /shared.profiles.v1.ProfilesService/GetByExternalId
      /shared.profiles.v1.ProfilesService/Delete /shared.activity.v1.ActivityService/GetActivityFeed
      /shared.activity.v1.ActivityService/GetEventExplorer /shared.activity.v1.ActivityService/GetActivityHeatmap
      /shared.activity.v1.ActivityService/GetProfileSessions /shared.activity.v1.ActivityService/GetProfileStats
      /shared.activity.v1.ActivityService/GetFilterSchema /shared.activity.v1.ActivityService/GetPropertyValues
      /shared.insights.v1.InsightsService/Query /shared.insights.v1.InsightsService/SegmentUsers
      /shared.insights.v1.InsightsService/GetFilterSchema /shared.insights.v1.InsightsService/GetPropertyValues
    ], requests.map(&:path)
    get = ProfilesV1::GetRequest.decode(requests.first.body)
    assert_equal ["p1", true], [get.id, get.include_bots]
  end

  # Net::HTTP advertises gzip, so a Connect server may compress unary responses.
  def test_reads_a_compressed_response
    serve do
      io = StringIO.new
      gzip = Zlib::GzipWriter.new(io)
      gzip.write(ProfilesV1::GetResponse.encode(ProfilesV1::GetResponse.new(profile: { id: "p1" })))
      gzip.close
      [200, PROTO.merge("Content-Encoding" => "gzip"), io.string]
    end
    assert_equal "p1", client.profiles.get("p1").id
    assert_match(/gzip/, @server.next_request.headers["accept-encoding"])
  end

  def test_keeps_connections_alive
    serve { [200, PROTO, ""] }
    pug = client
    3.times { pug.activity.filter_schema }
    assert_equal 1, @server.instance_variable_get(:@connections).size
  end

  def test_concurrent_reads_never_share_a_connection
    serve do |request|
      sleep 0.02
      id = ProfilesV1::GetRequest.decode(request.body).id
      ok(ProfilesV1::GetResponse.new(profile: { id: id }))
    end
    pug = client
    pug.profiles.get("warm")
    ids = Array.new(8) { |i| "p#{i}" }
    assert_equal ids, ids.map { |id| Thread.new { pug.profiles.get(id).id } }.map(&:value)
  end

  def test_a_forked_child_dials_its_own_connection
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    serve { [200, PROTO, ""] }
    pug = client
    pug.activity.filter_schema
    pid = fork do
      pug.activity.filter_schema
      exit!(0)
    rescue Exception # rubocop:disable Lint/RescueException
      exit!(1)
    end
    assert Process.wait2(pid).last.success?
    pug.activity.filter_schema
    assert_equal 2, @server.instance_variable_get(:@connections).size
  end

  # Over TLS, finishing an inherited connection writes close_notify into the parent's session.
  def test_a_forked_childs_close_leaves_the_parents_connections_alone
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    serve { [200, PROTO, ""] }
    pug = client
    pug.activity.filter_schema
    inherited = pug.instance_variable_get(:@connect).instance_variable_get(:@pool).instance_variable_get(:@idle).first
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      pug.close(timeout: 1)
      writer.puts(inherited.started?)
      exit!(0)
    end
    writer.close
    Process.wait(pid)
    assert_equal "true", reader.read.chomp, "the child finished a connection its parent still uses"
  end

  def test_maps_every_http_status_to_a_connect_code
    table = { 301 => :unimplemented, 400 => :internal, 401 => :unauthenticated, 403 => :permission_denied,
              404 => :unimplemented, 429 => :unavailable, 500 => :unknown, 502 => :unavailable, 503 => :unavailable,
              504 => :unavailable }
    statuses = table.keys
    serve { [statuses.shift, { "Content-Type" => "text/plain" }, "nope"] }
    pug = client
    table.each do |status, code|
      assert_equal code, assert_raises(Pug::Error) { pug.activity.filter_schema }.code, "HTTP #{status}"
    end
  end

  # Without a Connect error body, the status alone would leave a proxy's answer a mystery.
  def test_an_error_without_a_connect_body_says_what_answered
    responses = [[308, { "Location" => "https://pug.example.com/x" }, ""],
                 [413, { "Content-Type" => "text/html" }, "<html>\n  <title>413 Request Entity Too Large</title>"],
                 [502, {}, "x" * 500]]
    serve { responses.shift }
    pug = client
    ["unimplemented: HTTP 308: redirected to https://pug.example.com/x",
     "unknown: HTTP 413: <html> <title>413 Request Entity Too Large</title>",
     "unavailable: HTTP 502: #{"x" * 120}"].each do |message|
      assert_equal message, assert_raises(Pug::Error) { pug.activity.filter_schema }.message
    end
  end

  def test_read_errors_carry_the_connect_code
    responses = [
      error_json(404, "not_found", "no such profile"),
      [503, { "Content-Type" => "text/html" }, "<html>down</html>"],
      [400, {}, ""],
      [500, JSON_TYPE, "{not json"],
      error_json(500, "made_up", "odd"),
      [200, { "Content-Type" => "text/html" }, "<html>"],
      [200, { "Content-Type" => "application/json" }, "{}"],
      [200, PROTO, "\xFF\xFF\xFF"]
    ]
    serve { responses.shift }
    pug = client
    expected = [
      [:not_found, "not_found: no such profile"],
      [:unavailable, "unavailable: HTTP 503: <html>down</html>"],
      [:internal, "internal: HTTP 400"],
      [:unknown, "unknown: HTTP 500: {not json"],
      [:unknown, "unknown: odd"],
      [:unknown, "unknown: unsupported content type text/html"],
      [:internal, "internal: unsupported content type application/json"],
      [:internal, /\Ainternal: failed to decode shared.profiles.v1.GetResponse/]
    ]
    expected.each do |code, message|
      error = assert_raises(Pug::Error) { pug.profiles.get("p1") }
      assert_equal code, error.code
      message.is_a?(Regexp) ? assert_match(message, error.message) : assert_equal(message, error.message)
    end
  end

  def test_an_unreachable_server_is_unavailable
    serve { [200, PROTO, ""] }
    @server.close
    error = assert_raises(Pug::Error) { client.activity.filter_schema }
    assert_equal :unavailable, error.code
  end

  def test_reads_time_out
    serve do
      sleep 1
      [200, PROTO, ""]
    end
    pug = client(timeout: 0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Pug::Error) { pug.activity.filter_schema }
    assert_equal :deadline_exceeded, error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9
    assert_equal "200", @server.next_request.headers["connect-timeout-ms"]
  end

  def stream_response(*pages, end_stream: {})
    body = pages.map { |page| envelope(0, ProfilesV1::ListResponse.encode(page)) }
    body << envelope(2, JSON.generate(end_stream)) if end_stream
    [200, STREAM, body]
  end

  def test_list_paginates_over_the_stream
    serve do
      stream_response(ProfilesV1::ListResponse.new(profiles: [{ id: "a" }, { id: "b" }]),
                      ProfilesV1::ListResponse.new(profiles: [{ id: "c" }]))
    end
    assert_equal %w[a b c], client.profiles.list(include_bots: true).map(&:id)
    request = @server.next_request
    assert_equal "/shared.profiles.v1.ProfilesService/List", request.path
    assert_equal "application/connect+proto", request.headers["content-type"]
    flags, length = request.body.unpack("CN")
    assert_equal 0, flags
    assert ProfilesV1::ListRequest.decode(request.body.byteslice(5, length)).include_bots
  end

  def test_list_reassembles_messages_split_across_chunks
    serve do
      data = stream_response(ProfilesV1::ListResponse.new(profiles: [{ id: "a" }]))[2].join
      [200, STREAM, data.chars.each_slice(3).map(&:join)]
    end
    assert_equal %w[a], client.profiles.list.map(&:id)
  end

  def test_list_surfaces_stream_errors
    serve do
      stream_response(ProfilesV1::ListResponse.new(profiles: [{ id: "a" }]),
                      end_stream: { error: { code: "permission_denied", message: "denied" } })
    end
    seen = []
    error = assert_raises(Pug::Error) { client.profiles.list { |profile| seen << profile.id } }
    assert_equal :permission_denied, error.code
    assert_equal %w[a], seen
  end

  def test_list_protocol_errors
    responses = [
      stream_response(ProfilesV1::ListResponse.new, end_stream: nil),
      [200, STREAM, [envelope(2, "{}"), envelope(2, "{}")]],
      [200, STREAM, [envelope(0, "")[0, 3]]],
      [500, STREAM, []],
      [200, STREAM.merge("Connect-Content-Encoding" => "gzip"), [envelope(2, "{}")]],
      [200, STREAM, [envelope(1, "x"), envelope(2, "{}")]],
      [200, STREAM, [envelope(2, "[]")]]
    ]
    serve { responses.shift }
    pug = client
    %i[invalid_argument invalid_argument data_loss unknown internal internal unknown].each do |code|
      error = assert_raises(Pug::Error) { pug.profiles.list.to_a }
      assert_equal code, error.code, error.message
    end
  end

  def test_list_lets_the_callers_errors_through_and_can_stop_early
    serve do
      stream_response(ProfilesV1::ListResponse.new(profiles: [{ id: "a" }, { id: "b" }]))
    end
    pug = client
    mine = IOError.new("mine")
    assert_same mine, assert_raises(IOError) { pug.profiles.list { raise mine } }
    assert_equal %w[a], pug.profiles.list.first(1).map(&:id)
    assert_equal %w[a b], pug.profiles.list.to_a.map(&:id)
  end

  def test_a_stalled_stream_times_out
    serve do
      page = ProfilesV1::ListResponse.encode(ProfilesV1::ListResponse.new(profiles: [{ id: "a" }]))
      [200, STREAM, [envelope(0, page), -> { sleep 1 }, envelope(2, "{}")]]
    end
    error = assert_raises(Pug::Error) { client(timeout: 0.3).profiles.list.to_a }
    assert_equal :deadline_exceeded, error.code
  end

  # Each page arrives well within the timeout, but the stream as a whole doesn't.
  def test_a_trickling_stream_is_bounded_as_a_whole
    page = ProfilesV1::ListResponse.encode(ProfilesV1::ListResponse.new(profiles: [{ id: "a" }]))
    serve { [200, STREAM, Array.new(10) { [envelope(0, page), -> { sleep 0.1 }] }.flatten(1) << envelope(2, "{}")] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Pug::Error) { client(timeout: 0.3).profiles.list.to_a }
    assert_equal :deadline_exceeded, error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9
  end

  def test_a_list_timeout_covers_the_callers_block
    pages = Array.new(3) { |i| ProfilesV1::ListResponse.new(profiles: [{ id: "p#{i}" }]) }
    serve { stream_response(*pages) }
    pug = client(timeout: 0.2)
    seen = []
    slow = lambda do |profile|
      seen << profile.id
      sleep 0.15
    end
    assert_equal :deadline_exceeded, assert_raises(Pug::Error) { pug.profiles.list(&slow) }.code
    assert_operator seen.size, :<, 3
    seen.clear
    pug.profiles.list(timeout: 5, &slow)
    assert_equal %w[p0 p1 p2], seen
    assert_equal(%w[200 5000], @server.requests.map { |request| request.headers["connect-timeout-ms"] })
  end

  # Most of the way from an HTTP status to a dead letter or a retry.
  def test_dead_letters_or_retries_by_status
    { 401 => true, 403 => true, 404 => true, 308 => true, 400 => false, 429 => false, 500 => false,
      503 => false }.each do |status, permanent|
      serve { [status, {}, ""] }
      failures = Queue.new
      pug = client(on_error: ->(error, _) { failures << error })
      pug.track("u", "my.custom")
      pug.flush(timeout: 5)
      assert_equal permanent, !failures.empty?, "HTTP #{status}"
      teardown
    end
    @client = @server = nil
  end

  def test_a_permanent_failure_dead_letters
    serve { error_json(400, "invalid_argument", "bad event") }
    failures = Queue.new
    pug = client(on_error: ->(error, lost) { failures << [error, lost] })
    pug.track("u", "my.custom")
    pug.flush(timeout: 5)
    error, lost = failures.pop(timeout: 5)
    assert_equal :invalid_argument, error.code
    assert_equal 1, lost.events.size
    assert_match(/Permanent error, 1 event dropped/, logs.errors.last)
  end

  def test_a_transient_failure_retries
    responses = [[503, {}, ""], ok(EventsV1::BatchCreateResponse.new(accepted: 1))]
    serve { responses.shift }
    pug = client
    pug.track("u", "my.custom")
    pug.flush(timeout: 5)
    assert_match(/Transient error sending 1 event, will retry/, logs.warnings.last)
    pug.flush(timeout: 5)
    first, second = @server.requests
    assert_equal first.body, second.body
    assert pug.close(timeout: 5)
  end
end
