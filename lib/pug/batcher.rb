# frozen_string_literal: true

require_relative "errors"
require_relative "log"

module Pug
  # One sender thread per queue, so batches never overlap and go out in order.
  class Batcher
    DEFAULTS = { max_size: 100, max_wait: 5.0, max_queue_size: 10_000 }.freeze

    # The proto cap on BatchCreateRequest.events and BatchIdentifyRequest.identifies.
    MAX_BATCH_ITEMS = 1000

    # The server refuses request bodies over 8 MiB with resource_exhausted, a transient code, so
    # an oversized batch would be retried forever. Half the cap leaves room for the envelope.
    MAX_BATCH_BYTES = 4 * 1024 * 1024

    # Else a max_wait of 0 would retry a refusing server in a tight loop.
    MIN_RETRY_WAIT = 1

    # Plus any error not from the RPC layer, which is a bug.
    PERMANENT_CODES = %i[invalid_argument not_found already_exists permission_denied failed_precondition
                         unimplemented unauthenticated].freeze

    Noun = Data.define(:one, :many) do
      def word(number) = number == 1 ? one : many

      def count(number) = "#{number} #{word(number)}"
    end
    EVENTS = Noun.new(one: "event", many: "events")
    IDENTIFIES = Noun.new(one: "identify", many: "identifies")

    Item = Struct.new(:message, :bytesize)

    # Lets a sink say the first `sent` items arrived, so only the rest is retried.
    class PartialSendError < StandardError
      attr_reader :sent

      def initialize(sent)
        @sent = sent
        super("failed after delivering #{sent}")
      end
    end

    def self.permanent?(error)
      !error.is_a?(Error) || error.code.nil? || PERMANENT_CODES.include?(error.code)
    end

    # Idempotent and silent on a resolved config, so a client resolves once for both batchers.
    def self.resolve(config, log)
      config = (config || {}).transform_keys(&:to_sym)
      (config.keys - DEFAULTS.keys).each { |key| log.warn("Ignoring unknown batch option #{key.inspect}") }
      settings = DEFAULTS.merge(config)
      max_size = setting(log, :max_size, settings[:max_size], 1)
      if max_size > MAX_BATCH_ITEMS
        log.warn("batch.max_size exceeds the #{MAX_BATCH_ITEMS}-item proto cap, clamping to #{MAX_BATCH_ITEMS}.")
        max_size = MAX_BATCH_ITEMS
      end
      { max_size: max_size, max_wait: setting(log, :max_wait, settings[:max_wait], 0),
        max_queue_size: setting(log, :max_queue_size, settings[:max_queue_size], 1) }
    end

    def self.setting(log, name, value, min)
      if min >= 1 && !value.is_a?(Integer)
        log.warn("batch.#{name} must be an integer, using default.")
        return DEFAULTS[name]
      end
      unless value.is_a?(Numeric) && value.real? && value.finite? && value >= min
        log.warn("batch.#{name} must be >= #{min}, using default.")
        return DEFAULTS[name]
      end
      value
    end
    private_class_method :setting

    attr_reader :max_size, :max_wait, :max_queue_size

    def initialize(sink, config, on_error, log, noun: EVENTS)
      @sink = sink
      @on_error = on_error
      @log = log
      @noun = noun
      @max_size, @max_wait, @max_queue_size = self.class.resolve(config, log).values_at(*DEFAULTS.keys)
      @retry_wait = [@max_wait, MIN_RETRY_WAIT].max
      @lock = Mutex.new
      @closed = false
      @closer = nil
      reset
    end

    def enqueue(message, bytesize)
      dropped = nil
      closed = @lock.synchronize do
        after_fork
        next true if @closed

        @buffer << Item.new(message, bytesize)
        dropped = trim
        arm
        @kick = true if @buffer.size >= @max_size && !@backoff
        start
        @wake.signal
        false
      end
      return dead_letter(ClosedError.new("client is closed"), [message]) if closed

      report_overflow(dropped)
    end

    # A transient failure keeps items queued, so this doesn't guarantee an empty queue; close does.
    def flush(timeout: nil)
      !request_flush.pop(timeout: timeout).nil?
    end

    # The Queue yields nil at once if the attempt can't be waited for.
    def request_flush
      waiter = Queue.new
      @lock.synchronize do
        after_fork
        return waiter << true if @stopping || (@buffer.empty? && !@sending && @requests.empty?)
        # Called from on_error, which runs on the sender: waiting for it would wait forever.
        return waiter.close if sender?

        @requests << waiter
        start
        @wake.signal
      end
      waiter
    end

    def sender?
      Thread.current.equal?(@thread)
    end

    def closing?
      Thread.current.equal?(@closer) && !@done.closed?
    end

    # On timeout, everything undelivered is dead-lettered, including a batch still being sent that
    # may yet arrive.
    def close(timeout: nil)
      deadline = timeout && (monotonic + timeout)
      finish_close(start_close, deadline)
    end

    # Split from finish_close so the client can start both drains before waiting on either.
    def start_close
      first = @lock.synchronize do
        after_fork
        next false if @closed

        @closed = true
        @closer = Thread.current
        disarm
        true
      end
      @drain = request_flush if first
      first
    end

    def finish_close(first, deadline)
      unless first
        # Called from on_error, on the sender or the closing thread: the close underway waits on this call.
        return false if !@done.closed? && (sender? || Thread.current.equal?(@closer))

        @done.pop(timeout: remaining(deadline))
        return @done.closed? && @drained
      end

      drained = !@drain.pop(timeout: remaining(deadline)).nil?
      thread = @lock.synchronize do
        @stopping = true
        @wake.signal
        @thread
      end
      stopped = thread.nil? || (!thread.equal?(Thread.current) && !thread.join(remaining(deadline)).nil?)
      report_undelivered
      @drained = drained && stopped
      @done.close
      @drained
    end

    # The default would list every buffered item.
    def inspect = "#<#{self.class.name}>"

    private

    def reset
      @buffer = []
      @inflight = nil
      @requests = []
      @wake = ConditionVariable.new
      @done = Queue.new
      # A child forked from a closed client has nothing to drain, and no closer to wait for.
      @done.close if @closed
      @drained = true
      @deadline = nil
      @kick = false
      @backoff = false
      @sending = false
      @stopping = false
      @thread = nil
      @pid = Process.pid
    end

    # A forked child inherits the buffer but not the sender thread. The parent still owns and
    # sends those items, so the child starts empty with a sender of its own.
    def after_fork
      reset unless @pid == Process.pid
    end

    def start
      return if @thread&.alive?

      @thread = Thread.new { run }
      @thread.name = "pug-#{@noun.many}"
      @thread.report_on_exception = false
    end

    def run
      loop do
        requests = @lock.synchronize { next_job }
        break if requests.nil?

        begin
          send_buffer
        ensure
          requests.each { |waiter| waiter << true }
        end
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      # Nothing else would report it: the thread doesn't, and on_error or a logger may raise anything.
      @log.error("#{@noun.one.capitalize} sender stopped unexpectedly; it restarts with the next #{@noun.one}: " \
                 "#{Log.describe(e)}")
    ensure
      # An idle exit has already handed over to whichever thread starts next, so only a sender
      # that is stopping or crashed answers the pending flushes.
      @lock.synchronize do
        if @thread.equal?(Thread.current)
          @thread = nil unless @stopping
          @requests.each { |waiter| waiter << true }
          @requests.clear
        end
      end
    end

    # Called under the lock. Returns the flush requests the next send answers, or nil to stop.
    def next_job
      loop do
        return if @stopping

        unless @requests.empty?
          requests = @requests
          @requests = []
          return requests
        end
        if @kick
          @kick = false
          # Stale if the send that set it off has since taken those items, or if a backoff began;
          # once closed, close's flush sends.
          return [] if @buffer.size >= @max_size && !@backoff && !@closed

          next
        end
        if @deadline.nil?
          # Idle: exit rather than hold on to the client; the next item starts a new thread.
          @thread = nil
          return
        end
        wait = @deadline - monotonic
        return [] unless wait.positive?

        @wake.wait(@lock, wait)
      end
    end

    # The in-flight chunk is tracked so a timed-out close can report it. Stops at the first
    # transient failure, since the rest would likely fail the same way.
    def send_buffer
      pending = @lock.synchronize do
        disarm
        @backoff = false
        @sending = true
        @buffer.size
      end
      while pending.positive?
        chunk = @lock.synchronize { take_chunk(pending) unless @stopping }
        break if chunk.nil?

        pending -= chunk.size
        break unless %i[sent permanent].include?(settle(chunk, send_chunk(chunk)))
      end
    ensure
      @lock.synchronize { @sending = false }
    end

    # Called under the lock.
    def take_chunk(limit)
      cap = [limit, @max_size].min
      count = 0
      bytes = 0
      @buffer.each do |item|
        break if count == cap || (count.positive? && bytes + item.bytesize > MAX_BATCH_BYTES)

        count += 1
        bytes += item.bytesize
      end
      @inflight = @buffer.shift(count) if count.positive?
    end

    # Not just StandardError: one that ended the thread would strand the chunk. Any error that
    # didn't come from the RPC layer is permanent, so the chunk is dead-lettered.
    def send_chunk(chunk)
      @sink.call(chunk.map(&:message))
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    def settle(chunk, error)
      undelivered = chunk
      if error.is_a?(PartialSendError)
        undelivered = chunk.drop(error.sent)
        error = error.cause || error
      end
      outcome, dropped = @lock.synchronize do
        # close ran out of time during the send, and has reported the chunk itself.
        next [:reported] unless @inflight.equal?(chunk)

        @inflight = nil
        if error.nil? then [:sent]
        elsif self.class.permanent?(error) then [:permanent]
        elsif @closed then [:closed]
        else [:retry, requeue(undelivered)]
        end
      end
      messages = undelivered.map(&:message)
      case outcome
      when :permanent
        @log.error("Permanent error, #{@noun.count(messages.size)} dropped (will NOT retry): #{Log.describe(error)}")
        dead_letter(error, messages)
      when :closed
        @log.error("Client closed, #{@noun.count(messages.size)} dropped after transient error: " \
                   "#{Log.describe(error)}")
        dead_letter(error, messages)
      when :retry
        @log.warn("Transient error sending #{@noun.count(messages.size)}, will retry: #{Log.describe(error)}")
        report_overflow(dropped)
      end
      outcome
    end

    # Called under the lock. The retry is timed from the failure: a timer an enqueue armed during
    # the send could already be due.
    def requeue(items)
      @buffer.unshift(*items)
      @backoff = true
      disarm
      arm(@retry_wait)
      trim
    end

    # Called under the lock.
    def trim
      over = @buffer.size - @max_queue_size
      @buffer.shift(over).map(&:message) if over.positive?
    end

    def report_overflow(dropped)
      return unless dropped

      oldest = "#{dropped.size} oldest #{@noun.word(dropped.size)}"
      @log.warn("Queue full, dropping #{oldest}")
      dead_letter(QueueOverflowError.new("queue overflow: dropped #{oldest}"), dropped)
    end

    def report_undelivered
      inflight, unsent = @lock.synchronize do
        taken = [@inflight, @buffer.slice!(0..)]
        @inflight = nil
        taken
      end
      if inflight
        sending = "#{@noun.count(inflight.size)} still being sent"
        @log.error("Close timed out with #{sending}, which may yet arrive")
        dead_letter(ClosedError.new("close timed out with #{sending}"), inflight.map(&:message))
      end
      return if unsent.empty?

      undelivered = "#{unsent.size} undelivered #{@noun.word(unsent.size)}"
      @log.error("Client closed with #{undelivered}, dropped")
      dead_letter(ClosedError.new("client closed with #{undelivered}"), unsent.map(&:message))
    end

    def arm(wait = @max_wait)
      @deadline = monotonic + wait if @deadline.nil? && !@closed
    end

    def disarm
      @deadline = nil
    end

    # A raising callback must not abort the sender or a drain. NotImplementedError, a common
    # placeholder, is a ScriptError.
    def dead_letter(error, messages)
      @on_error&.call(error, messages)
      nil
    rescue StandardError, ScriptError => e
      @log.error("on_error callback raised; #{@noun.count(messages.size)} may be lost: #{Log.describe(e)}")
      nil
    end

    def remaining(deadline)
      deadline && [deadline - monotonic, 0].max
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
