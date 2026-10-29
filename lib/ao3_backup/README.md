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
