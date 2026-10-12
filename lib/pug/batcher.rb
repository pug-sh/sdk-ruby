# frozen_string_literal: true

require_relative "errors"
require_relative "log"

module Pug
  # In-memory batching transport. Events accumulate and are sent by a single background thread
  # on a size or interval trigger, so batches never overlap and go out in order. A transient
  # failure re-queues them for a retry after max_wait; a permanent one dead-letters them to
  # on_error, as does close for anything still undelivered.
  class Batcher
    DEFAULTS = { max_size: 100, max_wait: 5.0, max_queue_size: 10_000 }.freeze

    # BatchCreateRequest.events is capped at 1000 by the events proto.
    MAX_BATCH_EVENTS = 1000

    # The server refuses request bodies over 8 MiB with resource_exhausted, a transient code, so
    # an oversized batch would be retried forever. Half the cap leaves room for the envelope.
    MAX_BATCH_BYTES = 4 * 1024 * 1024

    # Retries wait max_wait but at least this long, or a max_wait of 0 would retry a server that
    # refuses connections in a tight loop.
    MIN_RETRY_WAIT = 1

    # Retrying can't fix these client errors, nor an error that didn't come from the RPC layer,
    # which is a bug.
    PERMANENT_CODES = %i[invalid_argument not_found already_exists permission_denied failed_precondition
                         unimplemented unauthenticated].freeze

    Item = Struct.new(:event, :bytesize)

    def self.permanent?(error)
      !error.is_a?(Error) || error.code.nil? || PERMANENT_CODES.include?(error.code)
    end

    attr_reader :max_size, :max_wait, :max_queue_size

    def initialize(sink, config, on_error, log)
      @sink = sink
      @on_error = on_error
      @log = log
      configure(config)
      @lock = Mutex.new
      @closed = false
      @closer = nil
      reset
    end

    def enqueue(event, bytesize)
      dropped = nil
      closed = @lock.synchronize do
        after_fork
        next true if @closed

        @buffer << Item.new(event, bytesize)
        dropped = trim
        arm
        @kick = true if @buffer.size >= @max_size && !@backoff
        start
        @wake.signal
        false
      end
      return dead_letter(ClosedError.new("client is closed"), [event]) if closed

      report_overflow(dropped)
    end

    # Resolves once the attempt it requested has finished, or returns false when timeout (in
    # seconds) runs out first. A transient failure keeps events queued, so an empty queue is not
    # guaranteed; close drains.
    def flush(timeout: nil)
      waiter = Queue.new
      @lock.synchronize do
        after_fork
        return true if @stopping || (@buffer.empty? && !@sending && @requests.empty?)
        # Called from on_error, which runs on the sender: waiting for it would wait forever.
        return false if Thread.current.equal?(@thread)

        @requests << waiter
        start
        @wake.signal
      end
      !waiter.pop(timeout: timeout).nil?
    end

    # Drains the buffer and stops the sender. Returns false when timeout (in seconds) runs out
    # first; everything still undelivered then is dead-lettered before it returns, including a
    # batch whose send goes on in the background and may yet succeed.
    def close(timeout: nil)
      deadline = timeout && (monotonic + timeout)
      first = @lock.synchronize do
        after_fork
        next false if @closed

        @closed = true
        @closer = Thread.current
        disarm
        true
      end
      unless first
        # Called from on_error, on the sender or the closing thread: the close underway waits on this call.
        return false if !@done.closed? && (Thread.current.equal?(@thread) || Thread.current.equal?(@closer))

        @done.pop(timeout: remaining(deadline))
        return @done.closed? && @drained
      end

      drained = flush(timeout: remaining(deadline))
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

    # The default would list every buffered event.
    def inspect = "#<#{self.class.name}>"

    private

    def configure(config)
      config = (config || {}).transform_keys(&:to_sym)
      (config.keys - DEFAULTS.keys).each { |key| @log.warn("Ignoring unknown batch option #{key.inspect}") }
      settings = DEFAULTS.merge(config)
      @max_size = setting(:max_size, settings[:max_size], 1)
      if @max_size > MAX_BATCH_EVENTS
        @log.warn("batch.max_size exceeds the #{MAX_BATCH_EVENTS}-event proto cap, clamping to #{MAX_BATCH_EVENTS}.")
        @max_size = MAX_BATCH_EVENTS
      end
      @max_wait = setting(:max_wait, settings[:max_wait], 0)
      @retry_wait = [@max_wait, MIN_RETRY_WAIT].max
      @max_queue_size = setting(:max_queue_size, settings[:max_queue_size], 1)
    end

    # Counts must be integers; max_wait, in seconds, may be fractional.
    def setting(name, value, min)
      if min >= 1 && !value.is_a?(Integer)
        @log.warn("batch.#{name} must be an integer, using default.")
        return DEFAULTS[name]
      end
      unless value.is_a?(Numeric) && value.real? && value.finite? && value >= min
        @log.warn("batch.#{name} must be >= #{min}, using default.")
        return DEFAULTS[name]
      end
      value
    end

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
    # sends those events, so the child starts empty with a sender of its own.
    def after_fork
      reset unless @pid == Process.pid
    end

    def start
      return if @thread&.alive?

      @thread = Thread.new { run }
      @thread.name = "pug-batcher"
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
      @log.error("Event sender stopped unexpectedly; it restarts with the next event: #{Log.describe(e)}")
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
          # Stale if the send that set it off has since taken those events, or if a backoff began;
          # once closed, close's flush sends.
          return [] if @buffer.size >= @max_size && !@backoff && !@closed

          next
        end
        if @deadline.nil?
          # Idle: nothing is buffered without a timer armed, so the thread exits rather than
          # holding on to the client, and the next event starts a new one.
          @thread = nil
          return
        end
        wait = @deadline - monotonic
        return [] unless wait.positive?

        @wake.wait(@lock, wait)
      end
    end

    # One attempt at what is buffered now, a chunk at a time. Events stay in the buffer until
    # their chunk is taken, and the chunk being sent is tracked, so a close that runs out of time
    # can report every event. Stops at the first transient failure, since the rest would likely
    # fail the same way.
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

    # Called under the lock: the oldest events, at most limit of them, cut at max_size and
    # MAX_BATCH_BYTES.
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
      @sink.call(chunk.map(&:event))
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    # Returns the outcome of a chunk's send. Open, a transient failure re-queues the chunk for a
    # retry; closed, it dead-letters it and leaves the rest for close to report.
    def settle(chunk, error)
      outcome, dropped = @lock.synchronize do
        # close ran out of time during the send, and has reported the chunk itself.
        next [:reported] unless @inflight.equal?(chunk)

        @inflight = nil
        if error.nil? then [:sent]
        elsif self.class.permanent?(error) then [:permanent]
        elsif @closed then [:closed]
        else [:retry, requeue(chunk)]
        end
      end
      events = chunk.map(&:event)
      case outcome
      when :permanent
        @log.error("Permanent error, #{events.size} event(s) dropped (will NOT retry): #{Log.describe(error)}")
        dead_letter(error, events)
      when :closed
        @log.error("Client closed, #{events.size} event(s) dropped after transient error: #{Log.describe(error)}")
        dead_letter(error, events)
      when :retry
        @log.warn("Transient error sending batch, will retry: #{Log.describe(error)}")
        report_overflow(dropped)
      end
      outcome
    end

    # Called under the lock. The retry is timed from the failure: a timer an enqueue armed during
    # the send could already be due.
    def requeue(chunk)
      @buffer.unshift(*chunk)
      @backoff = true
      disarm
      arm(@retry_wait)
      trim
    end

    # Called under the lock. Drops the oldest events past max_queue_size and returns them.
    def trim
      over = @buffer.size - @max_queue_size
      @buffer.shift(over).map(&:event) if over.positive?
    end

    def report_overflow(dropped)
      return unless dropped

      @log.warn("Queue full, dropping #{dropped.size} oldest event(s)")
      dead_letter(QueueOverflowError.new("queue overflow: dropped oldest event"), dropped)
    end

    def report_undelivered
      inflight, unsent = @lock.synchronize do
        taken = [@inflight, @buffer.slice!(0..)]
        @inflight = nil
        taken
      end
      if inflight
        @log.error("Close timed out with #{inflight.size} event(s) still being sent, which may yet arrive")
        dead_letter(ClosedError.new("close timed out with #{inflight.size} event(s) still being sent"),
                    inflight.map(&:event))
      end
      return if unsent.empty?

      @log.error("Client closed with #{unsent.size} undelivered event(s), dropped")
      dead_letter(ClosedError.new("client closed with #{unsent.size} undelivered event(s)"), unsent.map(&:event))
    end

    def arm(wait = @max_wait)
      @deadline = monotonic + wait if @deadline.nil? && !@closed
    end

    def disarm
      @deadline = nil
    end

    # A raising callback must not abort the sender or a drain: the remaining chunks would be lost
    # with neither a log nor a callback. NotImplementedError, a common placeholder, is a
    # ScriptError.
    def dead_letter(error, events)
      @on_error&.call(error, events)
      nil
    rescue StandardError, ScriptError => e
      @log.error("on_error callback raised; #{events.size} event(s) may be lost: #{Log.describe(e)}")
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
