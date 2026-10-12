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

        dropped = @buffer.shift(@buffer.size - @max_queue_size + 1).map(&:event) if @buffer.size >= @max_queue_size
        @buffer << Item.new(event, bytesize)
        if @buffer.size >= @max_size && !@backoff
          @kick = true
        else
          arm
        end
        start
        @wake.signal
        false
      end
      return dead_letter(ClosedError.new("client is closed"), [event]) if closed
      return unless dropped

      @log.warn("Queue full, dropping oldest event")
      dead_letter(QueueOverflowError.new("queue overflow: dropped oldest event"), dropped)
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
    # first; whatever is still queued then is dead-lettered as undelivered, and a send already
    # in flight finishes in the background, reporting its events to on_error if it fails.
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
    rescue StandardError => e
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
      # Events re-queued by a send that outlived close's timeout.
      report_undelivered if @stopping
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
          # A kick during backoff is a stale size trigger; once closed, close's flush sends.
          return [] unless @backoff || @closed

          next
        end
        if @deadline
          wait = @deadline - monotonic
          if wait <= 0
            @deadline = nil
            @backoff = false
            return [] unless @closed

            next
          end
          @wake.wait(@lock, wait)
        else
          # Idle: nothing is buffered without a timer armed, so the thread exits rather than
          # holding on to the client, and the next event starts a new one.
          @thread = nil
          return
        end
      end
    end

    def send_buffer
      chunks = @lock.synchronize do
        disarm
        @sending = true
        split(@buffer.slice!(0..))
      end
      send_chunks(chunks)
    ensure
      @lock.synchronize { @sending = false }
    end

    # Stops at the first transient failure, since the rest would likely fail the same way. Open,
    # the failed and unsent chunks are re-queued in order for a retry after max_wait; closed, the
    # failed chunk is dead-lettered and the rest is left for close to report.
    def send_chunks(chunks)
      until chunks.empty?
        return requeue(chunks.flatten(1), backoff: false) if @lock.synchronize { @stopping }

        chunk = chunks.shift
        error = send_chunk(chunk)
        next if error.nil?

        events = chunk.map(&:event)
        if self.class.permanent?(error)
          @log.error("Permanent error, #{events.size} event(s) dropped (will NOT retry): #{Log.describe(error)}")
          dead_letter(error, events)
        elsif @lock.synchronize { @closed }
          @log.error("Client closed, #{events.size} event(s) dropped after transient error: #{Log.describe(error)}")
          dead_letter(error, events)
          return requeue(chunks.flatten(1), backoff: false)
        else
          @log.warn("Transient error sending batch, will retry: #{Log.describe(error)}")
          return requeue(chunk + chunks.flatten(1), backoff: true)
        end
      end
      @lock.synchronize { @backoff = false }
    end

    def split(items)
      chunks = []
      bytes = 0
      items.each do |item|
        if chunks.empty? || chunks.last.size >= @max_size || bytes + item.bytesize > MAX_BATCH_BYTES
          chunks << []
          bytes = 0
        end
        chunks.last << item
        bytes += item.bytesize
      end
      chunks
    end

    def send_chunk(chunk)
      @sink.call(chunk.map(&:event))
      nil
    rescue StandardError => e
      e
    end

    def requeue(items, backoff:)
      dropped = nil
      @lock.synchronize do
        @buffer.unshift(*items)
        over = @buffer.size - @max_queue_size
        dropped = @buffer.shift(over).map(&:event) if over.positive?
        if backoff
          @backoff = true
          arm
        end
      end
      return unless dropped

      @log.warn("Queue full, dropping #{dropped.size} oldest event(s)")
      dead_letter(QueueOverflowError.new("queue overflow: dropped oldest event"), dropped)
    end

    def report_undelivered
      undelivered = @lock.synchronize { @buffer.slice!(0..) }.map(&:event)
      return if undelivered.empty?

      dead_letter(ClosedError.new("client closed with #{undelivered.size} undelivered event(s)"), undelivered)
    end

    def arm
      @deadline = monotonic + @max_wait if @deadline.nil? && !@closed
    end

    def disarm
      @deadline = nil
    end

    # A raising callback must not abort the sender or a drain: the remaining chunks would be lost
    # with neither a log nor a callback.
    def dead_letter(error, events)
      @on_error&.call(error, events)
      nil
    rescue StandardError => e
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
