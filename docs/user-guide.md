# User guide

This guide collects operating notes for the self-hosted archive. Run the Docker
commands from the repository directory. The examples below use the **restored
copy** at `http://localhost:3002`, with its dedicated project and overlays.
Other installations need their own project name and Compose files.

## Restore an older hosted archive onto a fresh server

Yes: clone this fork's updated branch, restore a **copy** of the old database,
and run the incremental migrations and data/index updates below. This brings
the supplied backup to the state we tested. Cloning the repository alone does
not restore data or run migrations.

These instructions reproduce the restore of `ao3_db_vol_20250501.tar`: a raw
MariaDB **10.5.4** data-directory archive with paths starting `var/lib/mysql/`.
Its development schema dated from May 2022. The archive filename dates from
May 2025. Do not use these extraction commands for a SQL dump, another archive
layout, or a data directory from a different database version. See
[restore verification](restore-verification.md) for counts, checksum and test
results. Historical release-specific data tasks have not been exhaustively
audited; the tested result covers the core archive and authoring operations.

### 1. Prepare Docker and clone the updated branch

Use Docker with Linux containers and a Compose version supporting `!reset` and
`!override` (the tested version is Compose 2.35.1). On Windows, enable Docker
Desktop integration for Ubuntu. The commands in this restore section use
**Bash in Ubuntu/WSL or Linux**; they are not PowerShell syntax. Ruby and
Bundler run inside the image, so no matching host Ruby installation is needed.

```sh
docker version
docker compose version
git clone --branch master https://github.com/pxtang/otwarchive.git
cd otwarchive
mkdir -p backup
```

The fork's default branch is `master` and includes the tested restore changes.
The integration history is also retained on
`codex/upstream-refresh-2026-10-26`. Keep this checkout on the server: the app
containers mount and run its files.

Copy the original backup to `backup/ao3_db_vol_20250501.tar` in the new checkout.
Keep an independent original elsewhere. `backup/` is excluded from Git and
Docker builds. Check the copied file:

```sh
sha256sum backup/ao3_db_vol_20250501.tar
tar -tf backup/ao3_db_vol_20250501.tar | head -20
```

For this specific supplied backup, the expected SHA-256 is
`8e0304755efdf66e10f6f443593694e727e084fd93b35f572a3a26903d834b23`.

### 2. Set the restored instance's configuration

Review these files before starting services:

| File | Settings to check |
| --- | --- |
| `config/docker/database.yml` | Development database `otwarchive_development`, host `db`, and the old database's actual root password |
| `docker-compose.yml` | `MYSQL_ROOT_PASSWORD` matching that password; retain `mariadb:10.5.4-focal` for this raw backup |
| `config/docker/restore-local.yml` | Localhost URLs for the initial test, internal service addresses, and any settings from the old host |
| `config/docker/redis.yml` | Development entries pointing at `redis:6379` |

**The database archive includes its existing accounts and passwords.**
`MYSQL_ROOT_PASSWORD` initializes an empty database; it does not change the
password in a restored data directory. If access fails, check the old password
before attempting migrations. The password edits on the current workstation
are local, uncommitted changes and will not arrive in a fresh clone.

Merge any old host-specific settings into `restore-local.yml` rather than
replacing it wholesale: retain `ES_URL: es:9200` and
`MEMCACHED_SERVERS: mc:11211`. Preserve existing session/encryption keys where
applicable. The restore overlay mounts the Docker database/Redis templates and
`restore-local.yml` into the application's configuration paths; unrelated
`config/local.yml` files are not used by this restored instance. Keep local
credentials out of commits.

This configuration runs Rails in **development**, as the old hosted instance
did. Email is disabled operationally: SMTP points at an unused loopback port,
and the worker excludes the mailer queue. This procedure does not set up email.

Define a shortcut for this terminal session so every command selects the same
project and all three configuration files:

```sh
dc() {
  docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml "$@"
}
dc --profile dev --profile manual config --quiet
dc build web resque
```

Although one overlay is named `sandbox`, using it here does **not** populate
fixture data. It removes dependency host ports and supplies configuration
mounts. The restore overlay selects port 3002 and the restored database volume.
The database volume name is explicitly fixed to
`otwarchive-restore_my-datavolume`: changing `-p` alone does not select another
database volume.

### 3. Extract into a new, empty volume

Do this **once**, before starting the database. The block refuses to extract if
that volume already exists. If it prints STOP, inspect the existing volume;
do not delete or overwrite it just to continue. In particular, do not run this
initial-restore step against the already working copy on this workstation.

```sh
if docker volume inspect otwarchive-restore_my-datavolume >/dev/null 2>&1; then
  echo 'STOP: restore volume already exists; inspect it before proceeding.'
else
  docker volume create otwarchive-restore_my-datavolume &&
  docker run --rm --network none \
    --mount "type=bind,src=$PWD/backup,dst=/backup,readonly" \
    --mount type=volume,src=otwarchive-restore_my-datavolume,dst=/restore \
    mariadb:10.5.4-focal \
    tar -xpf /backup/ao3_db_vol_20250501.tar --strip-components=3 -C /restore
fi
```

The three stripped components are `var/lib/mysql`. The original tar file is
mounted read-only. The restore Compose file treats this manually populated
volume as external; Redis and Elasticsearch get separate fresh volumes.
Do not attach the old Elasticsearch 7 volume to Elasticsearch 9.

### 4. Start dependencies and check the old database

```sh
dc up -d db redis es mc
dc logs --tail=40 db es

# This must authenticate and print a MariaDB version before proceeding:
dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "SELECT VERSION();"'

# Retry after startup if Elasticsearch is not yet ready:
dc exec -T es curl -fsS http://localhost:9200/_cluster/health
```

A single-node Elasticsearch cluster can report yellow because replicas have
no second node; red or an unavailable service needs investigation.

Record database counts before changing its schema:

```sh
dc exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N otwarchive_development -e "SELECT MAX(version),COUNT(*) FROM schema_migrations; SELECT (SELECT COUNT(*) FROM users) AS users,(SELECT COUNT(*) FROM works) AS works,(SELECT COUNT(*) FROM chapters) AS chapters,(SELECT COUNT(*) FROM series) AS series,(SELECT COUNT(*) FROM tags) AS tags;"'
```

For the supplied original backup, the counts are **1 user, 522 works, 1,054
chapters, 15 series and 1,046 tags**, with latest migration `20220519071139`.

### 5. Migrate existing data, refresh skins and rebuild search

Run these in order, and stop to investigate if a command fails:

```sh
# Incremental schema changes only; no database reset or fixture seed:
dc run --rm --no-deps web bundle exec rake db:migrate

# Backfills used in the tested restore:
dc run --rm --no-deps web bundle exec rake After:add_canonical_email After:sync_approved_to_spam After:add_collection_tags

# Refresh the site skin definitions from the updated code:
dc run --rm --no-deps web bundle exec rake skins:load_site_skins

# Build fresh search indices and enqueue the existing records:
dc run --rm --no-deps web bundle exec rake search:index_tags search:index_works search:index_pseuds search:index_bookmarks search:index_admin_users search:index_collections search:run_world_index_queue

# Dependencies are already running. Start the app and worker explicitly:
dc up -d --no-deps web resque
dc logs -f web resque
```

The worker must finish indexing before search results are complete. Ctrl+C
stops following logs without stopping containers. On the tested code, 64
pending migrations passed, ending at `20260728014110`. Counts immediately
after migration matched the original counts above. Rerun the count query to
confirm this before adding test data; a future fork revision may have more
migrations.

**Do not run the fresh-install init/reset scripts on a restored database.**
This includes `script/docker/init.sh`, `script/docker/init.cmd`,
`script/reset_database.sh`, `db:reset*`, `db:schema:load`, and `db:otwseed`.
Those commands can replace the restored data. Avoid `down -v`; retain all
restore volumes until the new instance and its backup plan are verified.

### 6. Verify and begin using the restored copy

Open <http://localhost:3002> on the server. It binds to server loopback only.
To inspect a remote Linux server without changing that binding, run this on
your own computer and keep it open:

```sh
ssh -L 3002:127.0.0.1:3002 your-user@your-server
```

Then browse <http://localhost:3002> on your computer. For ongoing hosting through
a domain, configure your reverse proxy and update `APP_HOST`, `APP_URL` and
`PERMITTED_HOSTS` in `restore-local.yml` for that address, then restart the app
processes. The sample configuration is an initial local verification setup,
not an automatic domain/proxy installation.

Verify the basics before switching from the old hosted instance:

- Log in with your original account; its password is preserved.
- Open existing works, chapters and series, and find an existing work in search.
- Post a disposable work, edit its tags/title/chapter text, create a series,
  and edit that series. Check the changes after a fresh request.
- Let background indexing catch up, then find the new work in search.

Check failures and indexing backlog:

```sh
dc exec -T redis redis-cli llen resque:failed
dc exec -T redis redis-cli llen resque:queue:reindex_world
dc exec -T redis redis-cli llen resque:queue:reindex_high
```

Queue lengths exclude jobs already being processed. A zero queue length alone
does not prove success; check failed jobs and actual search results too.
The verification account/work/series from our local test were created after
restoration and are **not** in the original backup or a fresh restore.

The tar contains database files, including work/chapter text. It does not
include the old host's separate uploaded images/files or its local configuration.
Keep those backups as well; older attachment formats can need additional
migration work. Database restoration alone cannot recreate missing media.

### Starting again after a restart, and later code updates

Once restored, do not repeat extraction or initialization. Define `dc` again
in a new terminal, then use:

```sh
dc up -d --no-deps db redis es mc web resque

# Stop the stack without deleting its volumes:
dc stop
```

For a later fork update, back up the working database and media first. Stop
web/Resque while upgrading, retain Redis and database volumes, pull the desired
code revision, rebuild images, review that revision's migrations/data tasks,
and run the required incremental migrations before restarting. Do not blindly
reapply historical data backfills or recreate indices on every startup. The
original tar is a rollback source for the original data, not a backup of changes
made after restoration. Restart both web and Resque after code changes so old
development-mode class definitions are not retained.

## Running background jobs manually

The `resque` service runs a worker and a scheduler. The worker processes queued
jobs; the scheduler periodically adds jobs for search updates, tag and filter
counts, statistics, and other maintenance. You can stop the service to save
memory and start it when you want jobs processed:

```sh
# Stop the worker and scheduler; leave the website and its data running.
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml stop resque

# Start them again when you want background jobs processed.
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml up -d resque

# Check status and follow the worker's output.
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml ps
docker compose -p otwarchive-restore -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml logs -f resque
```

Press Ctrl+C to stop following the logs; this does not stop the service. Leave
the worker running long enough to process the queued jobs and scheduled updates;
the logs alone do not guarantee that every queue is empty or every job succeeded.
Stopping during a job can interrupt it, so avoid stopping during active work.

While the service is stopped, queued jobs wait in Redis and search results,
tag/filter counts, statistics, and other background features can become stale.
Scheduled jobs are not being added during that time; do not assume every missed
run will be replayed immediately when it restarts. Keep Redis running and its
data intact. The restore configuration deliberately excludes mail queues from
its worker, so starting this service does not enable email processing.

Resque is in the `manual` Compose profile and is not a dependency of `web`.
Starting `web` alone therefore does not start Resque. Explicitly naming
`resque` starts it; enabling the `manual` profile also includes it. Starting
the website does not stop an already running worker. For automatic updates,
leave Resque running.

Docker Desktop can start individual existing containers, including Resque,
regardless of this Compose profile. Starting a whole application from its UI
may also start an existing stopped Resque container, depending on the action;
check its status afterward. Compose configuration changes take effect when you
use `docker compose up` with the appropriate files, rather than merely starting
an existing container in the UI. The restore project needs all three files in
the commands above; a plain Compose command targets a different project.

## Memcached

The `mc` container is a temporary cache, separate from Redis and the database.
The restored development configuration points to it, but Rails uses a null
cache unless `tmp/caching-dev.txt` exists when the processes start. Creating
that toggle affects development projects sharing this checkout; restart both
web and Resque to apply a change consistently. Some features use the cache for
temporary data, so a null cache can affect more than performance. Cached data
can also disappear when Memcached restarts or evicts entries.

On the restored copy, an idle snapshot showed Memcached at about 1.7 MiB and
0.01% CPU, while Resque used about 483 MiB and 0.11% CPU. These are snapshots,
not limits or guarantees; active jobs and traffic can use more. Memcached's
usual default cache allocation limit is 64 MiB, plus process overhead; actual
usage grows with stored data. Check the current containers with:

```sh
docker stats --no-stream otwarchive-restore-mc-1 otwarchive-restore-resque-1
```
