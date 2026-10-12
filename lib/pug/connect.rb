# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"
require_relative "errors"
require_relative "version"

module Pug
  # A Connect protocol client (https://connectrpc.com/docs/protocol) for the two call shapes the
  # SDK uses: unary, and server streaming for profiles.list. Binary protobuf over HTTP/1.1, like
  # sdk-node. Every failure surfaces as a Pug::Error carrying a Connect code.
  class Connect
    USER_AGENT = "pug-ruby/#{VERSION}".freeze
    UNARY_CONTENT_TYPE = "application/proto"
    STREAM_CONTENT_TYPE = "application/connect+proto"
    CONTENT_TYPE = %r{\Aapplication/(connect\+)?(?:(json)(?:; ?charset=utf-?8)?|(proto))\z}i
    END_STREAM = 0b10
    COMPRESSED = 0b01

    # Carries an exception raised by the caller's block past the transport's rescue clauses, which
    # would otherwise mistake, say, the caller's IOError for a network failure. Whoever passed
    # the block re-raises the original.
    class Passthrough < Exception # rubocop:disable Lint/InheritException
      attr_reader :error

      def initialize(error)
        @error = error
        super(error.message)
      end
    end

    CODES = %i[canceled unknown invalid_argument deadline_exceeded not_found already_exists permission_denied
               resource_exhausted failed_precondition aborted out_of_range unimplemented internal unavailable
               data_loss unauthenticated].to_h { |code| [code.to_s, code] }.freeze

    # https://connectrpc.com/docs/protocol/#http-to-error-code: 400 is internal and 404
    # unimplemented on purpose.
    HTTP_CODES = { 400 => :internal, 401 => :unauthenticated, 403 => :permission_denied, 404 => :unimplemented,
                   429 => :unavailable, 502 => :unavailable, 503 => :unavailable, 504 => :unavailable }.freeze

    def initialize(endpoint, api_key, timeout:)
      @uri = URI(endpoint)
      @base_path = @uri.path.to_s.chomp("/")
      @api_key = api_key
      @timeout = timeout
      @pool = Pool.new(@uri)
    end

    def unary(procedure, request, response_class, timeout: @timeout)
      response = call(procedure, request.class.encode(request), UNARY_CONTENT_TYPE, timeout) do |http, post|
        http.request(post)
      end
      raise unary_error(response) unless response.code == "200"

      check_content_type(response, stream: false)
      decode(response_class, response.body.to_s)
    end

    def server_stream(procedure, request, response_class, timeout: @timeout)
      body = envelope(0, request.class.encode(request))
      deadline = monotonic + timeout
      call(procedure, body, STREAM_CONTENT_TYPE, timeout) do |http, post|
        http.request(post) do |response|
          raise Error.new("HTTP #{response.code}", code: http_code(response.code.to_i)) unless response.code == "200"

          check_content_type(response, stream: true)
          check_stream_encoding(response)
          read_stream(http, response, response_class, deadline) do |message|
            yield message
          rescue Exception => e # rubocop:disable Lint/RescueException
            raise Passthrough, e
          end
        end
      end
      nil
    end

    def close
      @pool.close
    end

    private

    def call(procedure, body, content_type, timeout)
      post = Net::HTTP::Post.new("#{@base_path}/#{procedure}")
      post["Content-Type"] = content_type
      post["Connect-Protocol-Version"] = "1"
      post["Connect-Timeout-Ms"] = (timeout * 1000).ceil.to_s
      post["User-Agent"] = USER_AGENT
      post["X-Api-Key"] = @api_key
      post.body = body
      @pool.with(timeout) { |http| yield http, post }
    rescue Error
      raise
    rescue Timeout::Error => e
      raise Error.new("request timed out: #{e.message}", code: :deadline_exceeded)
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise Error.new("#{e.class}: #{e.message}", code: :unavailable)
    rescue Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error => e
      raise Error.new("#{e.class}: #{e.message}", code: :internal)
    end

    def read_stream(http, response, response_class, deadline)
      buffer = "".b
      ended = false
      response.read_body do |chunk|
        buffer << chunk
        while buffer.bytesize >= 5
          flags, length = buffer.unpack("CN")
          break if buffer.bytesize < 5 + length

          data = buffer.byteslice(5, length)
          buffer = buffer.byteslice((5 + length)..)
          if ended
            raise Error.new("protocol error: received extra message after EndStreamResponse", code: :invalid_argument)
          end
          if flags.anybits?(COMPRESSED)
            raise Error.new("protocol error: received a compressed message it did not ask for", code: :internal)
          end

          if flags.anybits?(END_STREAM)
            end_stream(data)
            ended = true
          else
            yield decode(response_class, data)
          end
        end
        next if ended

        remaining = deadline - monotonic
        raise Error.new("request timed out", code: :deadline_exceeded) unless remaining.positive?

        http.read_timeout = remaining
      end
      raise Error.new("protocol error: premature end of stream", code: :data_loss) unless buffer.empty?
      raise Error.new("protocol error: missing EndStreamResponse", code: :invalid_argument) unless ended
    end

    def end_stream(data)
      parsed = parse_json(data)
      raise Error.new("invalid end stream", code: :unknown) unless parsed.is_a?(Hash)
      return if parsed["error"].nil?

      raise wire_error(parsed["error"], Error.new("invalid end stream", code: :unknown))
    end

    def unary_error(response)
      fallback = Error.new("HTTP #{response.code}", code: http_code(response.code.to_i))
      match = CONTENT_TYPE.match(response["Content-Type"].to_s)
      return fallback unless match && match[2]

      wire_error(parse_json(response.body.to_s), fallback)
    end

    def wire_error(json, fallback)
      return fallback unless json.is_a?(Hash)

      message = json["message"]
      return fallback unless message.nil? || message.is_a?(String)

      Error.new(message.to_s, code: CODES.fetch(json["code"].to_s, fallback.code))
    end

    def parse_json(data)
      JSON.parse(data.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError, EncodingError
      nil
    end

    def check_content_type(response, stream:)
      type = response["Content-Type"].to_s
      match = CONTENT_TYPE.match(type)
      return if match && match[3] && !match[1] == !stream

      raise Error.new("unsupported content type #{type}", code: match ? :internal : :unknown)
    end

    def check_stream_encoding(response)
      encoding = response["Connect-Content-Encoding"]
      return if encoding.nil? || encoding.casecmp?("identity")

      raise Error.new("unsupported response encoding \"#{encoding}\"", code: :internal)
    end

    def decode(response_class, data)
      response_class.decode(data)
    rescue ::Google::Protobuf::ParseError => e
      raise Error.new("failed to decode #{response_class.descriptor.name}: #{e.message}", code: :internal)
    end

    def envelope(flags, data)
      [flags, data.bytesize].pack("CN") + data
    end

    def http_code(status)
      HTTP_CODES.fetch(status, :unknown)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Keep-alive connections, one per concurrent caller. Net::HTTP sessions aren't thread-safe,
    # so each is checked out by one thread at a time.
    class Pool
      MAX_IDLE = 4

      def initialize(uri)
        @uri = uri
        @idle = []
        @lock = Mutex.new
        @pid = Process.pid
      end

      def with(timeout)
        http = checkout
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout
        http.start unless http.started?
        result = yield http
        checkin(http)
        http = nil
        result
      ensure
        discard(http) if http
      end

      def close
        connections = @lock.synchronize { @idle.slice!(0..) }
        connections.each { |http| discard(http) }
      end

      private

      def checkout
        @lock.synchronize do
          forked
          @idle.pop
        end || Net::HTTP.new(@uri.hostname, @uri.port).tap { |http| http.use_ssl = @uri.scheme == "https" }
      end

      def checkin(http)
        keep = @lock.synchronize do
          forked
          @idle.size < MAX_IDLE && @idle.push(http)
        end
        discard(http) unless keep
      end

      # A forked child must not reuse, or even close, its parent's sockets: a TLS close_notify
      # would be written into the parent's live connection. They are dropped instead.
      def forked
        return if @pid == Process.pid

        @pid = Process.pid
        @idle = []
      end

      def discard(http)
        http.finish if http.started?
      rescue StandardError
        nil
      end
    end
  end
end
