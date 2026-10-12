<p align="center">
  <img src="https://app.pug.sh/logo.svg" alt="Pug" width="120" height="120" />
</p>

# pug-sh

Pug server-side SDK for Ruby — event tracking, profile identify, and analytics reads.

It is instance-based and authenticates with a **private** project API key (`prv_…`). Ingestion
never raises, so a tracking call can't take down your request path.

## Install

```ruby
# Gemfile
gem "pug-sh"
```

Requires Ruby 3.3 or newer.

## Quick start

```ruby
require "pug"

pug = Pug::Client.new(
  api_key: ENV.fetch("PUG_API_KEY"),
  endpoint: "https://pug.example.com",
)

# Track an event. distinct_id (who the event is for) comes first — a server has no ambient user.
pug.track("user_42", "order.completed", amount: 49.0, currency: "USD")

# Well-known events get their properties type-checked and validated against the event's schema.
pug.track("user_42", "feature_used", feature_id: "export")

# Identify a profile (never raises — failures are logged).
pug.identify("user_42", email: "ada@example.com", plan: "pro")

# Reads raise Pug::Error.
profile = pug.profiles.get_by_external_id("user_42")
pug.profiles.list.each { |p| puts p.external_id }
trend = pug.insights.query(
  spec: insight_spec, # a Hash, or a Pug::Proto::Shared::Insights::V1::InsightQuerySpec
  time_range: { from: Time.now - (30 * 86_400), to: Time.now },
  granularity: :GRANULARITY_DAY,
)

# Drain on shutdown so no buffered events are lost.
pug.close
```

## Behaviour

- **Ingestion never raises.** `track` and `identify` validate input client-side and log and drop
  anything invalid. `track` is non-blocking: a background thread sends events in batches, by size
  (`max_size`) or interval (`max_wait`).
- **Delivery is best-effort with retry.** A transient send failure keeps events queued and retries
  after `max_wait`; a permanent one (a fixed set of client-error Connect codes, plus any
  non-transport error) dead-letters them via `on_error`. `close` drains and reports anything still
  undelivered through `on_error`. `on_error` covers buffered `track` events only — `identify`
  failures are logged.
- **Reads are request/response and do raise** `Pug::Error` — they run in your control flow, so
  you own retry. They are not auto-retried.
- **Well-known events** have typed, validated properties; any other `kind` is accepted as a
  custom event with loose properties.
- **Thread- and fork-safe.** One client can be shared by every thread. A client created before a
  fork (Puma, Unicorn, Sidekiq) starts empty in each child, with its own sender thread and
  connections; events buffered in the parent stay with the parent.

## API

### `Pug::Client.new(**options)`

| Option     | Type                    | Default          | Description                                                                                                       |
| ---------- | ----------------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------- |
| `api_key`  | `String`                | —                | **Required.** Private project key (`prv_…`).                                                                      |
| `endpoint` | `String`                | hosted endpoint  | Pug server origin.                                                                                                |
| `batch`    | `Hash`                  | see below        | Ingestion buffer: `max_size` (100, capped at 1000), `max_wait` (5 seconds), `max_queue_size` (10,000).            |
| `on_error` | callable                | none             | Dead-letter hook for undeliverable buffered `track` events (`identify` failures are logged, not routed here).      |
| `logger`   | `Logger`-like           | `$stderr`, WARN  | Receives the SDK's warnings and errors (anything with `warn` and `error`, such as `Rails.logger`).                |
| `timeout`  | `Numeric`               | 10               | Request timeout, in seconds.                                                                                      |

```ruby
Pug::Client.new(
  api_key:,  # required, prv_…
  batch: { max_size: 100, max_wait: 5, max_queue_size: 10_000 },
  on_error: lambda do |error, events|
    # dead-letter sink: error is a Pug::QueueOverflowError, a Pug::ClosedError, a Pug::Error
    # with a permanent Connect code, or the exception a bug raised
  end,
)
```

`on_error` runs on the background sender thread, on the thread calling `close` for what it reports
undelivered, or on the thread that called `track` when the queue overflows. It must be thread-safe
and return promptly; `flush` and `close` called from inside it return `false` at once instead of
waiting.

### Ingestion (never raises)

- `pug.track(distinct_id, kind, properties = nil, options = nil)` — enqueue an event. Non-blocking.
- `pug.identify(external_id, traits = nil, options = nil)` — create or update a profile. Blocks
  until the server answers.
- `pug.flush(timeout: nil)` — send the currently buffered events now and wait for that attempt.
  Returns `false` if `timeout` (seconds) passed first.
- `pug.close(timeout: nil)` — drain and shut down; call on graceful exit so nothing buffered is lost.
  Returns `false` if `timeout` passed first; events still undelivered then go to `on_error`.

Ids are non-empty Strings (an Integer id, such as a record's, is sent as its decimal string).
Properties go in a Hash, braces optional when there are no options:

```ruby
pug.track(user.id, "signup", plan: "pro")
pug.track(user.id, "signup", { plan: "pro" }, timestamp: signed_up_at, location: { country: "DE" })
```

`track` options: `timestamp` (a `Time`; defaults to now), `session_id` (a UUID overriding the
client's per-instance session), `location` (the visitor's location — see below).
`identify` options: `anonymous_id` (must start with `anon-`; triggers anon→identified merge),
`device_id`. Traits must be JSON-serializable.

Custom properties map by Ruby type:

| Ruby value                                       | Sent as                                   |
| ------------------------------------------------ | ----------------------------------------- |
| `String`, `Symbol`                               | string                                    |
| `true`, `false`                                  | bool                                      |
| `Integer`                                        | int (outside the int64 range: dropped)    |
| `Float`, `BigDecimal`, `Rational`                | double (NaN and ±Infinity: dropped)       |
| `Time`, `DateTime`, `Google::Protobuf::Timestamp`| timestamp                                 |
| `Date`                                           | ISO 8601 date string, e.g. `"2026-10-10"` |
| `Google::Protobuf::Duration`                     | duration string, e.g. `"1.5s"`            |
| `Hash`, `Array`                                  | JSON string                               |
| `nil`                                            | omitted                                   |

Anything else is dropped with a warning. Strings are capped at 1024 bytes (truncated with a
warning), and invalid UTF-8 is repaired.

### Well-known events

For a well-known kind such as `purchase`, properties are checked against the event's schema.
Keys may be the field's name (`product_id`) or its JSON name (`productId`); either way the
property is sent under the JSON name, like every other Pug SDK. A field's type comes from the
schema rather than the Ruby value, so `amount: 10` is sent as a double. A value of the wrong type,
or one failing the schema's rules, drops the event with an error; other keys ride along as custom
properties.

```ruby
pug.track("user_42", "purchase", product_id: "p1", amount: 49, currency: "USD", coupon: "FALL")
pug.track("user_42", "video_play", video_id: "v1", position: 92.5) # a Duration field, in seconds
```

Duration fields take seconds as a number, `{ seconds:, nanos: }`, or a `Google::Protobuf::Duration`.

### Location

Pug only derives geo from CDN headers on browser (public-key) requests. This SDK uses a private
key, so the server adds no geo of its own — without `location`, an event has no geo at all:

```ruby
pug.track("user-123", "checkout_completed", { plan: "pro" }, location: { country: "DE", city: "Berlin" })
```

Fields: `continent`, `country`, `region`, `city`, `postal_code`, `metro_code`, `timezone`,
`latitude`, `longitude` — strings, except the two coordinates. `country` must be an ISO 3166-1
alpha-2 code (case and surrounding spaces are normalized); `latitude` and `longitude` are only
sent as a pair.

A field that is missing, nil or empty is omitted silently. One that looks like a mistake —
unknown key, wrong type, unknown country, coordinate out of range — is dropped with a warning and
the rest is still sent. If nothing is usable the event goes out with no geo.

### Reads (raise `Pug::Error`)

These run in your control flow:

- `pug.profiles` — `get(id, include_bots: false)`, `get_by_external_id(external_id, include_bots: false)`,
  `delete(id)`, `list(request = nil)` (auto-paginating: yields each profile to a block, or returns
  an `Enumerator`).
- `pug.activity` — `feed`, `event_explorer`, `heatmap`, `profile_sessions`, `profile_stats`,
  `filter_schema`, `property_values`.
- `pug.insights` — `query`, `segment_users`, `filter_schema`, `property_values`.

Requests are a Hash or the generated request message, and responses are the generated messages,
under `Pug::Proto` (`Pug::Proto::Shared::Insights::V1::QueryResponse`, …); call `to_h` on one
for plain Ruby data.

```ruby
sessions = pug.activity.profile_sessions(distinct_id: "user_42", page_size: 50)
sessions.sessions.each { |s| puts s.session_id }
```

Reads leave out traffic tagged as a bot at ingest unless you ask for it: pass
`include_bots: true` to `profiles.get` and `get_by_external_id`, or set it on the request.

`Pug::Error#code` is the Connect code as a Symbol (`:not_found`, `:unavailable`, …), or `nil`
when the failure didn't come from the RPC layer; `cause` is the underlying exception.

```ruby
begin
  pug.profiles.get("p_123")
rescue Pug::Error => e
  raise unless e.code == :not_found
end
```

## Rails

```ruby
# config/initializers/pug.rb
PUG = Pug::Client.new(api_key: Rails.application.credentials.pug_api_key, logger: Rails.logger)
at_exit { PUG.close(timeout: 5) }
```

The client is safe to create before Puma or Unicorn fork their workers.

## Contributing

See [`docs/development.md`](./docs/development.md) for building, testing, and how the generated
code and the well-known event catalog are maintained.

## License

MIT
