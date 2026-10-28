# Media server upstream refresh

Upstream `otwcode/otwarchive` master was merged through `aa99cd45c`
(AO3-7619 Update css_parser to 3.2.0). The pre-merge commit is preserved on
`codex/backup-before-upstream-2026-10-26`; integration work is on
`codex/upstream-refresh-2026-10-26`. The merge was pushed to that branch on
the fork; master was left unchanged.

## Merge decisions

- Keep the homepage without AO3 social links.
- Keep the development ribbon and Bullet disabled, the existing eager-loading
  and caching settings, and support for the media server hostname.
- Incorporate upstream's generator and Codespaces settings.
- Keep the TOS popup disabled. Replace the old HTML-commented JavaScript
  callback (which left invalid JavaScript) with an ERB comment.
- Retain the custom tag ordering and Resque scripts.
- Restore the pre-existing local Docker password and production database-name
  edits as uncommitted changes. The login file is untouched and untracked.

## Runtime and validation

The upstream Dockerfile, Gemfile and lockfile now require Ruby 3.4.12 and
Bundler 2.6.9. Compose uses MariaDB 10.5.4, Redis 7, Elasticsearch 9.3.0 and
Memcached 1.5. Keep the Dockerfile and locked dependencies together.

Ruby syntax for the development settings, shell syntax for the Docker and
custom Resque scripts, YAML structure, service references and runtime-version
consistency were checked locally. The fork-specific changes pass Git's
whitespace check. Upstream itself contains whitespace warnings.

Docker Desktop WSL integration is now enabled. The application image built
successfully using the locked dependencies. A fresh sandbox database was
created from the schema, migrated, seeded with fixtures, and indexed. Puma,
Resque and its scheduler are running. HTTP checks passed for the homepage,
CSS/JavaScript, work browsing and reading, work and tag search, collections,
login and the authenticated profile. Worker failure count was zero after setup.
This verifies a fresh installation, not compatibility with the older hosted
instance's backup. No existing archive volume was mounted by the sandbox.
The older hosted backup was subsequently tested in another isolated project;
see [restore verification](restore-verification.md) for results and commands.

The first boot exposed a Codespaces configuration bug: Compose supplies an
empty `CODESPACES` variable, which Ruby treats as truthy. That added an invalid
hostname restriction. Development settings now require a nonblank value before
applying Codespaces settings.

## Running the fresh sandbox

Open <http://localhost:3001>. The sandbox uses project name `otwarchive-sandbox`
and the additional `docker-compose.sandbox.yml` file. Its dependencies expose
no host ports; the web port binds to localhost only. Its configuration mounts
use the Docker templates plus `config/docker/sandbox-local.yml`, leaving the
existing local configuration files alone. Database, Redis and Elasticsearch
volumes have the `otwarchive-sandbox_` prefix.

Fixture account: username `testuser`, password `testuser`. Login works, but the
application warns that this fixture password is breached and opens the password
change page. Choose a unique password if you keep using the account.

Run these commands from the repository directory in Ubuntu or PowerShell:

```sh
# Start the already initialized sandbox:
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml up -d --build web

# View logs:
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml logs -f web resque

# Stop the sandbox while retaining its data:
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml stop
```

Only for initializing an EMPTY, disposable sandbox database (this resets data):

```sh
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml build web resque
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml up -d db redis es mc
# Wait for MariaDB and Elasticsearch to be ready, then:
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml run --rm --no-deps web script/reset_database.sh
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml up -d web
docker compose -p otwarchive-sandbox -f docker-compose.yml -f docker-compose.sandbox.yml exec web bundle exec rake search:run_world_index_queue
```

Continue using the sandbox project name and both Compose files. A plain
`docker compose up` targets the original project and its existing volumes.
The checkout and generated files under it are shared between projects; keep
the old web/worker containers stopped while testing this upgraded checkout.

## Existing volume: next phase

Before starting any services, identify the old application's commit, Rails
environment, database name, MariaDB version and actual Docker volume names.
The current local configuration maps production to the development database;
confirm that matches the old instance. The supplied Compose web service runs
in development, and its Redis template defines development and test only.
A production launch needs separate configuration review.

Make a backup and test restoration into a separate volume/project. Preserve
uploaded files and local configuration as well as the SQL data. A logical SQL
restore is preferable if the old database server version differs; do not
attach an unknown raw database directory to a different server version.

Do not use `script/docker/init.cmd`, `script/docker/init.sh`,
`script/reset_database.sh`, `db:reset*` or `db:otwseed` on the restored database.
The init scripts invoke reset/seed operations intended for a new installation.
Do not run `docker compose down -v` against volumes you intend to keep.

The Elasticsearch image changed from 7.17.26 to 9.3.0 since the previous merge.
Plan a fresh search volume and rebuild the indices from the restored database;
do not attach the old search volume directly to the new Elasticsearch service.
Review Redis persistence separately, especially any queued jobs.

Review pending migrations and the release-specific `After:` data tasks against
the *actual deployed version*, then migrate only the restored copy. There are
27 added/changed migration files since the May 2025 upstream base; an older
hosted database may need more. The `After:` file retains only recent tasks,
so earlier releases may require consulting historical versions. The custom
Resque scripts are preserved but have not been runtime-validated against the
new code; do not treat them as a verified migration procedure.
