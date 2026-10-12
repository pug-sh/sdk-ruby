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

pug = Pug::Client.new(api_key: ENV.fetch("PUG_API_KEY"))

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
  spec: { insight_type: :INSIGHT_TYPE_TRENDS, events: [{ event: { kind: "order.completed" } }] },
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
  `max_wait` after the failure, but no sooner than a second; a permanent one (a fixed set of
  client-error Connect codes, plus any non-transport error) dead-letters them via `on_error`.
  `close` drains and reports anything still undelivered through `on_error` and the log.
  `on_error` covers buffered `track` events only — `identify` failures are logged, and so are
  events the server drops from a batch it accepts (`BatchCreateResponse.dropped`), at WARN.
- **Reads are request/response and do raise** `Pug::Error` — they run in your control flow, so
  you own retry. They are not auto-retried.
- **Well-known events** have typed, validated properties; any other `kind` is accepted as a
  custom event with loose properties.
- **Thread- and fork-safe.** One client can be shared by every thread. A client created before a
  fork (Puma, Unicorn, Sidekiq) starts empty in each child, with its own sender thread and
  connections; events buffered in the parent stay with the parent.

## API

### `Pug::Client.new(**options)`

| Option     | Type          | Default                     | Description                                                                                                                       |
| ---------- | ------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `api_key`  | `String`      | —                           | **Required.** Private project key (`prv_…`).                                                                                      |
| `endpoint` | `String`      | hosted endpoint             | Pug server origin.                                                                                                                |
| `batch`    | `Hash`        | see below                   | Ingestion buffer: `max_size` (100, capped at 1000), `max_wait` (5 seconds), `max_queue_size` (10,000).                            |
| `on_error` | callable      | none                        | Dead-letter hook for undeliverable buffered `track` events, called with `(error, events)`.                                        |
| `logger`   | `Logger`-like | `Logger.new($stderr)`, WARN | Gets the SDK's warnings and errors: anything with public `warn` and `error`, such as `Rails.logger` (wrap an IO in `Logger.new`). |
| `timeout`  | `Numeric`     | 10                          | Request timeout, in seconds.                                                                                                      |

```ruby
Pug::Client.new(
  api_key: ENV.fetch("PUG_API_KEY"),
  batch: { max_size: 100, max_wait: 5, max_queue_size: 10_000 },
  on_error: lambda do |error, events|
    # dead-letter sink: error is a Pug::QueueOverflowError, a Pug::ClosedError, a Pug::Error
    # with a permanent Connect code, the transient Pug::Error that failed close's last attempt,
    # or the exception a bug raised
  end,
)
```

`on_error` runs on the background sender thread; on the thread calling `close`, for what it
reports undelivered; or, when the queue overflows, on the thread that called `track`. It must be
thread-safe and return promptly. Called from inside it on the sender or the closing thread, `flush`
and `close` don't wait for what is waiting on `on_error`: they return `false` at once, except that
`flush` returns `true` while `close` reports. On the overflow path nothing waits on `on_error`, so
they behave as anywhere else, blocking the thread that called `track`.

### Ingestion (never raises)

- `pug.track(distinct_id, kind, properties = nil, options = nil)` — enqueue an event. Non-blocking.
- `pug.identify(external_id, traits = nil, options = nil)` — create or update a profile. Blocks
  until the server answers.
- `pug.flush(timeout: nil)` — send the currently buffered events now and wait for that attempt.
  Returns `false` if `timeout` (seconds) passed first. `true` means the attempt finished, not that
  every event was delivered: a transient failure keeps them queued for a retry.
- `pug.close(timeout: nil)` — drain and shut down; call on graceful exit so nothing buffered is lost.
  Returns `false` if `timeout` passed first. Either way, by the time it returns every event it
  couldn't send has gone to `on_error` and the log, including a batch still being sent when the
  timeout ran out, which may yet arrive.

A `timeout` that isn't a number waits without one, with a warning.

`distinct_id` and `external_id` are non-empty Strings, or Integers such as a record's id, sent as
their decimal string; `session_id`, `anonymous_id` and `device_id` must be Strings. Properties go
in a Hash, braces optional, and options follow as keywords. Without braces, a key named after an
option sets that option, so a property with an option's name needs the braces:

```ruby
pug.track("user_42", "signup", plan: "pro")
pug.track("user_42", "signup", plan: "pro", timestamp: Time.now - 3600)
pug.track("user_42", "signup", { plan: "pro", location: "landing" }, location: { country: "DE" })
```

`track` options: `timestamp` (a `Time`; defaults to now), `session_id` (a UUID overriding the
client's per-instance session), `location` (the visitor's location — see below).
`identify` options, which work the same way with traits: `anonymous_id` (must start with `anon-`;
triggers anon→identified merge), `device_id`. Traits must be JSON-serializable, with nested values
mapped as for properties below; they travel as a protobuf `Struct`, whose numbers are doubles, so
an integer past 2^53 is refused.

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

Anything else is dropped with a warning. Inside a `Hash` or `Array`, a `Time`, `DateTime` or `Date`
becomes an ISO 8601 string and a `BigDecimal` or `Rational` a number, while a value JSON has no
form for, such as a `Set`, drops the whole property with a warning. Strings are capped at 1024
bytes (truncated with a warning), and invalid UTF-8 is repaired.

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
pug.track("user_42", "checkout_completed", { plan: "pro" }, location: { country: "DE", city: "Berlin" })
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
  `delete(id)`, `list(request = nil, timeout: nil)` (auto-paginating: yields each profile to a
  block, or returns an `Enumerator`). The timeout bounds the whole stream, the time your block
  takes included, so `timeout:` (seconds) can give one long `list` more than the client's.
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
`include_bots: true` to `profiles.get` and `get_by_external_id`, set it on the request of
`profiles.list` or of an `activity` read other than `filter_schema` and `property_values`, or set
it on the `spec` of `insights.query`. The other requests have no such field.

`Pug::Error#code` is the Connect code as a Symbol (`:not_found`, `:unavailable`, …), or `nil`
when the failure didn't come from the RPC layer; `cause` is the underlying exception. The SDK
doesn't follow redirects, so one is `:unimplemented`, like a wrong path: point `endpoint` at the
final URL.

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
unless ENV["SECRET_KEY_BASE_DUMMY"]
  PUG = Pug::Client.new(api_key: Rails.application.credentials.pug_api_key, logger: Rails.logger)
  at_exit { PUG.close(timeout: 5) }
end
```

`Pug::Client.new` raises without an API key, so the guard skips it during the `assets:precompile`
step of Rails' generated Dockerfile, which boots the app with `SECRET_KEY_BASE_DUMMY=1` and no
credentials. The client is safe to create before Puma or Unicorn fork their workers.

## Contributing

See [`docs/development.md`](./docs/development.md) for building, testing, and how the generated
code and the well-known event catalog are maintained.

## License

MIT
