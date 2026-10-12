# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "socket"
require "pug"

module Pug
  module TestSupport
    # Stands in for sdk-node's console spies: the never-raises contract is asserted through
    # what was logged.
    class LogCapture
      def initialize
        @entries = []
        @lock = Mutex.new
      end

      def warn(message)
        @lock.synchronize { @entries << [:warn, message] }
      end

      def error(message)
        @lock.synchronize { @entries << [:error, message] }
      end

      def warnings
        @lock.synchronize { @entries.filter_map { |level, message| message if level == :warn } }
      end

      def errors
        @lock.synchronize { @entries.filter_map { |level, message| message if level == :error } }
      end

      def clear
        @lock.synchronize { @entries.clear }
      end
    end

    class FakeRPC
      def initialize(&handler)
        @handler = handler || ->(_name, _request) {}
        @calls = Queue.new
      end

      def unary(name, request)
        @calls << [name, request]
        @handler.call(name, request)
      end

      def recorded
        Array.new(@calls.size) { @calls.pop }
      end
    end

    # A minimal HTTP/1.1 server for driving the SDK over a real socket. The handler gets each
    # request and returns [status, headers, body]; a body Array is sent chunked, one element per
    # chunk, and a Proc element runs between chunks (to stall a stream, say).
    class FakeServer
      Request = Struct.new(:verb, :path, :headers, :body)

      attr_reader :url

      def initialize(&handler)
        @handler = handler
        @server = TCPServer.new("127.0.0.1", 0)
        @url = "http://127.0.0.1:#{@server.addr[1]}"
        @requests = Queue.new
        @connections = []
        @accept = Thread.new do
          loop do
            socket = @server.accept
            @connections << Thread.new(socket) { |conn| serve(conn) }
          end
        rescue IOError, Errno::EBADF
          nil
        end
      end

      def requests
        Array.new(@requests.size) { @requests.pop }
      end

      def next_request(timeout: 5)
        @requests.pop(timeout: timeout)
      end

      def close
        @server.close
        @accept.join
        @connections.each(&:kill)
      end

      private

      def serve(socket)
        while (line = socket.gets)
          verb, path, = line.split
          headers = {}
          while (header = socket.gets) && header != "\r\n"
            name, value = header.split(":", 2)
            headers[name.downcase] = value.strip
          end
          request = Request.new(verb, path, headers, socket.read(headers.fetch("content-length", "0").to_i))
          @requests << request
          respond(socket, *@handler.call(request))
        end
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close
      end

      def respond(socket, status, headers, body)
        socket.write("HTTP/1.1 #{status} X\r\n")
        headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
        if body.is_a?(Array)
          socket.write("Transfer-Encoding: chunked\r\n\r\n")
          body.each do |chunk|
            next chunk.call if chunk.is_a?(Proc)

            socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
          end
          socket.write("0\r\n\r\n")
        else
          socket.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        end
      end
    end

    UUID = "0199d0c1-6a3e-7e8e-9f00-000000000000"

    def logs
      @logs ||= LogCapture.new
    end

    def wait_until(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        flunk "timed out waiting for condition" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
    end

    def envelope(flags, data)
      [flags, data.bytesize].pack("CN") + data
    end
  end
end
