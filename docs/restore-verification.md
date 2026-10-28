# Older hosted development instance: restore verification

The local `backup/ao3_db_vol_20250501.tar` archive was restored into a new volume,
`otwarchive-restore_my-datavolume`. Its InnoDB redo header identifies MariaDB
10.5.4, matching the `mariadb:10.5.4-focal` image used to open it. The archive
contains `var/lib/mysql/`, not a SQL dump. The original archive and the original
`otwarchive_*` volumes were not modified. Backups are excluded from Git and
Docker build contexts.

Archive SHA-256:
`8e0304755efdf66e10f6f443593694e727e084fd93b35f572a3a26903d834b23`

## Result

The restored application is running at <http://localhost:3002> in development
mode. A separate fixture sandbox remains at <http://localhost:3001>.

The old database had migrations through `20220519071139`. All 64 pending schema
migrations passed, ending at `20260728014110` (137 recorded migrations total).
Record counts were unchanged immediately after migration:

| Records | Before | After migrations |
| --- | ---: | ---: |
| Users | 1 | 1 |
| Works | 522 | 522 |
| Chapters | 1,054 | 1,054 |
| Series | 15 | 15 |
| Tags | 1,046 | 1,046 |

Ran the current `After:add_canonical_email`, `After:sync_approved_to_spam` and
`After:add_collection_tags` data tasks, refreshed site skins, and rebuilt the
work, tag, pseud, bookmark, user and collection search indices. No database
reset, fixture seed or `db:otwseed` was run on this restored instance.

HTTP checks passed for:

- Login with a separate, newly created `restorecheck` account.
- Opening an imported work and an imported series.
- Finding an imported work through title search.
- Posting a new work with a new series.
- Editing work tags, title and chapter content.
- Editing the series title/description and retaining its work membership.
- Finding the newly edited work through search.

Temporary test additions remain for inspection: work `/works/523`, series
`/series/16`, and user `restorecheck`. Final counts include one added user,
work, chapter and series, plus three new tag records. The original user's
password was not changed; logging in with that user's actual password remains
a manual check. The temporary account has a generated password retained only
in `/tmp/otwarchive-restore-account.log` on the WSL host.

The skin refresh exposed an ActiveStorage save-order bug: attaching a preview
to an unchanged, persisted site skin performed a validated save before the
maintenance task's explicit unvalidated save. With no logged-in user, this
failed the reserved-title check. Assigning the attachment and saving together
fixes it. Running the loader twice without a logged-in user passed afterward.

One indexing job was interrupted by our development-process restart; it was
requeued successfully. At verification completion, failed jobs and the pending
high-priority indexing queue were both zero.

## Manage the restored copy

Run from the repository directory in Ubuntu or PowerShell:

```sh
# Start the migrated copy with the existing application images:
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml up -d --no-build web

# Logs:
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml logs -f web resque

# Stop while retaining data:
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml stop
```

The restore overlay references the manually populated database volume as an
external volume, uses fresh Redis/search volumes, and binds only localhost
port 3002. Mailer jobs are excluded from its worker queues and SMTP points at
an unused loopback port. Old Redis queues were not imported. Use this exact
project/configuration combination; plain `docker compose up` targets the old
project instead.

This is database and core-authoring verification, not a full release-by-release
migration certification. Historical `After:` tasks removed from current code
have not been exhaustively audited. The archive does not supply the separate
uploaded images/files that may have existed on the old host. PDF conversion,
email delivery, global tag wrangling and admin flows were outside the requested
checks.
