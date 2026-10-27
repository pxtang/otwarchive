# Media server upstream refresh

Upstream `otwcode/otwarchive` master was merged through `aa99cd45c`
(AO3-7619 Update css_parser to 3.2.0). The pre-merge commit is preserved on
`codex/backup-before-upstream-2026-10-26`; integration work is on
`codex/upstream-refresh-2026-10-26`. Nothing has been pushed.

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

This WSL distro has Ruby 3.0.2 and Bundler 2.3.5; its Docker CLI reports that
Docker Desktop WSL integration is unavailable. No image build, Rails boot,
application tests, database migration or volume compatibility test has been
performed. Those remain necessary before calling this deployment-ready.

From Windows with Docker Desktop available, start with checks that do not
start services or access volumes:

```powershell
docker compose config --quiet
docker compose build web test
```

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
