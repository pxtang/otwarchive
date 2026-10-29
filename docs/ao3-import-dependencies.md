# Local AO3 import dependency

Append `docker-compose.import.yml` to your existing Compose files to run
FlareSolverr 3.5.2 alongside the archive. The overlay gives `web` and `resque`
`AO3_FLARESOLVERR_URL=http://flaresolverr:8191` and waits for the solver's HTTP
health check. It adds no host port, persistent volume, or archive database changes.
The browser's temporary files use a 256 MiB tmpfs. The upstream Compose file is
unchanged by this dependency addition.

FlareSolverr is an acquisition dependency; the new selective import UI and save
service described in `plans/ao3-selective-backup-import.md` are not implemented
by this overlay. Existing imports do not automatically use FlareSolverr yet.

## Restored archive

From the repository root, start the existing web stack plus its new dependency:

```sh
docker compose -p otwarchive-restore \
  -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml \
  -f docker-compose.import.yml up -d --no-build web
```

Append the same overlay to subsequent commands so Compose retains the dependency
and environment settings. Start `resque` with this combination when needed; this
setup check does not start its scheduler or run archive maintenance jobs.

Verify retrieval from the web container using the shared Rails parser without changing records:

```sh
docker compose -p otwarchive-restore \
  -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml \
  -f docker-compose.import.yml exec -T web \
  bundle exec rails runner script/docker/check_flaresolverr.rb \
  'https://archiveofourown.org/works/95493226/chapters/255079676'
```

The smoke check requests the entire work with adult acknowledgement, rejects
solver/target errors and non-work pages, and checks chapter IDs, body containers,
and the published chapter count. It prints title, chapter status/IDs, and tag
counts, never prose or solver cookies. This is a live network check; source
content/counts may change, and site challenges or downtime may cause failures.

For the original example, the 2026-10-28 reference snapshot had two chapters
(`255079676`, `255425746`), status `2/?`, one fandom, three relationships,
six characters, and fifteen freeforms.

Verified on 2026-10-28 using `otwarchive-restore`: the new local solver became
healthy, and the web-container smoke check returned `status: ok`, solver version
3.5.2, title `The Last Person on Earth`, both chapter IDs, and those metadata
counts. The check used `http://flaresolverr:8191`, not the pre-existing LAN solver.
The merged configuration retained the external restored database volume and gave
both web and resque the solver URL and healthy-service dependency. No resque
worker/scheduler was started, and no import records were saved.

Keep using the existing restored volume and localhost web port 3002. Do not run
init/seed/reset scripts or delete volumes. See `restore-verification.md` for the
restoration details.

## Other deployments

Append the import overlay after that deployment's existing overlays and start
`web` or `resque` normally. Each Compose project gets its own solver with internal
DNS name `flaresolverr`; there is no fixed LAN address. Run the same smoke check
from its web container before relying on automatic retrieval. The service uses
a real browser, so allow memory for it and avoid parallel fetches.

Upgrade the pinned image deliberately and repeat the smoke check. No solver can
guarantee every future challenge succeeds. Official setup and API reference:
<https://github.com/FlareSolverr/FlareSolverr>.
