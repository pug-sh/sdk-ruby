# sdk-ruby developer tasks. Mirrors sdk-node / sdk-go proto vendoring: the gem carries its
# generated code (lib/pug/gen), so consumers just `gem install` with no Buf Schema Registry
# involvement.

.PHONY: sync-protos protos check-codegen proto-latest lint deadcode test build check ci

# `ci` must run `protos` before `check-codegen` diffs lib/pug/gen, and `protos` rewrites files the
# tests load. Keep everything serial even under `make -jN` so a parallel run can't race.
.NOTPARALLEL:

# BSR module + pinned commit that proto/ is vendored from. The pin makes `make sync-protos`
# reproducible and taking newer upstream protos a deliberate, reviewable change: builds and CI
# never touch BSR (proto/ + lib/pug/gen are committed). To bump: run `make proto-latest` for the
# newest commit, set PROTO_COMMIT below, then `make sync-protos && make protos` and review the diff.
PROTO_MODULE  := buf.build/pugsh/pug
PROTO_COMMIT  := 8b5d0680b10c4693b4d9d15d3dbfc663

# The Ruby generator is built into protoc, so only this exact protoc reproduces lib/pug/gen.
PROTOC_VERSION := 36.1

# Re-vendor proto/ from the pinned BSR commit. `buf export` is a read-only download; --path is an
# allowlist and buf pulls in transitive imports (buf/validate, google WKTs) automatically. Like
# sdk-node and sdk-go, this server SDK also vendors the shared/** services it reads from. Add a
# --path when the SDK starts consuming a new package.
sync-protos:
	@command -v buf >/dev/null || { echo "buf CLI required: https://buf.build/docs/installation"; exit 1; }
	rm -rf proto
	buf export $(PROTO_MODULE):$(PROTO_COMMIT) --output proto \
	  --path sdk \
	  --path common/events/v1 \
	  --path common/v1/property_value.proto \
	  --path shared/activity/v1 \
	  --path shared/insights/v1 \
	  --path shared/profiles/v1
	@echo "Synced SDK protos into proto/ at $(PROTO_COMMIT). Run 'make protos' to regenerate lib/pug/gen."

# Regenerate the committed Ruby code from the vendored proto/ mirror. If the well-known-event
# catalog changes, test/fixtures/well_known_events.golden fails the tests until it is reviewed
# and accepted with `UPDATE_GOLDEN=1 bundle exec rake test`.
protos:
	@command -v buf >/dev/null || { echo "buf CLI required: https://buf.build/docs/installation"; exit 1; }
	@protoc --version 2>/dev/null | grep -qx 'libprotoc $(PROTOC_VERSION)' \
	  || { echo "protoc $(PROTOC_VERSION) required, found: $$(protoc --version 2>&1)"; exit 1; }
	buf generate
	ruby scripts/relativize_requires.rb lib/pug/gen

# CI gate: the committed generated tree must match a fresh generate, new files included.
check-codegen:
	@test -z "$$(git status --porcelain -- lib/pug/gen)" \
	  || { git status --short -- lib/pug/gen; echo "codegen drift: run 'make protos' and commit"; exit 1; }

# Print the newest commit on the module's main branch, to update PROTO_COMMIT above.
proto-latest:
	@buf registry module commit resolve $(PROTO_MODULE):main

lint:
	bundle exec rubocop

# Fails on any method that nothing in lib or test calls. debride itself always exits 0, so the
# target checks its report's total instead.
deadcode:
	bundle exec debride --whitelist .debride_whitelist --exclude lib/pug/gen lib test \
	  | tee /dev/stderr | grep -qx 'Total suspect LOC: 0'

test:
	bundle exec rake test

build:
	gem build pug-sh.gemspec

check: lint deadcode test build

# Strict CI target: regenerate protobufs from scratch, then run every check.
ci: protos check-codegen check
