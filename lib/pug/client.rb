# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"
require_relative "batcher"
require_relative "connect"
require_relative "errors"
require_relative "event_builder"
require_relative "log"
require_relative "reads"
require_relative "rpc"
require_relative "validator"

module Pug
  # What one failure lost, as on_error receives it. Either list may be empty.
  Undelivered = Data.define(:events, :identifies) do
    def initialize(events: [], identifies: []) = super
  end

  class Client
    DEFAULT_ENDPOINT = "https://api.pugs.dev"
    DEFAULT_TIMEOUT = 10
    RESERVED_PREFIX = "cookieless-"
    TRACK_OPTIONS = %w[timestamp session_id location].freeze
    IDENTIFY_OPTIONS = %w[anonymous_id device_id].freeze

    # Each identify is one NATS message, capped at 1 MiB; the margin covers envelope and headers.
    MAX_IDENTIFY_BYTES = 900 * 1024

    class NotSerializable < StandardError; end
    OMITTED = Object.new.freeze
    private_constant :NotSerializable, :OMITTED

    attr_reader :profiles, :activity, :insights

    def initialize(api_key:, endpoint: nil, batch: nil, on_error: nil, logger: nil, timeout: nil)
      unless api_key.is_a?(String) && !api_key.empty?
        raise ArgumentError, "[Pug SDK] api_key is required and must be a non-empty String"
      end
      # A trailing newline from a secrets file would fail every request.
      unless api_key.ascii_only? && api_key.match?(/\A[!-~]+\z/)
        raise ArgumentError, "[Pug SDK] api_key must be printable ASCII without spaces (check for a trailing newline)"
      end
      unless api_key.start_with?("prv_")
        raise ArgumentError, "[Pug SDK] api_key must be a private key (prv_…) for the server SDK"
      end
      raise ArgumentError, "[Pug SDK] on_error must be callable" unless on_error.nil? || on_error.respond_to?(:call)
      unless on_error.nil? || takes_two?(on_error)
        raise ArgumentError, "[Pug SDK] on_error must take two arguments, (error, undelivered)"
      end
      raise ArgumentError, "[Pug SDK] batch must be a Hash" unless batch.nil? || batch.is_a?(Hash)
      unless logger.nil? || %i[warn error].all? { |level| logger.respond_to?(level) }
        raise ArgumentError, "[Pug SDK] logger must respond to warn and error, like a Logger (wrap an IO in Logger.new)"
      end

      endpoint = endpoint.to_s
      endpoint = DEFAULT_ENDPOINT if endpoint.empty?
      unless http_url?(endpoint)
        raise ArgumentError, "[Pug SDK] endpoint must be an absolute http(s) URL, got #{endpoint.inspect}"
      end

      @log = Log.new(logger)
      @connect = Connect.new(endpoint, api_key, timeout: resolve_timeout(timeout))
      @rpc = RPC.new(@connect)
      @events = EventBuilder.new(@log)
      # Resolved once, so a bad setting warns once rather than once per queue.
      batch = Batcher.resolve(batch, @log)
      on_events = on_error && ->(error, events) { on_error.call(error, Undelivered.new(events:)) }
      on_identifies = on_error && ->(error, identifies) { on_error.call(error, Undelivered.new(identifies:)) }
      @event_queue = Batcher.new(method(:send_events), batch, on_events, @log)
      @identify_queue = Batcher.new(method(:send_identifies), batch, on_identifies, @log, noun: Batcher::IDENTIFIES)
      @close_lock = Mutex.new
      @unbatched = false
      @session_id = SecureRandom.uuid_v7
      @closed = false
      @profiles = Profiles.new(@rpc)
      @activity = Activity.new(@rpc)
      @insights = Insights.new(@rpc)
    end

    def track(distinct_id, kind, properties = OMITTED, options = nil, **keywords)
      return @log.warn("track() called after close().") if @closed

      distinct_id = id_string(distinct_id, "track", "distinct_id")
      return if distinct_id.nil?
      # The server rejects a whole batch over one such id, taking other users' events with it.
      if distinct_id.start_with?(RESERVED_PREFIX)
        return @log.error("track() distinct_id must not start with the reserved '#{RESERVED_PREFIX}' prefix.")
      end
      return @log.error("track() requires a non-empty event kind String.") unless kind?(kind)

      properties, options = split_options(properties, options, keywords, TRACK_OPTIONS, "track")
      return @log.error("track() properties must be a Hash.") unless properties.nil? || properties.is_a?(Hash)

      event, bytesize = @events.build(kind, session(options["session_id"]), distinct_id, properties,
                                      timestamp: options["timestamp"], location: options["location"])
      @event_queue.enqueue(event, bytesize) if event
      nil
    rescue StandardError => e
      @log.error("Unexpected error in track(#{kind.inspect}): #{Log.describe(e)}")
    end

    def identify(external_id, traits = OMITTED, options = nil, **keywords)
      return @log.warn("identify() called after close().") if @closed

      external_id = id_string(external_id, "identify", "external_id")
      return if external_id.nil?

      traits, options = split_options(traits, options, keywords, IDENTIFY_OPTIONS, "identify")
      return @log.error("identify() traits must be a Hash.") unless traits.nil? || traits.is_a?(Hash)

      request = identify_request(external_id, traits, options)
      return if request.nil?

      violations = Validator.validate(request)
      return @log.error("Invalid identify request: #{Validator.format(violations)}") unless violations.empty?

      bytesize = RPC::SdkProfilesV1::IdentifyRequest.encode(request).bytesize
      if bytesize > MAX_IDENTIFY_BYTES
        return @log.error("Identify #{external_id.inspect} dropped: #{bytesize} bytes is too large to send " \
                          "(limit #{MAX_IDENTIFY_BYTES})")
      end

      @identify_queue.enqueue(request, bytesize)
      nil
    rescue NotSerializable => e
      @log.error("identify() traits must be JSON-serializable: #{e.message}")
    rescue StandardError => e
      @log.error("Unexpected error in identify(#{external_id.inspect}): #{Log.describe(e)}")
    end

    def flush(timeout: nil)
      deadline = wait_deadline(timeout, "flush")
      waiters = queues.map(&:request_flush)
      waiters.map { |waiter| !waiter.pop(timeout: remaining(deadline)).nil? }.all?
    end

    # Concurrent closes can't each own one queue: the second waits on the first's timeout.
    def close(timeout: nil)
      @closed = true
      deadline = wait_deadline(timeout, "close")
      firsts = @close_lock.synchronize { queues.map(&:start_close) }
      queues.zip(firsts).map { |queue, first| queue.finish_close(first, deadline) }.all?
    ensure
      @connect.close
    end

    # The default would print the API key and everything queued.
    def inspect = "#<#{self.class.name}>"

    private

    def send_events(events)
      response = @rpc.unary(:batch_create, RPC::EventsV1::BatchCreateRequest.new(events: events))
      # A refused event isn't an RPC error, so this is the only sign it was lost.
      return unless response.dropped.positive?

      @log.warn("Server dropped #{response.dropped} of #{events.size} event(s): #{response.dropped_by_reason.to_h}")
    end

    # Falls back to one Identify per item on servers older than BatchIdentify.
    def send_identifies(identifies)
      return if !@unbatched && batch_identify(identifies)

      identifies.each_with_index do |identify, sent|
        @rpc.unary(:identify, identify)
      rescue StandardError => e
        raise Batcher::PartialSendError.new(sent), cause: e
      end
    end

    def batch_identify(identifies)
      @rpc.unary(:batch_identify, RPC::SdkProfilesV1::BatchIdentifyRequest.new(identifies: identifies))
      true
    rescue Error => e
      # A server without the route answers 404, which the batcher would treat as permanent.
      raise unless e.code == :unimplemented

      @log.warn("Server has no BatchIdentify; sending identifies one at a time.")
      @unbatched = true
      false
    end

    # A bad session id costs the event its own session, not the event.
    def session(session_id)
      return @session_id if session_id.nil? || session_id == ""
      return session_id if session_id.is_a?(String) && session_id.ascii_only? && Validator::UUID.match?(session_id)

      @log.warn("Ignoring invalid track session_id #{session_id.inspect}; expected a UUID String. " \
                "Using the client's session.")
      @session_id
    end

    def identify_request(external_id, traits, options)
      ids = IDENTIFY_OPTIONS.filter_map do |name|
        value = options[name]
        [name.to_sym, id_string(value, "identify", name, integers: false)] unless value.nil? || value == ""
      end.to_h
      return if ids.value?(nil)

      request = { external_id: external_id, **ids }
      request[:traits] = to_struct(traits) unless traits.nil?
      RPC::SdkProfilesV1::IdentifyRequest.new(request)
    end

    def resolve_timeout(timeout)
      return DEFAULT_TIMEOUT if timeout.nil?
      return timeout if Connect.timeout?(timeout)

      @log.warn("timeout must be a positive number of seconds; using the default #{DEFAULT_TIMEOUT}.")
      DEFAULT_TIMEOUT
    end

    def queues = [@event_queue, @identify_queue]

    # From on_error, waiting could deadlock on the other queue's sender, itself in on_error.
    def wait_deadline(timeout, method)
      timeout = wait_timeout(timeout, method)
      timeout = 0 if queues.any? { |queue| queue.sender? || queue.closing? }
      timeout && (monotonic + timeout)
    end

    # A timeout that isn't a number waits without one, as close must still drain; one already
    # past doesn't wait at all.
    def wait_timeout(timeout, method)
      return if timeout.nil? || timeout == Float::INFINITY
      return [timeout.to_f, 0].max if timeout.is_a?(Numeric) && timeout.real? && timeout.finite?

      @log.warn("#{method}() timeout must be a number of seconds; waiting without one.")
      nil
    end

    def remaining(deadline)
      deadline && [deadline - monotonic, 0].max
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Lambdas and methods check their arity, so one taking fewer arguments would fail every call.
    def takes_two?(callable)
      callable = callable.method(:call) unless callable.is_a?(Proc) || callable.is_a?(Method)
      return true if callable.is_a?(Proc) && !callable.lambda?

      arity = callable.arity
      arity.negative? ? -arity - 1 <= 2 : arity == 2
    end

    def http_url?(endpoint)
      uri = URI.parse(endpoint)
      uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    # An Integer passes as an id too, since a Rails record's id is one. Unlike property values,
    # ids aren't repaired: a mangled id would be a different person.
    def id_string(value, method, name, integers: true)
      value = value.to_s if integers && value.is_a?(Integer)
      unless value.is_a?(String) && !value.empty?
        return @log.error("#{method}() requires a non-empty #{name} String#{" or Integer" if integers}.")
      end

      utf8 = if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(value.encoding)
               value.dup.force_encoding(Encoding::UTF_8)
             else
               value.encode(Encoding::UTF_8)
             end
      return utf8 if utf8.valid_encoding?

      @log.error("#{method}() #{name} must be valid UTF-8.")
    rescue EncodingError
      @log.error("#{method}() #{name} must be valid UTF-8.")
    end

    def kind?(kind)
      (kind.is_a?(String) || kind.is_a?(Symbol)) && !kind.empty?
    end

    # Braceless keywords arrive as one Hash, so track(id, kind, plan: "pro") and
    # track(id, kind, timestamp: t) look alike. A keyword named after an option sets that option;
    # any other is data, properties or traits, unless the data came first in an argument of its own.
    def split_options(data, options, keywords, known, method)
      named = keywords
      if data.equal?(OMITTED)
        named, data = keywords.partition { |key, _| known.include?(key.to_s) }.map(&:to_h)
        data = nil if data.empty?
      end
      [data, options_hash(options, known, method).merge(options_hash(named, known, method))]
    end

    def options_hash(options, known, method)
      return {} if options.nil?

      unless options.is_a?(Hash)
        @log.warn("Ignoring #{method}() options: expected a Hash, got #{options.class}")
        return {}
      end
      options.each_with_object({}) do |(key, value), out|
        if known.include?(key.to_s)
          out[key.to_s] = value
        else
          @log.warn("Ignoring unknown #{method}() option #{key.inspect}")
        end
      end
    end

    # A Struct's numbers are doubles, so an integer past 2^53 would arrive changed.
    def to_struct(traits)
      ready = EventBuilder.json_ready(camel_case_keys(traits), max_integer: EventBuilder::MAX_SAFE_FLOAT)
      ::Google::Protobuf::Struct.from_hash(JSON.parse(JSON.generate(finite_traits(ready))))
    rescue StandardError => e
      raise NotSerializable, e.message
    end

    # JSON has no NaN or Infinity, so a trait holding one costs only itself.
    def finite_traits(traits)
      traits.reject do |key, value|
        next false if finite_json?(value)

        @log.warn("identify() trait #{key.inspect} is not representable (NaN or Infinity), skipping")
        true
      end
    end

    def finite_json?(value)
      case value
      when Float then value.finite?
      when Hash then value.each_value.all? { |item| finite_json?(item) }
      when Array then value.all? { |item| finite_json?(item) }
      else true
      end
    end

    # Only the top level, as for properties: a nested Hash is as likely data keyed by ids.
    def camel_case_keys(traits)
      given = {}
      traits.each_with_object({}) do |(key, value), out|
        name = key.to_s
        name = EventBuilder.camel_case(name.encoding.ascii_compatible? ? name : name.encode(Encoding::UTF_8))
        if given.key?(name)
          @log.warn("identify() traits #{given[name].inspect} and #{key.inspect} both go out as #{name.inspect}; " \
                    "sending the last")
        end
        given[name] = key
        out[name] = value
      end
    end
  end
end
