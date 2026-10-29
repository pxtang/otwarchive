# Selective backup import from public AO3

## Current requirements and defaults

Build a **new import UI inside the self-hosted Rails archive**, using the archive's
existing web server, authentication, database connections, and Resque workers.
The example is <https://archiveofourown.org/works/95493226/chapters/255079676>.
Normalize that chapter URL to work ID `95493226` and retrieve the whole work.
This document is an implementation plan; no importer or imported work exists yet.

Every piece of source metadata must be visible, selectable, removable, and editable
before committing the import: title, author attribution/tag, summary, work/chapter
notes, dates, language, completion metadata, fandoms, categories, relationships,
characters, freeforms, rating, archive warnings, and series information. Distinguish
source values from local replacements. Do not retain unchecked source metadata
in a hidden permanent copy: raw source HTML and full manifests are temporary and
expire. Keep only minimal technical provenance plus the final selected metadata.

Defaults:

- Use the designated **archival account/pseud** as the local work and chapter
  creator. Never create source-author accounts or send author invitations.
- Notification suppression and other optional subsystem disablement are deferred.
  With only one or two local users, normal work/chapter notification callbacks
  are acceptable for now; disabling them is not an import milestone requirement.
- Generate a selected Freeform tag containing the actual source author's name,
  e.g. `Black_Heather`. It is the first tag, even when new to the local archive.
  It remains editable/removable like other metadata. Multiple authors produce
  one tag each, first in source order. Preserve anonymous/orphaned attribution as
  displayed rather than trying to identify a person.
- Leave **rating and archive warnings unchecked and unsaved**, while displaying
  their fetched values with controls to keep/edit them. This exception wins even
  when these tags already exist locally. Do not silently add `Not Rated`, `No
  Archive Warnings Apply`, or `Creator Chose Not To Use Archive Warnings`.
- For other source tags, resolve existing local tags using read-only lookup;
  **select existing tags by default**, with new tags initially unchecked except
  author tags. This replaces the earlier select-all character/relationship rule.
- Present a single ordered candidate list: selected/pinned source-author tags,
  then existing local tags, then new tags. Use type badges and category filters
  so relationships, characters, fandoms, etc. remain independently selectable.
  A deselected existing tag stays deselected; edits must not undo manual choices.
- Keep ordinary non-tag metadata selected initially, but allow removal/edits.
  Keep chapter bodies/order as the whole-work content rather than mistaking
  structural source IDs for editable AO3 identities.
- **No imported reading restrictions:** save posted works/chapters with
  `restricted = false`, no inherited unrevealed/collection visibility settings,
  and no adult-content confirmation on work, chapter, or entire-work views.
  Logged-out reading must work. Import/edit operations still require the archive
  owner's authorization; this does not change who can modify content.

Title and language currently have mandatory Rails storage semantics. Removing a
source value must not silently put it back: show the proposed local replacement
in review (e.g. a generated local title and explicitly chosen local language).
If a field genuinely cannot be represented as absent, explain that inline and
require a replacement. Do not use `save(validate: false)` to satisfy removals.
Fandom/rating/warning presence rules are specifically addressed below so optional
tag categories really can be absent.

## Architecture and save path

The proposed path is:

```text
Archive Rails import page
  → existing Resque worker → configured FlareSolverr → validated source HTML
  → plain-value manifest + read-only local-tag matching
  → review/edit/select in the archive UI
  → Rails import service → ActiveRecord transaction
  → Work + Chapters + Creatorships + selected Tags/Taggings + provenance
  → normal after-commit indexing → readable local work
```

This invokes the Ruby application's model code in the existing Rails process or
worker. It **does write the database through ActiveRecord**, as all Rails saves
do; it does not connect externally to SQL or issue ad hoc inserts. It does not
POST to the old `/works/import` endpoint or screen-scrape the local authoring form.
Those paths save too early, populate unwanted metadata, and can invite authors.
An external importer/API server would add authentication, callbacks, and duplicate
integration work without helping the current scope.

### Keep upstream integration small

Implement an isolated, versioned local Rails engine, suggested path
`lib/ao3_backup/`, mounted at `/backup_imports`. Confirm Rails 8.1 loading conventions
before scaffolding. Keep controllers, views/assets, parser, providers, selection
policy, model concerns, jobs, helpers, tests, and namespaced models together.
Use additive tables/migrations such as `ao3_backup_imports` and
`ao3_backup_import_sessions`; avoid global Tag/Tagging schema changes.

Expected upstream touchpoints are a route/engine boot hook, one navigation link,
small conditional validation hooks, a shared adult-view predicate, and imported
work tag-display hooks. Document them in the engine README, with focused
integration tests. Keep ordinary imports/works on upstream behavior; do not copy
large upstream controllers/templates or replace validation chains dynamically.
A local engine reduces conflict surface but cannot guarantee conflict-free pulls.

The provenance association is a durable **archival import marker**, not a
user-submitted flag. Build it before Work validation, inside the transaction;
make omissions continue to work on subsequent edits, reindexing, and re-saves.

## Acquisition: use FlareSolverr first

The owner supplied `http://192.168.0.12:8191`; it has successfully retrieved the
example from both the host and the restoration Rails container. Configure the
provider endpoint in environment/local settings, e.g. `AO3_FLARESOLVERR_URL`.
Never hardcode that LAN address or accept a proxy endpoint from the import form.

For automatic import on another network, the recommended simplest deployment is
an optional **FlareSolverr Compose sidecar** on the archive's internal Docker
network. The Rails worker calls `http://flaresolverr:8191/v1`; no public port is
needed. Reuse a trusted existing service when available. Pin a tested image
version/digest and document upgrades. This task does not install it elsewhere.
The sidecar is now implemented in `docker-compose.import.yml` with pinned image
3.5.2, health gating, and web/resque environment configuration. See
`docs/ao3-import-dependencies.md` and `script/docker/check_flaresolverr.rb` for
startup and the read-only live check. It passed on `otwarchive-restore` using the
local solver; the selective import UI and persistence service remain planned.
The prior browser-extension requirement is withdrawn; browser capture/upload can
remain future fallback options, not v1 dependencies.

Use `POST /v1` / `request.get` for
`https://archiveofourown.org/works/:id?view_full_work=true&view_adult=true`.
Validate the API HTTP response, JSON envelope, target HTTP status, final URL,
expected source work ID, work/chapter DOM structure, response size, and complete
published chapter count. The verified API example and source selectors are below.
Do not rely on `status: ok` or HTTP 200 alone. Do not replay clearance cookies
through another client/IP or log them. Keep concurrency low, use a 60-second
solver limit and slightly longer caller timeout, bounded retries/backoff, and
cancel/error states in the UI. Close persistent sessions if introduced.

Accept only supported HTTPS AO3 work/chapter paths; check host/port/credentials
and every redirect. Do not fetch arbitrary image/link targets. Distinguish solver
unreachable, malformed response, target 403/429/525, verification still present,
adult gate, missing work, and incomplete/truncated chapter content. No failure
may save a partial work. Respect Retry-After and avoid repeated whole-work fetches
while the user changes selections.

Use one immutable temporary snapshot per review. Bind the import session to its
user, source identity, digest, and expiration. Fetch once; commit the exact reviewed
snapshot. Do not persist unchecked metadata or raw prose as permanent fixtures.
FlareSolverr worked here but is not a guarantee against future site changes; test
from the actual deployment network before advertising unattended import there.

## Parse and review without creating tags

Use Nokogiri to extract plain values, typed source tags, safe HTML fields,
chapter IDs/order where exposed, and published/expected chapter counts. Handle
both multipart chapter article containers and the single-chapter body layout
verified below. Only these body containers become body HTML. Strip page chrome
and the direct “Chapter Text” landmark, preserve source headings/formatting, and
run existing HTML sanitization.
Keep chapter summary/beginning notes/endnotes separate. Validate lengths rather
than truncating prose. Resolve safe relative links; report externally hosted
images as remote dependencies. Media mirroring and work skins are later work.

Do not import source comments, kudos, hit counts as local statistics, subscriptions,
accounts, or tag-wrangling graphs. Source word count may be shown for comparison;
local counters are computed by the application. Series information can be removed,
edited, or explicitly mapped to a local series; never create a series silently.

Existing code facts:

- `StoryParser` lacks an AO3 parser and falls back to generic page-body parsing.
  `set_work_attributes` uses fetched chapter count as the expected total, which
  would incorrectly mark the example's `2/?` complete.
- `Taggable` setters call `find_or_create_by_name` even on an unsaved Work.
  Therefore preview must not instantiate/populate Work tag setters. Use plain
  manifests and read-only database queries until the final transaction.
- Local tag names have cross-type collision/recategorization behavior. Existing
  means an exact match under local name comparison rules **of the intended type**,
  or an explicitly resolved local synonym. Display the resolved name/type/ID.
  Do not count a same-spelled tag of another type as reusable, or recategorize
  an UnsortedTag during preview. Explain collisions before saving.

### New native import UI

Name the feature **Magic Import work** (use this exact visible label). Add it as
the third item in the header's **Post** dropdown, matching the supplied screenshot:

1. New Work
2. Import Work
3. Magic Import work

The menu is rendered by `app/views/users/sessions/_greeting.html.erb`. Insert the
new link immediately after the existing Import Work link and before the optional
drafts entry. Link to the new engine's `/backup_imports` entry page. Retain the
existing two destinations and use the same label for the new page heading, with
a namespaced translation key. Show the link to accounts authorized for the new
import workflow and enforce that authorization at its routes. Add the menu link
when the entry page exists, rather than exposing a dangling navigation item.

Provide URL entry, fetch progress/errors, review, exact save preview, and result
link inside the existing archive layout. Review contains editable metadata fields,
a chapter list and content preview, and a searchable tag list with type badges.
Every source metadata field has a keep toggle and local editor. Rating/warnings
stay visible but unchecked. New author tag(s) are at the top, then all existing
local tag candidates (checked), then remaining new candidates (unchecked).

Support select-all/none and category filters without losing the global priority
order. Renaming a candidate recomputes its local match status without overwriting
an explicit keep/remove choice. Deduplicate final values by resolved tag identity
and handle author tags colliding with existing freeforms only once. Show which
values will create new tags. Never infer characters from pairings or tag text.

At commit, send the exact selected values/types/order and edited scalar fields,
not a request to reapply defaults. Bind data to the reviewed source snapshot and
validate limits/types/ownership server-side. Explicit empty arrays mean keep none.
Named presets can come later; their defaults must remain subordinate to explicit
choices and the initial rating/warning exclusion. Do not auto-select unrelated
local tags that are absent from the source/candidate list.

### Author-first order after import

The first-tag rule applies to both review and saved work/search-list displays.
Store final ordered local tag IDs and author-tag IDs in the import's own metadata.
Do not rely on SQL insertion order or globally change Tag/Tagging ordering.
Use a focused display helper/partial for imported works: author(s), then tags
identified as existing at review, then selected new tags, with type labels where
needed. Persist the reviewed order, so tags becoming “existing” during commit do
not reshuffle it. Reconcile removed/deleted tags on later edits and append later
additions predictably; do not render duplicate tags in the normal grouped lists.
Add small hooks at the work metadata and work-list tag display points. Ordinary
works continue using upstream display order.

## Save with Rails models and normal callbacks

Create a minimal provenance record with source host/work ID/canonical URL,
local owner/work, source-to-local chapter ID map, retrieval digest/time, selected
policy, and final tag ordering. Use a unique `(source_host, source_work_id)` index
for duplicate/concurrent import protection. Keep only selected author names and
selected/edited metadata; do not permanently store rejected source tags, ratings,
warnings, or summaries in an original-metadata blob. Technical source identity
is distinct from the editable public source-attribution field.

In one ActiveRecord transaction, claim source identity, build the import marker,
create the Work/Chapters/Creatorships, resolve **only selected tags**, save final
ordering, and validate the complete result. Use typed tag arrays rather than
comma-joined text or raw SQL. On any failure, roll back new work, tags, chapters,
series, and provenance. Account for indexing callback timing; retries must not
invite authors, duplicate saves, or lose the saved work's indexing status.
Keep normal subscription notification behavior; suppression is future work.
Use archival account context where validations require `User.current_user`.

### Truly optional metadata and unrestricted reading

`Work` currently has unconditional presence checks for `fandom_string`,
`rating_string`, and `archive_warning_string`. Add narrowly scoped conditions
allowing these to be absent for works with the durable archival import marker.
Do not suppress unrelated validations, falsify metadata with placeholder tags,
or leave a transient import flag that breaks later edits. If rating/warnings
are selected, their existing type/cardinality/canonical constraints still apply;
provide local valid choices or an explicit mapping rather than silently changing
an unsupported value.

Save imported works/chapters as posted, with `restricted = false`, no imported
collection/reveal restrictions, and normal non-hidden status. Skip adult-content
interstitials for imported backups in shared `see_adult?`, covering both work and
chapter controllers. Empty ratings are considered adult by `Taggable#adult?`, so
omitting ratings alone does **not** remove the gate. Keep that method's global
semantics intact. Confirm anonymous reading of imported work/chapter/entire-work
pages with no adult cookie, including an import that explicitly retains Mature
rating. Do not alter global rating records, existing works, or write authorization.

Use `expected_number_of_chapters = nil` for the example's `2/?`, preserve posted
chapter order, and verify `complete == false` after chapter callbacks. Imported
backups must not remain drafts: drafts older than 30 days are purged. Repeated
work/chapter URL variants link to the same existing import. Automatic updates of
ongoing works are later work and must preserve local metadata/text edits.

## Implementation and verification sequence

Follow [Magic Import implementation milestones](magic-import-implementation-milestones.md)
for component contracts, build order, recovery semantics, and concrete acceptance
gates. Preserve all four verified layouts (`1/1`, `7/7`, `2/?`, `10/12`) below.

| Stage | Deliverable |
| --- | --- |
| M0 | Boot/reload/eager-load foundation and early isolated proof of model validation, posting, and indexing behavior |
| M1 | Shared parser/provider/policy contracts and a read-only diagnostic accepting single and multipart works |
| M2 | Working Post → Magic Import work inspector/review UI, with content saving disabled |
| M3 | Full reviewed import into Rails models, including chosen metadata, author-first ordering, anonymous reading, and indexing |
| M4 | Retry/crash/concurrency/cleanup recovery, ordinary-edit/upstream regression coverage, and routine-use acceptance |

Do not postpone all tests until after UI/persistence implementation. Each stage
must pass its own gate before the next exposes more behavior. In particular,
SQL rollback does not undo Redis index effects, and existing worker
queue subscriptions must actually consume the new fetch jobs.

Run automated suites in a separate Compose project with isolated SQL, Redis,
search, and cache. The current spec helper flushes Redis and cleans database/search
data, so do not run it inside `otwarchive-restore`. Use the restored stack for
controlled live acceptance of specific new imports, without test-suite cleanup.

## Restoration environment

See `docs/restore-verification.md`. The verified web endpoint is
<http://localhost:3002>. Use this exact project and overlays:

```sh
docker compose -p otwarchive-restore \
  -f docker-compose.yml -f docker-compose.sandbox.yml -f docker-compose.restore.yml \
  -f docker-compose.import.yml \
  up -d --no-build web
```

Start Resque with the same overlays when implementing worker/indexing tests,
after reviewing scheduler side effects. Never run init scripts, database resets,
fixture seeds, `db:otwseed`, volume deletion, or plain/default Compose against
this restored copy. The FlareSolverr sidecar uses an additive local overlay,
leaving the upstream base file's existing local changes untouched.

## Verified example through the owner's FlareSolverr

On 2026-10-28, the owner supplied `http://192.168.0.12:8191` (the default port).
The health endpoint returned FlareSolverr 3.5.2. `POST /v1` with the following
payload returned `status: ok`, target HTTP 200, the requested canonical AO3 URL,
and 61,817 UTF-8 bytes of rendered HTML in about 2.5 seconds:

```json
{
  "cmd": "request.get",
  "url": "https://archiveofourown.org/works/95493226?view_full_work=true&view_adult=true",
  "maxTimeout": 60000
}
```

The restoration web container can also reach this solver. Keep the endpoint in
environment/local configuration, e.g. `AO3_FLARESOLVERR_URL`, rather than hardcoding
a LAN address into application code or exposing it as a user-supplied proxy URL.
The service needs no new installation on this network. Its configured browser
runs on a different host/network path than the earlier probes; success does not
isolate whether browser state, request fingerprint, or routing caused the earlier
525s. See [FlareSolverr's API documentation](https://github.com/FlareSolverr/FlareSolverr)
for the response envelope and browser/session lifecycle.

### Observed metadata and structure

| Field | Verified value |
| --- | --- |
| Title | The Last Person on Earth |
| Source author | Black_Heather, `/users/Black_Heather/pseuds/Black_Heather` |
| Rating | Mature |
| Archive warning | Graphic Depictions Of Violence |
| Categories | F/M; M/M |
| Fandom | 僕のヒーローアカデミア \| Boku no Hero Academia \| My Hero Academia (Anime & Manga) |
| Language | English |
| Published / updated | 2026-10-26 / 2026-10-28 |
| Source word count | 2,796; retain as source metadata, do not require the local counter to match exactly |
| Chapter status | 2/?; incomplete, final total unknown |
| Metadata counts | 1 fandom, 3 relationships, 6 characters, 15 freeform tags |
| Series | None listed |
| Summary | Present; 1,029 characters of inner HTML in this rendered snapshot |
| Work beginning/end notes | None found |
| Chapter notes | Chapter 2 has ending notes; no chapter summaries/beginning notes found |
| Inline chapter images | None found in this example |

The three relationship names are `Bakugou Katsuki/Midoriya Izuku`,
`Bakugou Katsuki/Original Character(s)`, and `Midoriya Izuku/Uraraka Ochako`.
The six characters are `Bakugou Katsuki`, `Midoriya Izuku`, `Todoroki Shouto`,
`Original Pro Hero Character(s) (My Hero Academia)`, `Kirishima Eijirou`, and
`Uraraka Ochako`. Tags such as `Original Character(s)` and
`Todoroki Shouto is a Good Friend` belong to the **freeform** group on this work;
do not turn them into Character records by guessing from their text.

| Chapter | Source ID | Title | Raw body-node text length |
| --- | --- | --- | ---: |
| 1 | 255079676 | The beginning of the end | 4,741 |
| 2 | 255425746 | Defenseless | 11,754 |

These text lengths include presentation whitespace and the “Chapter Text”
landmark; they are structural diagnostics, not expected final imported counts.
No story prose or solver cookies are included in this plan or committed fixtures.

Verified selectors for the full-work page:

- Work title: `#workskin > .preface h2.title`; byline links:
  `#workskin > .preface .byline a`.
- Typed tags: `dl.work.meta dd.<type> a.tag`, where type is `rating`, `warning`,
  `category`, `fandom`, `relationship`, `character`, or `freeform`. Read decoded
  link text, not tag URL encodings or comma-separated container text.
- Language: `dl.work.meta dd.language`; summary:
  `#workskin > .preface .summary blockquote.userstuff`.
- Stats: `dl.work.meta dd.stats dl dd.published`, `dd.status`, `dd.words`, and
  `dd.chapters`. Read `dt.status` alongside `dd.status`: the original example
  labels it `Updated:`, while the completed multipart example below labels it
  `Completed:`. A completed single-chapter work may omit both status nodes.
  Parse the chapter fraction explicitly instead of equating the retrieved
  chapter count with completion or requiring a status-date node.
- Multipart chapters: `#chapters > .chapter`; their DOM IDs `chapter-1`/`chapter-2` are
  **positions**, not source chapter IDs. Extract stable source IDs from each
  `h3.title a[href]` and confirm its work ID matches `95493226`.
- Multipart chapter body: direct child `.userstuff[role="article"]`. Remove only its direct
  `h3.landmark.heading` before retaining inner HTML; do not strip arbitrary user
  headings. Every observed chapter has exactly one body container.
- Chapter 2 ending notes: `#chapter-2 #chapter_2_endnotes blockquote.userstuff`.
  Ending notes contain 720 text characters; retain separately from prose.

An independent solver request for the original chapter URL **without** the adult
flag returned HTTP 200 with the work's normal page title, but zero `#workskin`
and chapter-body containers. It contained `a[href*="view_adult"]` with text
“Yes, Continue” and relative target
`/works/95493226/chapters/255079676?view_adult=true`. Thus a plausible title and
HTTP 200 do not establish successful retrieval. The acknowledged full-work URL
above is validated; there is no need to scrape individual chapters for this work.

### Additional verified chapter/completion cases

On 2026-10-28, both owner-supplied examples were retrieved sequentially through
the restoration stack's configured FlareSolverr 3.5.2, using the full-work and
adult-acknowledgement query parameters. Both returned API `status: ok`, target
HTTP 200, and the requested full-work URL. Nokogiri checks inspected structure
without booting Rails, writing archive records, or retaining source HTML/prose.

| Source | Observed chapter status | Body structure | Persistence expectation when completion metadata is retained |
| --- | --- | --- | --- |
| [95623101](https://archiveofourown.org/works/95623101), *Sometimes The People We Hate Are The People We Need* | `1/1` | One nonempty `#chapters > .userstuff`; no `.chapter` wrapper or body `role="article"` | One posted chapter; `expected_number_of_chapters = 1`; `complete == true` |
| [95605556](https://archiveofourown.org/works/95605556), *I’m already here* | `7/7` | Seven `.chapter` wrappers, each with exactly one nonempty direct article body | Seven posted chapters in source order; `expected_number_of_chapters = 7`; `complete == true` |
| [87764801](https://archiveofourown.org/works/87764801), *six eyes in the dark (midnight screenings)* | `10/12` | Ten `.chapter` wrappers, each with exactly one nonempty direct article body | Ten posted chapters in source order; `expected_number_of_chapters = 12`; `complete == false` |
| [95493226](https://archiveofourown.org/works/95493226), original example above | `2/?` | Two multipart chapter bodies in the earlier verified snapshot | Two posted chapters; `expected_number_of_chapters = nil`; `complete == false` |

For the `1/1` layout, `#chapters` has a direct `h3.landmark.heading` followed by
the body `div.userstuff`. Extract only that body's inner HTML; do not include
the sibling “Work Text” landmark. No work/chapter links exposing a source chapter
ID were found in this page. Represent the source chapter ID as absent, keep
position `1` and the local chapter ID, and bind it to the source work/snapshot;
do not invent an AO3 chapter ID or require an extra fetch merely to obtain one.
The provenance chapter mapping must support that absent source ID. This work
has a published date of `2026-10-28` and no `dt.status`/`dd.status` nodes.

For the `7/7` layout, the source chapter IDs in order are `255398291`,
`255398366`, `255398636`, `255398761`, `255398826`, `255399001`, and
`255400861`. Chapter 7 is the final chapter; importing its URL must still retrieve
all seven chapters and resolve to the same source work identity. Chapters 2–7
each have a chapter summary, which must remain separate from body HTML. Both
the published date and the `Completed:` status date are `2026-10-28`.

The additional cross-fandom example, `87764801`, was also verified on 2026-10-28
through the **new local Compose sidecar**, using the web container's configured
`AO3_FLARESOLVERR_URL=http://flaresolverr:8191`, not the earlier LAN service.
FlareSolverr 3.5.2 returned API `status: ok`, target HTTP 200, the requested
full-work URL, and 375,040 UTF-8 bytes of rendered HTML. Structural checks found
ten unique chapter IDs with ten nonempty bodies. The author is
`strawberry_hongjoong`; the two distinct source fandoms are:

- `呪術廻戦 | Jujutsu Kaisen (Anime)`
- `呪術廻戦 | Jujutsu Kaisen (Manga)`

Observed metadata counts are 2 fandoms, 1 relationship, 9 characters, 19 source
freeforms, and 1 each of rating, warning, and category; the language is English.
Chapter 1's source ID is `232579836`, and chapter 10's is `255304351`.
Chapters 2–10 each have a chapter summary; every chapter has two note blocks.
Keep those summaries/notes separate from prose. The published date is
`2026-07-02`, and the `Updated:` date is `2026-10-28`; verify that retaining dates
preserves the reviewed publication date through posting callbacks.

For this `10/12` case, completeness of retrieval means all **ten published**
chapters, while the expected final total remains twelve. Do not request/create
two placeholder chapters, replace the expected total with ten, or mark the work
complete. Match the two fandom candidates independently by their complete names
and intended type, including the Japanese text, pipe, and Anime/Manga suffixes.
Test with one fandom present locally and the other absent, then with both absent:
only existing fandom candidates auto-select; the author Freeform
`strawberry_hongjoong` remains selected first; rating/warning candidates remain
unchecked; and no tags from the other example works appear unless sourced here.
Explicitly keeping both fandoms must retain two distinct Fandom taggings.

Use synthetic fixtures reproducing these layouts with invented prose. Require
the parser to accept `1/1` without multipart selectors or a status date; preserve
all seven bodies and six chapter summaries for `7/7`; and reject a `7/7` snapshot
with any missing/duplicate chapter or missing body. Verify completion after
posted chapter/creatorship callbacks, alongside the existing `2/?` regression.
For `10/12`, likewise preserve ten bodies and nine chapter summaries, reject
missing/duplicate published chapters, and verify the finite incomplete total.
The current `script/docker/check_flaresolverr.rb` only accepts multipart markup
and still needs its single-chapter validation branch before it can pass `1/1`.
These live checks verify acquisition/structure; persistence remains planned.

### Concrete selection acceptance case

For this example, select only characters `Bakugou Katsuki` and `Midoriya Izuku`,
only relationship `Bakugou Katsuki/Midoriya Izuku`, and only freeforms
`Single Parents` and `Legal Drama`. Keep the source fandom, categories, and language; leave rating and archive
warnings unchecked, and keep the generated `Black_Heather` author tag first. The resulting work must have exactly 2 Character,
1 Relationship, and 3 Freeform taggings (author plus two selected freeforms),
with zero Rating/ArchiveWarning taggings; all other source values stay unattached.
Repeat with no source freeforms selected and require only the author Freeform
tagging. Remove the author tag too and require zero Freeform taggings. No interpretation of these example choices as the owner's permanent
preferences is intended: the final UI must let them make the selections.

For `2/?`, set `expected_number_of_chapters = nil` and verify `complete == false`
after both posted chapters and their creatorships are saved. `Work#wip_length`
renders nil as `?`; the generic StoryParser's assignment of chapter count would
incorrectly mark this example complete. Chapter callbacks and Work's
`update_complete_status` must be covered by the persistence test.

### FlareSolverr provider requirements and remaining limits

- Validate the API HTTP response, JSON envelope `status`, `solution.status`,
  `solution.url`, HTML structure, source identity, and chapter completeness.
  A solver HTTP 200 alone is insufficient. Never log its returned cookie values.
- Read rendered HTML directly from `solution.response`. Do not rely on replaying
  clearance cookies through another client/IP. One full-work request suffices
  here; avoid parallel browser launches. Stateless requests used in this probe
  require no persistent sessions; if sessions are added, close them on completion,
  cancellation, and errors.
- Give the solver up to 60 seconds with an outer client timeout slightly longer
  (the probe used 75 seconds). Run it outside the web request lifecycle with a
  status page and bounded retry; distinguish solver unreachable, solver error,
  target error, verification still present, adult warning, and malformed work.
- The linked HTML download is **not yet validated**: requesting its advertised
  URL through FlareSolverr returned `status: ok`, target HTTP 200, but final URL
  `chrome://new-tab-page/` and browser UI HTML. Reject that result. Browser
  attachment handling differs from rendered-page retrieval; keep the validated
  full-work HTML as the primary acquisition format. Test actual saved/download
  HTML separately before enabling its parser.
- All parsing above used Nokogiri in the restoration web container and performed
  no database writes. No Work/Chapter/Tag/Series records were created. Local
  persistence, indexing, and selected-tag filtering remain implementation work.
- Recommended deployment: run a FlareSolverr sidecar with each automatic-import
  deployment; verify it from that deployment before claiming retrieval works.
  Installing it on the other network is not part of this planning task. The
  manifest, selection policy, and persistence remain independent of transport.
