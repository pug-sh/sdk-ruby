# frozen_string_literal: true

require_relative "test_helper"

class BatcherTest < Minitest::Test
  include Pug::TestSupport

  TRANSIENT = Pug::Error.new("unavailable", code: :unavailable)

  def setup
    @sent = Queue.new
    @errors = Queue.new
  end

  def batcher(config = { max_size: 3, max_wait: 60, max_queue_size: 5 }, &sink)
    sink ||= ->(events) { @sent << events }
    @batcher = Pug::Batcher.new(sink, config, ->(error, events) { @errors << [error, events] }, Pug::Log.new(logs))
  end

  def teardown
    @batcher&.close(timeout: 5)
  end

  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  def test_flushes_when_max_size_is_reached
    b = batcher
    b.enqueue(1, 1)
    b.enqueue(2, 1)
    sleep 0.05
    assert_empty drain(@sent)
    b.enqueue(3, 1)
    assert_equal [1, 2, 3], @sent.pop(timeout: 5)
  end

  def test_flush_sends_the_buffer
    b = batcher
    b.enqueue(1, 1)
    assert b.flush(timeout: 5)
    assert_equal [[1]], drain(@sent)
  end

  def test_flush_on_an_empty_buffer_returns_without_starting_a_sender
    b = batcher
    assert b.flush
    assert_nil b.instance_variable_get(:@thread)
  end

  def test_dead_letters_permanent_errors
    [RuntimeError.new("boom"), Pug::Error.new("bad", code: :invalid_argument),
     Pug::Error.new("no code")].each do |error|
      b = batcher { |_| raise error }
      b.enqueue(1, 1)
      b.flush(timeout: 5)
      assert_equal [[error, [1]]], drain(@errors)
      assert_match(/Permanent error, 1 event\(s\) dropped/, logs.errors.last)
      b.close(timeout: 5)
    end
  end

  def test_retries_transient_errors
    calls = 0
    b = batcher do |events|
      calls += 1
      raise TRANSIENT if calls == 1

      @sent << events
    end
    b.enqueue(1, 1)
    b.flush(timeout: 5)
    assert_empty drain(@sent)
    assert_empty drain(@errors)
    b.flush(timeout: 5)
    assert_equal [[1]], drain(@sent)
  end

  def test_drops_the_oldest_on_overflow_and_reports_it
    b = batcher(max_size: 99, max_wait: 60, max_queue_size: 2)
    b.enqueue(1, 1)
    b.enqueue(2, 1)
    b.enqueue(3, 1)
    error, events = @errors.pop(timeout: 5)
    assert_kind_of Pug::QueueOverflowError, error
    assert_equal [1], events
  end

  def test_close_drains_and_rejects_later_events
    b = batcher
    b.enqueue(1, 1)
    assert b.close(timeout: 5)
    assert_equal [[1]], drain(@sent)
    b.enqueue(2, 1)
    error, events = @errors.pop(timeout: 5)
    assert_kind_of Pug::ClosedError, error
    assert_equal [2], events
  end

  def test_flushes_on_the_max_wait_interval
    b = batcher(max_size: 99, max_wait: 0.05, max_queue_size: 99)
    b.enqueue(1, 1)
    assert_empty drain(@sent)
    assert_equal [1], @sent.pop(timeout: 5)
  end

  def test_the_sender_thread_exits_when_idle
    b = batcher(max_size: 99, max_wait: 0.01, max_queue_size: 99)
    b.enqueue(1, 1)
    @sent.pop(timeout: 5)
    wait_until { b.instance_variable_get(:@thread).nil? }
    b.enqueue(2, 1)
    assert_equal [2], @sent.pop(timeout: 5)
  end

  def test_splits_a_buffer_larger_than_max_size
    attempts = 0
    b = batcher(max_size: 2, max_wait: 60, max_queue_size: 99) do |events|
      attempts += 1
      raise TRANSIENT if attempts == 1

      @sent << events
    end
    b.enqueue(1, 1)
    b.enqueue(2, 1)
    wait_until { attempts == 1 }
    b.enqueue(3, 1)
    b.flush(timeout: 5)
    assert_equal [[1, 2], [3]], drain(@sent)
  end

  def test_splits_by_bytes
    b = batcher(max_size: 99, max_wait: 60, max_queue_size: 99)
    half = Pug::Batcher::MAX_BATCH_BYTES / 2
    b.enqueue(1, half)
    b.enqueue(2, half)
    b.enqueue(3, 1)
    b.enqueue(4, Pug::Batcher::MAX_BATCH_BYTES)
    b.flush(timeout: 5)
    assert_equal [[1, 2], [3], [4]], drain(@sent)
  end

  def test_falls_back_to_defaults_on_invalid_config
    b = batcher(max_size: 0, max_wait: -1, max_queue_size: 2.5, extra: 1)
    assert_equal Pug::Batcher::DEFAULTS.values, [b.max_size, b.max_wait, b.max_queue_size]
    assert_equal 4, logs.warnings.size
    assert_match(/unknown batch option :extra/, logs.warnings.first)
  end

  def test_accepts_string_keys_and_a_zero_max_wait
    b = batcher("max_size" => 7, "max_wait" => 0, "max_queue_size" => 9)
    assert_equal [7, 0, 9], [b.max_size, b.max_wait, b.max_queue_size]
    b.enqueue(1, 1)
    assert_equal [1], @sent.pop(timeout: 5)
  end

  def test_clamps_max_size_to_the_proto_cap
    assert_equal 1000, batcher(max_size: 5000).max_size
    assert_match(/clamping to 1000/, logs.warnings.last)
  end

  def test_dead_letters_a_transient_failure_during_close
    b = batcher { |_| raise TRANSIENT }
    b.enqueue(1, 1)
    b.close(timeout: 5)
    errors = drain(@errors)
    assert_equal [[TRANSIENT, [1]]], errors
    assert_match(/Client closed, 1 event\(s\) dropped after transient error/, logs.errors.last)
  end

  def test_stops_at_the_first_transient_failure_and_keeps_order
    calls = Queue.new
    failing = true
    b = batcher(max_size: 2, max_wait: 60, max_queue_size: 99) do |events|
      calls << events
      raise TRANSIENT if failing

      @sent << events
    end
    (1..5).each { |i| b.enqueue(i, 1) }
    b.flush(timeout: 5)
    attempted = drain(calls)
    refute_empty attempted
    assert attempted.all? { |events| events.first == 1 }, "every failed send restarted from the oldest event"
    failing = false
    b.flush(timeout: 5)
    assert_equal [[1, 2], [3, 4], [5]], drain(@sent)
  end

  def test_a_permanent_failure_moves_on_to_the_next_chunk
    b = batcher(max_size: 1, max_wait: 60, max_queue_size: 99) do |events|
      raise Pug::Error.new("bad", code: :invalid_argument) if events == [1]

      @sent << events
    end
    [1, 2].each { |i| b.enqueue(i, 1) }
    b.flush(timeout: 5)
    wait_until { @sent.size == 1 }
    assert_equal [[2]], drain(@sent)
    assert_equal [1], drain(@errors).first.last
  end

  def test_backs_off_after_a_transient_failure
    attempts = Queue.new
    calls = 0
    b = batcher(max_size: 2, max_wait: 0.3, max_queue_size: 99) do |events|
      attempts << events
      calls += 1
      raise TRANSIENT if calls == 1

      @sent << events
    end
    b.enqueue(1, 1)
    b.flush(timeout: 5)
    attempts.pop(timeout: 5)
    b.enqueue(2, 1)
    b.enqueue(3, 1)
    sleep 0.1
    assert_equal 0, attempts.size, "size triggers must not retry during backoff"
    assert_equal [1, 2], @sent.pop(timeout: 5)
    assert_equal [3], @sent.pop(timeout: 5)
  end

  def test_a_size_trigger_from_a_failing_send_waits_out_the_backoff
    entered = Queue.new
    gate = Queue.new
    calls = 0
    b = batcher(max_size: 2, max_wait: 60, max_queue_size: 99) do |_|
      calls += 1
      if calls == 1
        entered << true
        gate.pop
      end
      raise TRANSIENT
    end
    b.enqueue(1, 1)
    b.enqueue(2, 1)
    entered.pop(timeout: 5)
    b.enqueue(3, 1)
    b.enqueue(4, 1)
    gate << :go
    sleep 0.2
    assert_equal 1, calls
  end

  # As sdk-go's TestBatchRetryWaitsMaxWaitFromTheFailure: a timer an enqueue armed during a slow
  # send must not retry the moment it fails.
  def test_a_retry_waits_from_the_failure
    starts = Queue.new
    calls = 0
    b = batcher(max_size: 99, max_wait: 0.05, max_queue_size: 99) do |_|
      starts << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      calls += 1
      next if calls > 1

      sleep 0.2
      raise TRANSIENT
    end
    b.enqueue(1, 1)
    first = starts.pop(timeout: 5)
    b.enqueue(2, 1)
    retried = starts.pop(timeout: 5)
    assert_operator retried - first, :>=, 0.2 + Pug::Batcher::MIN_RETRY_WAIT - 0.01
  end

  def test_a_zero_max_wait_still_waits_between_retries
    calls = 0
    b = batcher(max_size: 99, max_wait: 0, max_queue_size: 99) do |_|
      calls += 1
      raise TRANSIENT
    end
    b.enqueue(1, 1)
    sleep 0.3
    assert_equal 1, calls
  end

  def test_requeue_respects_max_queue_size
    gate = Queue.new
    attempts = 0
    b = batcher(max_size: 99, max_wait: 60, max_queue_size: 3) do |_|
      attempts += 1
      gate.pop if attempts == 1
      raise TRANSIENT
    end
    b.enqueue(1, 1)
    b.enqueue(2, 1)
    flusher = Thread.new { b.flush(timeout: 5) }
    wait_until { attempts == 1 }
    b.enqueue(3, 1)
    b.enqueue(4, 1)
    gate << :go
    flusher.join
    error, events = @errors.pop(timeout: 5)
    assert_kind_of Pug::QueueOverflowError, error
    assert_equal [1], events
  end

  # An at_exit close must account for every event before the process goes, including those of a
  # send that outlives it.
  def test_close_with_a_timeout_reports_every_event_before_returning
    gate = Queue.new
    b = batcher(max_size: 2, max_wait: 60, max_queue_size: 99) do |events|
      gate.pop
      @sent << events
    end
    (1..5).each { |i| b.enqueue(i, 1) }
    wait_until { b.instance_variable_get(:@sending) }
    refute b.close(timeout: 0.1)
    in_flight, unsent = drain(@errors)
    assert_equal [Pug::ClosedError, [1, 2]], [in_flight.first.class, in_flight.last]
    assert_match(/close timed out with 2 event\(s\) still being sent/, in_flight.first.message)
    assert_equal [Pug::ClosedError, [3, 4, 5]], [unsent.first.class, unsent.last]
    assert_match(/Client closed with 3 undelivered event\(s\), dropped/, logs.errors.last)
    gate << :go
    assert_equal [1, 2], @sent.pop(timeout: 5)
    wait_until { !b.instance_variable_get(:@thread).alive? }
    assert_empty drain(@sent)
    assert_empty drain(@errors), "events were reported twice"
  end

  def test_a_failed_send_that_outlives_close_is_not_reported_twice
    gate = Queue.new
    b = batcher do |_|
      gate.pop
      raise TRANSIENT
    end
    b.enqueue(1, 1)
    refute b.flush(timeout: 0)
    wait_until { b.instance_variable_get(:@sending) }
    refute b.close(timeout: 0.1)
    assert_equal [[1]], drain(@errors).map(&:last)
    gate << :go
    wait_until { !b.instance_variable_get(:@thread).alive? }
    assert_empty drain(@errors)
  end

  def test_close_logs_what_it_drops_without_an_on_error
    b = @batcher = Pug::Batcher.new(->(_) { raise TRANSIENT }, { max_size: 2 }, nil, Pug::Log.new(logs))
    3.times { |i| b.enqueue(i, 1) }
    b.close(timeout: 5)
    assert_includes logs.errors, "[Pug SDK] Client closed with 1 undelivered event(s), dropped"
  end

  def test_flush_honors_its_timeout
    gate = Queue.new
    b = batcher { |_| gate.pop }
    b.enqueue(1, 1)
    refute b.flush(timeout: 0.05)
    gate << :go
  end

  def test_flush_and_close_after_close
    b = batcher
    assert b.close(timeout: 5)
    assert b.flush(timeout: 5)
    assert b.close(timeout: 5)
  end

  def test_concurrent_closers_wait_for_the_drain
    gate = Queue.new
    b = batcher { |events| gate.pop && (@sent << events) }
    b.enqueue(1, 1)
    closers = Array.new(3) { Thread.new { b.close(timeout: 5) } }
    sleep 0.05
    gate << :go
    assert_equal [true, true, true], closers.map(&:value)
    assert_equal [[1]], drain(@sent)
  end

  # on_error runs on the sender, so flush or close waiting for the sender would wait forever.
  def test_flush_and_close_from_on_error_do_not_deadlock
    results = Queue.new
    @batcher = Pug::Batcher.new(->(_) { raise "boom" }, { max_size: 99, max_wait: 60, max_queue_size: 99 },
                                lambda { |_, _|
                                  results << @batcher.flush(timeout: 5)
                                  results << @batcher.close(timeout: 5)
                                }, Pug::Log.new(logs))
    @batcher.enqueue(1, 1)
    @batcher.flush(timeout: 5)
    assert_equal [false, false], [results.pop(timeout: 5), results.pop(timeout: 5)]
  end

  # During a close, on_error runs on the sender for the failed chunk and on the closing thread for
  # the unsent one, and that close can't finish until either returns.
  def test_close_from_on_error_during_a_close_does_not_deadlock
    results = Queue.new
    @batcher = Pug::Batcher.new(->(_) { raise TRANSIENT }, { max_size: 99, max_wait: 60, max_queue_size: 99 },
                                ->(_, _) { results << [Thread.current, @batcher.close(timeout: 5)] },
                                Pug::Log.new(logs))
    @batcher.enqueue(1, Pug::Batcher::MAX_BATCH_BYTES)
    @batcher.enqueue(2, 1)
    closer = Thread.new { @batcher.close }
    assert closer.join(5), "close deadlocked"
    callers = Array.new(2) { results.pop(timeout: 5) }
    assert_equal [false, false], callers.map(&:last)
    assert_equal([false, true], callers.map { |thread, _| thread.equal?(closer) })
  end

  # NotImplementedError, a common placeholder, isn't a StandardError.
  def test_contains_a_raising_on_error
    [RuntimeError, NotImplementedError].each do |error_class|
      b = Pug::Batcher.new(->(_) {}, { max_size: 99, max_wait: 60, max_queue_size: 1 },
                           ->(*) { raise error_class, "callback boom" }, Pug::Log.new(logs))
      b.enqueue(1, 1)
      b.enqueue(2, 1)
      assert_match(/on_error callback raised; 1 event\(s\) may be lost: #{error_class}/, logs.errors.last)
      b.close(timeout: 5)
    end
  end

  def test_logs_a_crashed_sender_and_restarts_it
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException
    @batcher = Pug::Batcher.new(lambda { |events|
      raise "boom" if events == [1]

      @sent << events
    }, { max_size: 1, max_wait: 60, max_queue_size: 99 }, ->(*) { raise crash }, Pug::Log.new(logs))
    @batcher.enqueue(1, 1)
    wait_until { logs.errors.any?(/Event sender stopped unexpectedly/) }
    @batcher.enqueue(2, 1)
    assert_equal [2], @sent.pop(timeout: 5)
  end

  def test_recovers_from_a_raising_sink
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException
    [NoMethodError, crash].each do |error_class|
      calls = 0
      b = batcher do |events|
        calls += 1
        raise error_class, "bug" if calls == 1

        @sent << events
      end
      b.enqueue(1, 1)
      b.flush(timeout: 5)
      b.enqueue(2, 1)
      b.flush(timeout: 5)
      assert_equal [[2]], drain(@sent)
      assert_equal [1], drain(@errors).first.last
      b.close(timeout: 5)
    end
  end

  def test_accounts_for_every_event
    delivered = Queue.new
    b = batcher(max_size: 7, max_wait: 0.001, max_queue_size: 50) do |events|
      raise [TRANSIENT, Pug::Error.new("bad", code: :invalid_argument)].sample if rand < 0.3

      events.each { |event| delivered << event }
    end
    threads = Array.new(8) { |t| Thread.new { 200.times { |i| b.enqueue((t * 1000) + i, 1) } } }
    threads.each(&:join)
    b.close(timeout: 10)
    failed = drain(@errors).flat_map(&:last)
    seen = drain(delivered) + failed
    assert_equal 1600, seen.size
    assert_equal seen.uniq.size, seen.size
  end

  def test_a_forked_child_starts_empty_and_sends_its_own_events
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    reader, writer = IO.pipe
    b = batcher(max_size: 99, max_wait: 60, max_queue_size: 99) { |events| writer.puts(events.inspect) }
    b.enqueue(:parent, 1)
    pid = fork do
      reader.close
      b.enqueue(:child, 1)
      b.flush(timeout: 5)
      writer.close
      exit!(0)
    end
    Process.wait(pid)
    b.flush(timeout: 5)
    writer.close
    assert_equal ["[:child]", "[:parent]"], reader.read.lines.map(&:chomp).sort
  end
end
