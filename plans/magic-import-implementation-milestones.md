# Magic Import work: build order, test boundaries, and usable milestones

**Current retention override:** Keep cached snapshots indefinitely, including after completion, cancellation, or retry. Only explicit deletion removes them. No automatic expiry or cleanup until the owner changes this instruction. Earlier expiry/cleanup requirements below are superseded.

This is the execution sequence for [the feature plan](ao3-selective-backup-import.md).
That plan remains the source of product requirements and verified AO3 examples.
Each milestone below has an observable capability and a completion gate. These
are staged releases of the same implementation, not separate prototype importers.

## Assessment of the current plan

The requirements and four verified layouts are enough to start. The current
sequence still groups too much work into “build the engine” and postpones the
riskiest integration questions until persistence. Adjust it in four ways:

1. Prove engine boot/reloading and a minimal Rails save contract early. Optional
   rating/warning/fandom validation, archival-marker save order, chapter posting,
   and indexing behavior affect the design of the reviewed payload.
2. Deliver a useful read-only inspector before enabling saves. This exercises
   real acquisition, account authorization, existing-tag matching, and review UX
   without creating content or unwanted tags.
3. Treat the first saving milestone as a complete vertical slice: chosen metadata,
   local ownership, author-first display, anonymous reading, and indexing. A work
   saved with the wrong defaults or visible only to its author is not a usable
   version of the requested feature.
4. Separate deterministic automated tests from opt-in live acquisition checks.
   Upstream AO3 changes and Cloudflare availability must not determine CI results.

Concrete gaps found in the checkout:

- `script/docker/check_flaresolverr.rb` currently accepts multipart markup only;
  it rejects the verified `1/1` layout. The service being healthy is not evidence
  that every supported work layout can import.
- Some indexing calls write Redis in save callbacks. Database rollback does not
  undo those writes; identify which cache/index effects require deferral or safe
  reconciliation. Normal work/chapter notifications are acceptable for this
  one-or-two-user instance. Notification suppression is deferred and is not a
  prerequisite for any milestone; do not add special notification controls now.
- The restore worker subscribes to an explicit queue list. A newly named import
  queue will not run unless configuration includes it. Use the existing
  `utilities` queue initially, or add and test an explicit `ao3_imports` queue.
  Pick one before the first background-fetch UI; do not create a second worker
  framework or assume an enqueued job has executed.
- `config/application.rb` autoloads `lib`. A nested engine needs an intentional
  boot/eager-load arrangement to avoid Rails and engine loaders both owning its
  files. Verify that arrangement before building the rest of the engine.

## Milestone map

| Milestone | Usable result | Must pass before proceeding |
| --- | --- | --- |
| M0: integration foundation | Maintainer can boot the extension and exercise the save contract in an isolated test project | Engine loading, scoped model rules, callback audit, infrastructure isolation |
| M1: inspect a work | Maintainer can fetch/parse any of the four supported shapes and see a manifest summary | Parser contract and transport error tests; single-chapter smoke support |
| M2: review in the archive | Owner can use Post → Magic Import work to fetch, edit, and review exact selections; no work is saved | Session/job lifecycle, authorization, review defaults, zero content/tag writes |
| M3: first complete import | Owner can commit the reviewed work and read/find the correctly tagged local copy | Atomic save, duplicate handling, unrestricted reading, stable tag order, real indexing |
| M4: routine use and release | Import survives retries, competing requests, worker restarts, expiration, and ordinary local edits | Recovery/concurrency tests, cleanup, upstream regressions, restore-stack acceptance |

Dependencies are `M0 → M1 → M2 → M3 → M4`. Within M0, the model-contract proof
and parser data definitions can be developed in either order, but settle the
shared contracts before the review UI. Do not expand the architecture to support
bulk import, automatic source updates, browser extensions, mirrored media, or
named presets in these milestones.

## M0: integration foundation and early risk proof

Create the smallest namespaced engine entry point, an authenticated route, and
an additive migration skeleton. Keep the Post menu link hidden until M2 has a
working entry screen. Prove development reload, test loading, and production-like
eager loading with the extension enabled; verify the host still boots when its UI
is disabled. Document each host integration hook as it is added.

Before a polished UI, use invented manifests in isolated model/service specs to
prove the minimal import save path: durable import marker built before validation,
archival-account work/chapter creatorships, empty fandom/rating/warning categories,
two posted chapters with unknown total, and an ordinary non-imported work that
still requires its normal metadata. The marker needs to exist on the in-memory
association before the Work is validated; do not depend only on a persisted
association query. Verify a reload and later edit preserve the intended rules.

Inventory Redis/index side effects on that path; never globally remove callbacks
or disable validation. Leave normal notification behavior in place. Always
restore `User.current_user` after a job/service call, including exceptions, so a
reused worker cannot leak the archival account into another task.

**Gate:** the proof demonstrates a valid saved object graph and a later-chapter
failure rolls back all SQL records. No source-author invitation path is used;
normal subscription notifications are allowed. Identify
precommit cache/index writes explicitly; defer irreversible publication until
commit, and make remaining harmless invalidation/reindex effects safe on rollback.
Do not promise that all existing upstream callbacks are automatically after-commit.

## M1: deterministic core and a real acquisition diagnostic

Define small value contracts, owned by the engine:

| Boundary | Input → output | Responsibility |
| --- | --- | --- |
| Source identity | URL → normalized source host/work ID | Chapter URL normalization, supported host/path validation |
| Acquisition provider | Source identity → captured page or typed error | Solver envelope/status/final URL, timeouts, response limits; no model writes |
| Parser | Captured page → versioned manifest | Work/scalar values, typed tag candidates, chapter bodies/order, optional source chapter IDs, published/final totals |
| Local tag resolver | Typed names → resolved candidates | Read-only local IDs, type/conflict status, no tag creation |
| Selection policy | Manifest + resolved candidates + explicit choices → reviewed import payload | Defaults only on first review, user edits/removals, stable order, required local replacements |
| Commit service | Reviewed payload + operation identity → saved work/result | Only component allowed to create archive content/tags |

Inject the fetch client, clock, resolver, and job dispatch boundary where relevant;
avoid globals or controllers hiding those dependencies. Include manifest/payload
schema versions. Keep source chapter identity separate from local position, and
fetched source values separate from edited output. Returning an explicit empty
selection is different from no review choice having been made.

Build synthetic, small HTML fixtures with invented prose matching:

- `1/1`: direct `#chapters > .userstuff`, no source chapter ID/status date.
- `7/7`: seven bodies, six separate chapter summaries, Completed date label.
- `2/?`: two published bodies, unknown expected total, chapter ending notes.
- `10/12`: ten bodies, nine chapter summaries, separate note locations, two
  Unicode fandom names independently resolved, Updated date label.

Add rejected variants for missing/duplicate bodies/IDs, inconsistent fractions,
warning/challenge pages, and solver `ok` with browser-internal final URL. Preserve
the unwrapped one-chapter case without requiring an extra fetch just for an ID.
Do not duplicate parser logic in the smoke script: extract reusable parsing and
validation, then have the script call it. The diagnostic must stay read-only.

**Gate:** all four layouts produce the correct manifest under deterministic
tests; FlareSolverr errors are actionable typed results; the diagnostic can
inspect a single or multipart work. Run only the live cases needed to verify the
adapter, sequentially. Later milestones use fixture-backed responses by default.

## M2: usable native review, with saves disabled

Ship the third Post menu option with the exact label **Magic Import work** once
URL entry, progress, errors, and review are functional. The page can clearly say
that saving is not yet enabled in this milestone. This is a useful inspector,
not a fake successful import. Use the existing archive layout and authentication.

Add only the session/snapshot storage needed now. Fetch in the selected existing
Resque queue. Store ownership, normalized source identity, immutable snapshot
digest, lifecycle state, expiration, and an editable selection revision. Queue
session IDs, not full HTML. Save selection revisions separately from the immutable
source snapshot so editing remains possible without refetching.

The owner can remove/edit scalar metadata and tags, inspect chapter structure,
and see the exact proposed output. Pin the selected author tag first, existing
local candidates next and selected, new candidates last and unselected; override
existing-tag defaults for ratings/warnings. Show collisions and required local
title/language replacements without silently retaining removed source values.

Define state transitions now: `queued → fetching → ready` or `fetch_failed`;
`ready → expired/cancelled`. M3 extends `ready → committing → completed` or
`commit_failed`. Retry fetch explicitly creates a new generation; a late job may
not overwrite a newer generation, cancellation, or completed state. Capture time
and expiration tests use an injected clock. Do not hold SQL locks during a solver
request. Persist job dispatch intent/recoverable queued state so a Redis dispatch
failure does not strand a session while the UI claims it is fetching.

**Gate:** request/worker tests prove ownership/CSRF checks, rejected edits, retry
and expiration behavior, defaults, and manual deselections surviving filter/edit
round trips. A browser test uses a stubbed solver to exercise actual progress and
review controls. Preview may write session records, but never Work, Chapter, Tag,
Tagging, Creatorship, or Series records. No import model setters in preview.

## M3: first complete import through the reviewed UI

Enable commit only after its integration tests pass. Reuse the M0 save path;
do not create a second persistence implementation. Under a short transaction,
lock/check the session, validate its owner, revision/digest/expiration, and resolve
the final selections. Create the graph and unique provenance atomically, then
mark the operation completed with its work ID. Concurrent saves of one source
must converge on one result through a database unique constraint, not just a
preflight URL lookup. Handle conflicts by loading/linking the existing result
after the losing transaction has rolled back.

Saving does not fetch again or reapply defaults. Excluded values must be absent
from tags/taggings and durable original-metadata blobs. Resolve any new local
tag conflict explicitly rather than silently substituting a different type/name.
If local catalog changes invalidate the reviewed result, return to review with
the user's choices preserved; do not silently reorder/reselect tags.

At this milestone the whole loop works: URL → review/edit → commit → local work.
Author-first order must appear both on the work and normal work listings. Save
posted, unrestricted content and omit unchecked ratings/warnings without adult
interstitials. Verify fresh anonymous work/chapter/entire-work requests: the
importing account already bypasses the adult gate and cannot prove this behavior.

Index the committed graph and expose pending/failed indexing separately from
import failure. If SQL commit succeeded but Redis/index dispatch failed, show the
saved work and retry publication for that same work; never reimport it. Keep a
durable pending-publication state or equivalent repair mechanism. A thin UI may
wait for the short commit, or enqueue it using the same operation identity; neither
approach should hold a request open for source fetching.

**Gate:** database integration tests cover the default import, explicit retained
rating/warnings, zero optional tags, edited values, late-chapter rollback, duplicate
commit, and subsequent local edit/re-save. Use real model callbacks. Separately
verify actual search indexing/filtering and a small browser workflow with a
stubbed solver. Exactly one controlled restore-stack import then proves the full
path using the real solver; this is an authorized feature operation, not an
automatic cleanup/reset of the historical restored archive.

## M4: recovery, routine use, and upstream compatibility

Exercise double-clicks and competing sessions for the same source with separate
database connections; transactional single-connection specs cannot prove a race.
Cover worker death before/after fetch completion, a duplicate queue delivery,
cancel during fetch, expired review, stale selection revision, lost commit HTTP
response, and indexing outage after a successful SQL commit. Do not blindly retry
unknown-commit outcomes; first look up the operation's persisted result.

Use expiring leases/generation checks for in-flight work and a bounded repair
path for abandoned queued/committing states. Cleanup deletes temporary source
HTML/manifests after completion, cancellation, or TTL; it must not delete imported
works, durable source identity, or another active generation. Ensure excluded
source fields do not survive in session backups/logs longer than the documented
retention. A live acquisition failure must leave a useful retryable session.

Test display-order reconciliation after tag edits/deletions, archived work edits
with empty optional metadata, query count on imported
work listings, and ordinary work validation/visibility/old import flows. Upstream
test coverage should focus on the touched seams, rather than rerunning every
unrelated subsystem for each small change. Prove eager loading and the documented
Compose/migration/worker commands once the implementation is stable.

**Gate:** focused deterministic suites pass, one committed indexing scenario
passes with real Redis/search, the isolated concurrency test passes, and a manual
restore acceptance report identifies the newly added work IDs and any transient
records. Document recovery and feature-disable procedures. Disabling new imports
must leave already imported works readable/editable with their durable optional
metadata rules; it must not disable the archival-marker model hooks.

## Test environment and acceptance evidence

Use the repository's RSpec (`spec/spec_helper.rb`), WebMock, factories, and existing
Cucumber/Capybara conventions; do not invent a parallel engine test application
or assertion framework. Keep engine domain code together, with host-integration
specs in the host suite where its helpers and indexing setup already work.

**Do not run the automated suites inside `otwarchive-restore`.** This checkout's
spec helper calls Redis `FLUSHALL`, DatabaseCleaner, and search-index cleanup.
`config/docker/redis.yml` points development and test to the same service address;
separate Redis database numbers alone cannot protect against `FLUSHALL`. Use a
dedicated Compose project, e.g. `otwarchive-magic-import-test`, with its own DB,
Redis, search, and cache services, and no restore overlay/external restored volume.
Confirm its resolved database/service endpoints before the first suite run.

| Layer | Evidence | External dependencies |
| --- | --- | --- |
| Parser/policy | Exact values, nullable IDs, category defaults/order, edit/removal semantics | Synthetic inputs; no network; no tag writes |
| Provider | Request contract and every envelope/status/timeout/interstitial branch | WebMock; live solver only in opt-in smoke |
| Resolver/save | Read-only matching, valid graphs, omission, rollback, later edits | Isolated SQL; capture queue effects where appropriate |
| Session/HTTP/jobs | Owner/revision/state checks, durable result, stale-job handling | Controlled clock/client/job dispatch; isolated Redis for job integration |
| Display/browser | Real controls, anonymous reading, author-first listings | Stubbed source, host views, isolated browser/test services |
| Commit/publication | Real index callbacks and eventual searchable work | Actual transaction commits and isolated Redis/search; ordinary test mail isolation |
| Concurrency | One work for simultaneous source commits | Separate DB connections/processes, committed fixtures, isolated cleanup |
| Live restore acceptance | Real solver → reviewed choices → saved/readable/searchable result | Existing restored stack; specific new records only; no suite cleanup |

The host suite normally wraps tests in transactions. Use a narrowly tagged,
isolated committed-transaction setup for after-commit/Redis and concurrency cases;
ensure DatabaseCleaner strategy is restored afterward. A rollback-only spec with
all callbacks mocked is insufficient evidence for these two boundaries.

For each milestone, record the focused command run, pass/fail result, the usable
capability, and remaining limits. M0/M1 artifacts are developer tools; M2 is the
first user-facing result; M3 is the first usable importer; M4 is readiness for
routine use. Do not label the entire feature complete at the read-only milestone.
