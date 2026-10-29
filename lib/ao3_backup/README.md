# Magic Import work engine

M0 supplies the internal save contract; there is no content-save route. The Post
menu stays hidden until M2. UI authorization is opt-in with `AO3_BACKUP_ENABLED=true`
and comma-separated `AO3_BACKUP_OWNER_IDS`. The archival pseud is supplied explicitly
to the internal service and must belong to its owner. Disabling UI access never
removes durable model rules for already marked works.

## Host integration

- `config/application.rb` requires the engine before initialization, and excludes
  `lib/ao3_backup` from the host lib loader. The engine has an explicit root and
  its app directories belong to the main reloadable loader.
- `ChallengeSignupTagSummary` was moved unchanged to its own matching model file:
  the previous second top-level class survived unload and raised a superclass
  mismatch during development reload.
- `config/routes.rb` mounts the engine at `/backup_imports`.
- `Work` includes `Ao3Backup::ArchivalWork`; three metadata presence validations
  consult the built or persisted provenance association. Other validation remains
  unchanged. The concern's association autosaves durable provenance.
- Engine migration paths append to the host migration task; no migration copy is
  required. Run the deployment's normal `rails db:migrate` before using the feature.

## Save contract and callback audit

`CommitService` takes selected local values only. It builds provenance before
Work validation, creates approved work/chapter creatorships for the supplied local
pseud, and saves posted unrestricted chapters in one transaction. It never calls
source-author import/invitation setters. `User.current_user` is restored in ensure.
M0 supports empty optional metadata; selected-tag persistence and public commit UI
are M3 work.

Upstream callbacks are deliberately retained:

- `Searchable#enqueue_to_index` normally writes the Work's ID to Redis in after_save.
  The archival concern defers that specific publication using transaction-level
  after_commit callbacks, discarded on rollback. Standalone repair calls publish
  immediately; related-creatorship and deletion callbacks retain indexing. Provenance starts with durable `publication_state=pending`.
  Postcommit Redis errors are logged by error class and do not disguise a committed
  work as a failed import. M3 will own publication completion/retry UI.
- Work `expire_caches`, Chapter `invalidate_chapter_count`, and position updates
  invalidate cache keys before commit. A rollback can cause cache misses, but does
  not publish source content. Work queues refreshes for existing pseud/collection/
  series IDs before commit; workers read committed SQL and missing IDs are handled
  by upstream index sweepers. The final Work publication refreshes the final graph.
- Work `update_tag_index` and filter callbacks can queue tag/filter refreshes before
  commit when selected tags exist. M0 has no tags. These are reconciliation hints,
  not stored document payloads; M3 must verify selected-tag/index behavior with a
  committed transaction and actual search services.
- Creatorship `update_indices` and Chapter series indexing run after_commit.
- Normal creation/subscription notifications remain enabled. Subscription notices
  can enter Redis before SQL commit (`RedisMailQueue.queue_subscription`); this is
  existing upstream behavior accepted by the plan, not notification suppression.
  Mailer `deliver_after_commit` calls retain their normal timing.

## Isolated automated tests

Never run the host suite in `otwarchive-restore`: helpers flush Redis, clean SQL,
and delete search indexes. Use only the dedicated project and overlay:

```sh
docker compose -p otwarchive-magic-import-test -f docker-compose.yml -f docker-compose.magic-import-test.yml up -d --no-build test
docker compose -p otwarchive-magic-import-test -f docker-compose.yml -f docker-compose.magic-import-test.yml exec -T test bundle exec rails db:create db:schema:load db:migrate
docker compose -p otwarchive-magic-import-test -f docker-compose.yml -f docker-compose.magic-import-test.yml exec -T test bundle exec rspec spec/ao3_backup
```

The schema-load command is only for the initial fresh test database. Test services
use the new project's network and named volumes with no external restored volume.
Rails endpoints are database `db/otwarchive_test`, Redis `redis:6379`, Elasticsearch
`es:9200`, memcached `mc:11211`, all within that isolated network. The overlay uses
an existing Ruby 3.4/Rails dependency image; no test process runs in restore.

## M0 verification (2026-10-28)

The isolated Compose configuration was resolved before startup and checked for
project-prefixed volumes, no external volumes, no host service ports, and a
project-specific network. Rails runtime confirmed its test SQL/Redis endpoints.
Fresh isolated schema load plus host/engine migrations passed.

- `bundle exec rspec spec/ao3_backup/foundation_spec.rb`: focused graph, later-edit,
  ordinary validations, late chapter rollback, user-context restoration, route
  authorization, and actual commit/rollback Redis boundary proofs (fixture
  transactions disabled only in that context; cleaner strategy restored): **12 examples,
  0 failures**.
- `RAILS_ENV=development AO3_BACKUP_ENABLED=true bundle exec rails runner` with
  class identity comparison around `Rails.application.reloader.reload!`, followed
  by `Rails.application.eager_load!`: passed. A preexisting helper constant emits
  an already-initialized warning on reload; no engine constant conflicts occur.
- `AO3_BACKUP_ENABLED=false CI=true bundle exec rails runner` with full eager load
  and durable-hook assertion: passed (production-like loading in test environment).

All commands above run via the isolated project's `exec -T test`. No restore
container, restored volume, or restored archive SQL was changed. M0 is an internal
maintainer contract only; fetching/review/save UI remain later milestones.

## M1 contracts and acquisition diagnostic

The engine's services own version 1 manifests and selection payloads:
`SourceIdentity` normalizes only supported HTTPS AO3 work/chapter URLs;
`Provider` injects its HTTP client/clock and returns a frozen `CapturedPage` or a
coded `Error`; `Parser` returns plain values, separate chapter metadata/bodies,
optional source chapter IDs, full-work completion totals, and remote media URLs.
It uses the host `HtmlCleaner` sanitizer, resolves safe relative URLs, removes only
direct chapter landmarks, and rejects oversized text instead of truncating it.
`LocalTagResolver` performs read-only name queries under the database collation
and reports cross-type collisions without recategorization. `SelectionPolicy`
initializes author/existing/new order once and updates explicit choices without
reapplying defaults. Empty tag choices mean keep none. Proposed output deduplicates
tags while retaining their reviewed priority. Local title/language replacements
are explicit; language must exist locally and finite chapter totals cannot be
smaller than the published body count. Canonical rating/warning/category choices
must resolve locally before review accepts them.

The shared diagnostic now boots Rails for the existing sanitizer and engine
loader, but does not write any archive records or retain source HTML:

```sh
bundle exec rails runner script/docker/check_flaresolverr.rb 'https://archiveofourown.org/works/95623101'
```

`AO3_FLARESOLVERR_URL` is trusted server configuration, never a form parameter.
The adapter sends one stateless request (60-second solver timeout, 75-second read
and 5-second connect limits), streams an 8 MiB maximum API envelope, and accepts
at most 5 MiB HTML. It rejects browser-internal/cross-work final URLs. Errors
separate missing work, target forbidden/rate limit/TLS failure, solver HTTP/envelope/
verification/timeout failures, adult warning and malformed/truncated source layout.
Retry-After is available on typed errors; no automatic repeated fetch occurs.
M2 will expose explicit retry as a new generation. Cookies and solver messages
are never logged or copied into errors.

M1 deterministic checks use four small invented fixtures (1/1, 7/7, 2/?, 10/12),
with no source story prose. Parser/provider/policy specs cover missing/duplicate
bodies/IDs, chapter fraction inconsistencies, Unicode typed resolution, explicit
removals, unsupported URLs, challenge/adult pages and transport/size failures.

Two sequential opt-in live diagnostics passed on 2026-10-28 using only the new
`otwarchive-magic-import-test-flaresolverr-1` service:

- Source 95623101: `1/1`, one body, absent source chapter ID.
- Source 95493226 chapter URL: normalized whole work, `2/?`, source IDs 255079676
  and 255425746, expected typed tag counts.

Both ran via the isolated test container with `RAILS_ENV=development` and
`AO3_FLARESOLVERR_URL=http://flaresolverr:8191`; no restore service or database was
used. M2+ automated checks continue to use fixture-backed acquisition.

M1 focused automated command (isolated Compose `exec -T test`):
`bundle exec rspec spec/ao3_backup` passed **60 examples, 0 failures** before
the final heading-scope regression. The final focused core run
`bundle exec rspec spec/ao3_backup/core_spec.rb` passed **49 examples, 0 failures**;
the unchanged foundation suite had previously passed **12 examples, 0 failures**.
`git diff --check` passed. Acquisition diagnostics remain read-only developer
tools; the native inspector is M2, and content saving remains disabled until M3.

## M2 native review (saving disabled)

Authorized owners now have the third Post entry **Magic Import work**. Set
`AO3_BACKUP_ENABLED=true` and comma-separated `AO3_BACKUP_OWNER_IDS`; banned or
suspended accounts are denied. Every session read, edit, progress poll, retry,
dispatch recovery and cancellation checks the current owner through a scoped
lookup. Routes retain the host CSRF protection. There is no content-save route.

New integration details:

- The greeting partial adds one owner-visible link after Import Work.
- Engine controllers forward named host route helpers through `main_app`, without
  replacing the engine's `_routes` context. They use the host application layout.
- A tiny engine-only fandom menu partial performs read-only Media queries because
  upstream `Media.for_menu` can create an Uncategorized Fandoms tag on a fresh DB.
  It does not alter ordinary host menus or globally disable model callbacks.
- Explicit JSON attributes handle both native MySQL JSON and MariaDB's LONGTEXT
  JSON alias. Session and snapshot data live in separate additive tables.
- Selection request parameters are filtered. Engine metadata reads/writes use
  thread-local logger silence so source manifests and edited choices do not leak
  into SQL debug logs; model inspection also filters those attributes.

`SessionService` injects clock/dispatcher/policy. A new session durably starts
queued with dispatch intent before Redis is contacted. Failure stays visibly
queued and offers “Try dispatch again”. Fetch jobs use the existing `utilities`
queue with only session ID and generation. Each delivery claims queued → fetching
under a short lock, releases it before solver I/O, and accepts the result only if
state/generation/expiry still match. Duplicate deliveries and late generations
cannot overwrite cancellation, retry, expiry or a ready review. A snapshot is
immutable; selection revisions update separately under owner/revision/digest checks.
Retry creates a new generation and discards the old temporary review; at most
three generations are allowed per session, and Retry-After is honored with an
injected-clock timestamp. User.current_user is restored on every worker exit.

Review controls expose original values next to editable choices, including source
author/tag names after renaming. Category/search filters and select/clear-visible
controls operate on the same ordered list without discarding hidden choices.
Metadata removal requires explicit title/language replacements. Chapters retain
source order and bodies while title, summary and note selections remain editable.
The exact proposed output uses only retained local values and shows externally
hosted media, source completion and source word count as source context. The Save
button is disabled, with a prominent review-only notice.

Reviews expire 24 hours after creation. Access/worker expiry and cancellation
remove snapshots and editable choices. M4's scheduled sweeping and worker-death
lease recovery are deferred; an abandoned fetching generation can already be
explicitly retried/cancelled. M3 will add content saving/publication. No M3 work
is enabled by this UI.

M2 validation (all via isolated Compose `exec -T test`):

- `bundle exec rspec spec/ao3_backup`: **78 examples, 0 failures** before the final
  private-metadata SQL-log regression. Includes M0/M1 and native review requests.
- Chromium uses the existing `chrome` service, actual archive login, a real Redis
  `utilities` job and WebMock solver response. It observes queued/fetching/ready,
  filters/deselects fandoms, edits title/author, removes summary, applies a revision,
  checks no refetch, and verifies zero Work/Chapter/Tag/Tagging/Creatorship/Series writes.
- The browser fixture loads the normal archive skins and asserts their rendered
  font, then captures styled review areas at desktop and mobile sizes in
  `tmp/magic-import-review-{desktop,mobile}.png`.
- Request/worker proofs cover cross-owner denial, enabled CSRF rejection, malformed
  nested payloads, stale revision/digest, dispatch outage recovery, duplicate/stale
  jobs, cancel/expiry during fetch, immutable snapshots, explicit removals and
  rate-limit wait/retry boundaries. No automated source fetch uses the live solver.

For the optional isolated development preview, the same overlay supplies web port
3003, a separate PID file and a `utilities`-only worker command (no scheduler).
It uses `otwarchive_development` within the isolated project's DB and a separate
preview local configuration; tests continue to use `otwarchive_test`. Set
`MAGIC_IMPORT_PREVIEW_OWNER_IDS` when starting web/resque and append the optional
import sidecar overlay. Initialize only this fresh isolated development database
with the normal schema/migrations/skin setup. Never use the restored stack for
these setup commands. Avoid automated tests while operating the preview: the host
suite flushes the isolated project's shared Redis/cache even though its SQL
cleaner uses the separate test database.

Final focused M2 run after SQL-log privacy guard:
`bundle exec rspec spec/ao3_backup/review_spec.rb` — **17 examples, 0 failures**.

Independent M2 review found one final malformed-input gap: an omitted tag keep
boolean now returns a typed rejected edit. The final focused review suite passed
**18 examples, 0 failures**, including unchanged revision/digest/snapshot and zero
archive writes for that case. The full **78/78** run predates the private SQL-log
and omitted-keep regressions; both are included in the final focused **18/18**.
Production-like `CI=true` eager loading and host route-helper availability passed.
Independent milestone review approved M2; implementation pauses here for UI
inspection. No content-save endpoint or M3 behavior is enabled.

Start the initialized isolated preview (replace the owner ID if needed):

```sh
MAGIC_IMPORT_PREVIEW_OWNER_IDS=1 docker compose -p otwarchive-magic-import-test \
  -f docker-compose.yml -f docker-compose.magic-import-test.yml \
  -f docker-compose.import.yml up -d --no-build web resque
```

Open `http://localhost:3003/backup_imports` with the separately supplied local
preview account. Credentials are runtime-only and are not committed. The prepared
sample review uses invented fixture text; entering a real public work URL uses the
configured solver. Saving remains disabled for both.
