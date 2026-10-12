# Development

Internal guide for working on `sdk-ruby`. End-user docs live in the [README](../README.md).

## Toolchain

- **Ruby** 3.3 or newer, with **Bundler** — `bundle install` sets up everything below except buf
  and protoc.
- **[Minitest](https://github.com/minitest/minitest)** + **Rake** — tests (`bundle exec rake test`).
- **[RuboCop](https://rubocop.org)** — lint and format (see `.rubocop.yml`).
- **[debride](https://github.com/seattlerb/debride)** — dead code (see [Dead code](#dead-code)).
- **[buf](https://buf.build/docs/installation)** 1.73 and **protoc** 36.1 — re-vendor and
  regenerate the protobuf code. Only needed when updating protos.

## Protobuf types (vendored)

Protobuf types are **vendored**, not pulled from the Buf Schema Registry: the generated code is
committed under `lib/pug/gen/` and shipped in the gem, so `gem install` needs nothing but
rubygems.org. The `.proto` sources are mirrored under `proto/` from a **pinned** BSR commit — the
same commit and allowlist as sdk-node and sdk-go. See the `Makefile`:

| Command             | What it does                                                                                                                             |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `make sync-protos`  | `buf export buf.build/pugsh/pug:$(PROTO_COMMIT)` (read-only) → `proto/` mirror, allowlisted to the SDK packages (incl. the server-only `shared/**`). Needs BSR network. |
| `make protos`       | `buf generate` → `lib/pug/gen/`, then rewrites its requires (below). Offline.                                                           |
| `make proto-latest` | Print the newest commit on the module's `main` branch (to bump `PROTO_COMMIT`).                                                          |

To take a newer schema: run `make proto-latest`, set `PROTO_COMMIT` in the `Makefile`, then
`make sync-protos && make protos`, run the tests, and review + commit the `proto/` and
`lib/pug/gen/` diff. Builds and CI never touch the BSR — they load the committed snapshot, and CI
fails if a fresh `make protos` differs from it.

Things specific to Ruby codegen:

- The generator is protoc's built-in one (`protoc_builtin: ruby` in `buf.gen.yaml`), so the
  output depends on the protoc version; `make protos` refuses any protoc but `PROTOC_VERSION`.
- buf's managed mode sets `ruby_package` per proto package, so everything lands under
  `Pug::Proto` (`Pug::Proto::Sdk::Events::V1::Event`) instead of top-level `Common`, `Sdk`,
  `Shared` and `Buf` modules. Descriptor names keep the upstream packages (`sdk.events.v1.Event`).
- protoc requires imports by proto path (`require 'common/v1/property_value_pb'`), which only
  resolves with the output directory on `$LOAD_PATH`. `scripts/relativize_requires.rb` rewrites
  them to `require_relative`, so the gem never touches `$LOAD_PATH`.
- `buf/validate/validate.proto` **is** generated (sdk-go skips it): the validator decodes its
  `FieldRules` from the descriptors.

As in sdk-go, a program that loads two copies of the pug protos (this gem alongside code
generated from the monorepo, say) fails at load: protobuf refuses a second registration of the
same `.proto` file.

## Well-known events

Like sdk-go, there is no generated registry: `lib/pug/well_known.rb` builds the catalog at load
from the `(common.events.v1.kind)` option of the generated `Pug::Proto::Common::Events::V1`
messages. Ruby's protobuf has no extension API, so custom options survive only as unknown fields
of a descriptor's options; `Pug::Proto::Options` re-encodes the options message and reads them
back off the wire.

- **Filter policy** (same as sdk-node): an event is well-known here if its
  `(common.events.v1.platforms)` option contains `PLATFORM_SERVER` **or** is unset.
- `test/fixtures/well_known_events.golden` lists the catalog (`kind` → message) and is identical
  to sdk-go's. A proto sync that adds, drops or re-targets an event fails the tests until the
  change is reviewed and accepted with `UPDATE_GOLDEN=1 bundle exec rake test`.

## Validation

There is no protovalidate for Ruby, so `lib/pug/validator.rb` implements the part the SDK's
schemas use, driven by the `buf.validate` rules decoded from the descriptors: `required`, oneof
`required`, the numeric/duration/timestamp `const`/`lt`/`lte`/`gt`/`gte`/`in`/`not_in` family,
`finite`, the string length, pattern, affix, list and UUID rules, and recursion into messages,
lists and map values. Messages are formatted like protovalidate's (`path: message [rule_id]`).

- Patterns are RE2; `^` and `$` are rewritten to `\A` and `\z`, since Ruby's anchor every line.
- CEL has no Ruby interpreter. The handful of expressions the schemas use are implemented in
  `Validator::CEL`, keyed by their exact text, so an expression changed upstream stops matching
  rather than being enforced with stale semantics.
- `Validator.unsupported_rules` lists every rule it can't evaluate. The tests require it to be
  empty for `Event`, `IdentifyRequest` and every catalog event, so a proto sync that adopts a new
  rule fails CI instead of going silently unenforced. Read requests aren't validated client-side,
  as in sdk-node: the server does.

## Connect

There is no Connect library for Ruby either. `lib/pug/connect.rb` speaks the
[Connect protocol](https://connectrpc.com/docs/protocol) over `Net::HTTP` for the two call
shapes the SDK uses — unary, and server streaming for `profiles.list` — with binary protobuf, like
sdk-node. It mirrors connect-es where it matters: `Connect-Timeout-Ms`, the HTTP-status-to-code
table, JSON error bodies, end-of-stream errors, and the protocol-error codes. Network failures map
to `unavailable` and timeouts to `deadline_exceeded`, so the batcher retries them.

Connections are kept alive in a small pool (one per concurrent caller, as `Net::HTTP` isn't
thread-safe). After a fork the child drops the inherited connections without closing them:
closing a TLS connection writes to it, and the parent still owns it.

## Dead code

`make deadcode` (part of `make check`) runs debride over `lib` and `test`, leaving out
`lib/pug/gen`, and fails if it reports any method that nothing calls. debride matches calls by
method name, statically: a call from a test counts, any call to a method of the same name counts,
and a name built at runtime (`public_send(:"has_#{name}?")`) is invisible. Minitest calls `test_*`,
`setup` and `teardown` by reflection, so `.debride_whitelist` lists them; add a name, or a
`/regexp/`, there for anything else only called that way. To delete what it reports instead,
`bundle exec debride_rm` takes the same arguments and edits the files in place.

## Scripts

| Command                    | What it does                                                     |
| -------------------------- | ---------------------------------------------------------------- |
| `bundle exec rake test`    | Run the tests                                                    |
| `bundle exec rubocop`      | Lint (`-a` to autocorrect)                                       |
| `make deadcode`            | Fail on methods nothing calls ([Dead code](#dead-code))          |
| `make build`               | `gem build pug-sh.gemspec`                                       |
| `make check`               | `lint`, `deadcode`, `test`, `build`                              |
| `make ci`                  | `protos`, `check-codegen`, then `check` — what CI runs           |

`Pug::VERSION` in `lib/pug/version.rb` is the gem's version and is sent with every event as
`$sdkVersion`. Bump it together with the release tag (`vX.Y.Z`).

## Source layout

| File                    | Responsibility                                                                    |
| ----------------------- | --------------------------------------------------------------------------------- |
| `client.rb`             | `Pug::Client` — options, ingestion (`track`/`identify`), lifecycle.               |
| `event_builder.rb`      | Builds and validates `Event` protos; maps Ruby values and typed schemas to `PropertyValue`; location. |
| `batcher.rb`            | Batching transport: one sender thread, flush triggers, retry, dead-letter.        |
| `reads.rb`              | `Profiles`/`Activity`/`Insights` read facades and error normalization.            |
| `rpc.rb`                | The procedure table (path, request and response class per RPC).                   |
| `connect.rb`            | Connect protocol client and connection pool.                                      |
| `validator.rb`          | protovalidate subset.                                                             |
| `well_known.rb`         | Well-known event catalog from the proto options.                                  |
| `proto.rb`              | Loads the generated code; reads custom options off descriptors.                   |
| `countries.rb`          | ISO 3166-1 alpha-2 set, mirroring the server's `internal/geo`.                    |
| `errors.rb`, `log.rb`   | `Pug::Error` and its subclasses; the `[Pug SDK]`-prefixed logger wrapper.         |

## Behaviour notes (vs sdk-node)

The contract matches sdk-node. sdk-go's deliberate differences carry over:

- **One sender thread.** Flushes run sequentially instead of overlapping, so event order holds
  across flushes.
- **Retry backoff.** A send stops at the first transiently failing chunk and re-queues it with the
  unsent ones, then waits `max_wait` before retrying; size triggers during that wait don't retry
  early. During `close`, the failed chunk is dead-lettered and the unsent rest reported as
  undelivered.
- **Byte-aware chunks.** Requests are also cut at 4 MiB, and an event that alone exceeds it is
  dropped at `track`: the server refuses bodies over 8 MiB with a transient code, so an oversized
  batch would otherwise retry forever.
- **`max_queue_size` holds after a retry**, too: re-queued events that overflow it drop the oldest.
- **Types over heuristics.** A `Float` is always a double and an `Integer` always an int; the
  whole-number-is-int rule exists in sdk-node only because JavaScript has one number type.

And some are Ruby's own:

- **Encodings.** Property strings and keys are transcoded to UTF-8, with invalid bytes replaced by
  U+FFFD, since google-protobuf refuses invalid UTF-8. Ids aren't repaired — a mangled id is a
  different person — so an id that isn't valid UTF-8 drops the call.
- **Duration fields take seconds.** A number for a Duration field is seconds, Ruby's unit for time
  spans and what google-protobuf itself accepts; sdk-node refuses a bare number because
  JavaScript's convention is milliseconds. `{ seconds:, nanos: }` and `Google::Protobuf::Duration`
  work too.
- **Field names.** Well-known properties may be keyed by the proto field name (`product_id`) or
  the JSON name (`productId`), and go out under the JSON name; location keys likewise
  (`postal_code`/`postalCode`).
- **Blocking calls.** `identify` returns once the server answers, and `flush`/`close` wait, with an
  optional `timeout:` and a boolean result — the Ruby counterparts of awaiting sdk-node's promises.
  `track`'s `timestamp` option is a `Time`, not epoch milliseconds.
- **Forks.** A client created before a fork starts empty in the child, with its own sender thread
  and connections; the sender thread exits when idle and restarts on the next event, so an unused
  client holds no thread.
- **Timeouts.** `timeout` bounds each phase of a request (connect, write, read) and is sent as
  `Connect-Timeout-Ms`, so the server enforces the overall deadline; a streaming `list` is bounded
  as a whole.
- `profiles.delete` returns the `DeleteResponse` (erasure request id and status), as in sdk-go.

## Testing notes

- Tests run through the real validator over the real generated descriptors, so they exercise the
  actual validation contract.
- The batcher is driven through a fake sink; client tests stub the RPC layer, and
  `test/connect_test.rb` runs the SDK against an in-process HTTP server (`TestSupport::FakeServer`),
  covering the wire format, the API key header, streaming `list`, error mapping and timeouts.
- The never-raises contract is asserted through `TestSupport::LogCapture`, standing in for
  sdk-node's console spies.
- `test_accounts_for_every_event` checks under real concurrency that every event is delivered or
  dead-lettered exactly once; the fork test needs a platform with `fork`.

Before opening a PR: `make check`.
