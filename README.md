# DepControl

**Know what your projects depend on, and what it is going to cost you.**

DepControl tracks a registry of software projects and keeps a standing answer to
the questions that only get asked after something goes wrong: which packages are
we actually running, which of them have known vulnerabilities, what licenses did
we agree to, what changed since last week, and what breaks if we upgrade.

Point it at a Git repository. It reads every manifest in there, resolves the
dependency tree, and produces a report you can act on — then keeps re-checking
and tells you when the answer changes.

Dart/Flutter and npm today. 100% Dart: Flutter Web front end, Dart Frog API,
Postgres.

---

## What you get

### A complete inventory

Every package the project resolves, direct and transitive, with the version
actually in use and the manifests it was reached from. A repository is not
assumed to be one package — a monorepo's every `pubspec.yaml` and
`package.json` is read, including the directories deliberately kept out of the
workspace that resolve to different versions of the same thing.

Packages that are declared but never imported are flagged as dead weight, and
packages imported but never declared are flagged as the build break waiting to
happen. Each dependency carries its install weight, and the report can tell you
what dropping a set of them actually reclaims — including the transitive tail
that comes out with them.

### Known vulnerabilities, with a fix that was verified

Advisories from OSV.dev, matched against the version you are running rather than
the package name, scored from the published CVSS vector and banded
critical→low. For a vulnerable transitive package the report names the direct
dependency that pulls it in, because that is the only thing you can bump.

Then it gives you the fix. Not constraint arithmetic that looks plausible —
every candidate is run through the resolver and kept only if the vulnerable
package lands on a fixed version. Raise a constraint, bump the parent, or
promote to a direct dependency, in that order, with the knock-on version changes
listed. Where nothing works, it distinguishes "no fix has been published" from
"no change to this manifest can reach one".

Delivered as a manifest diff. DepControl holds no write credentials to your
repositories and does not open pull requests.

### License compliance you can hand to somebody

Every dependency's license, classified by the obligation it creates —
permissive, weak copyleft, strong copyleft, network copyleft, not open source —
and judged against a policy you set per obligation family, with per-license
exceptions. A license nobody recognises is never filed under "probably fine";
it goes to review.

Export the whole tree as CSV or JSON, including the permissive majority, because
a compliance manifest is an inventory first and an exception list second. The
export carries the policy it was evaluated under, so it still reads six months
later.

Dev dependencies are excluded by default — worked out from the graph, not just
from the `dev_dependencies` block — and included on request if you redistribute
your toolchain.

### An upgrade assessment before you commit to it

For any package, what a version jump actually changes:

- **Published metadata** — new and dropped dependencies, constraint widening,
  SDK requirements.
- **The public API** — the declarations your code calls, compared between the
  two versions' real sources. Semver tells you whether the author *considered*
  the release breaking; this tells you whether the function you use still
  exists.
- **The author's release notes**, verbatim, filtered to just the sections your
  jump crosses rather than a link to twelve releases and the job of working out
  which apply.

### History, and what changed

Every scan is kept, but a revision is written only when something is actually
different — so a nightly re-scan of an untouched project gives you the four
entries that matter, not three hundred and sixty-five. Each entry records both
when that state was first seen and when it was last confirmed, because
"unchanged for six months" and "nobody has looked in six months" are different
facts.

Compare any two revisions in either direction and get: how far each version
moved (breaking/minor/patch, direction kept separate), advisories that newly
apply, advisories that cleared, relicensing, and dependencies that changed from
direct to transitive. A newly published advisory against a version that never
moved counts as a change — that is most of the reason to re-scan at all.

### Being told, without watching

Register a Slack or Teams incoming webhook, scoped to one project or all of
them, and set a bar: a new advisory at or above a severity you choose, a
breaking version move, or both. A daily sweep re-scans everything, compares, and
announces what clears the bar.

Each change is announced at most once per target, guaranteed through the
database rather than through hope — a sweep that runs twice, or a machine that
dies mid-send, cannot produce a duplicate alert.

### A registry that stays manageable

Projects can be archived — kept, with their reports, out of the default listing
and frozen against further scanning — or deleted outright. Archiving offers an
undo; deleting asks first, because nothing is kept and there is nothing to
restore.

---

## What it supports

| | Dart / Flutter | npm |
|---|---|---|
| Manifest | `pubspec.yaml` | `package.json` |
| Lockfile | `pubspec.lock` | `package-lock.json`, `npm-shrinkwrap.json` |
| Registry | pub.dev | registry.npmjs.org |
| Advisories | OSV.dev | OSV.dev |
| Licenses | pub.dev's per-version detection | the publisher's `license` field |
| Install weight | archive `Content-Length` | `dist.unpackedSize` |
| Unused / undeclared imports | yes | yes |
| Resolve & simulate | yes | not yet |
| Public API diffs | yes | no |
| Release notes | yes | thinner — many npm packages ship no changelog |

A repository can be both at once, and a Flutter app with a JavaScript front end
is the ordinary shape of that. Package identity carries the ecosystem, because
`path`, `http` and `crypto` exist on both registries as entirely different
software.

Repositories are read from **github.com and gitlab.com over https**. Public
repositories today.

## What it will not tell you

Stated plainly, because these are the gaps that matter when you are deciding
whether this covers you:

- **An empty advisory list is not a clean bill of health.** OSV does not
  distinguish "nothing published" from "the database could not be reached", and
  a report currently reads both as no advisories.
- **Install weight is not bundle size.** What survives tree-shaking into your
  production bundle depends on your symbols and your bundler, and no registry
  knows either.
- **npm packages are reported at one version.** The hoisted copy. A nested copy
  at a different version is missing, along with any advisory that applies only
  to it.
- **`yarn.lock` and `pnpm-lock.yaml` are not read.** Those projects fall back to
  resolving declared constraints, which the report labels as inferred.
- **`peerDependencies` are not counted**; `optionalDependencies` are.
- **No private or self-hosted Git.** Public GitHub and GitLab only.

More on all of it, and why, in [docs/DESIGN.md](docs/DESIGN.md).

---

## Roadmap

| Phase | Scope | Status |
|------:|-------|--------|
| 0 | Monorepo, shared models, wiring | done |
| 1 | Ingest Git URL → dependency report | done |
| 2 | Resolve & simulate | done — from registry metadata, not by running the package manager |
| 3 | Postgres registry, auth, history, alerts | done |
| 4 | Sandbox hardening, rate limits | in progress |
| 5 | **Local repository collector** | planned — not built |
| 6 | **API health tracking** | planned — not built |

### Local repository collector *(planned)*

A remote scan sees only what your repository publishes, and that is regularly
not what you run. Lockfiles are generated locally and frequently gitignored, so
the resolved versions — the ones an advisory actually applies to — never reach
the server, and the report falls back to inferring them from declared
constraints. Repositories that are private or self-hosted cannot be scanned at
all.

The plan is a small CLI you run inside your own checkout, which produces the
same report from local files:

```bash
depcontrol collect            # writes a dependency bundle from the working tree
```

**Sealed by construction**, because it runs against a repository you would not
hand to a service:

- It reads an **explicit allowlist of manifest and lockfile names** and nothing
  else. Not your source, not your `.env`, not your history.
- It **executes nothing** — no `pub get`, no `npm install`, no build hooks, no
  subprocess of any kind.
- Its output is a **plain JSON bundle you can read before it goes anywhere**:
  package names, versions, kinds, and the manifest paths they came from. That
  is the whole contents.
- Uploading is a **separate, explicit step**. Collecting and sending are not the
  same command.

### API health tracking *(planned)*

Dependencies are one half of what a project relies on; the services it calls are
the other, and nothing in a manifest mentions them. The plan is to let you
register endpoints against a tracked project **by hand** — URL, method, expected
status, check interval — and have DepControl poll them and report availability,
latency and status history alongside the dependency report, with the same
notification targets.

Manual registration only. Nothing is discovered from your code, and no endpoint
is contacted that you did not enter.

---

## Running it

### Prerequisites

- **Dart SDK ≥ 3.6** (pub workspaces) and **Flutter ≥ 3.27**
- Dart Frog CLI: `dart pub global activate dart_frog_cli`
- A Supabase project for auth; Postgres for persistence (optional — the API
  falls back to an in-memory store)

### Setup

The repo is a single pub workspace, so everything resolves **once from the
root**:

```bash
flutter pub get
```

(`flutter pub get` at the root covers the Flutter members too; plain
`dart pub get` works if you only touch the Dart members.)

Then copy `backend/.env.example` to `backend/.env` and fill it in. It documents
every variable; the two that matter are `SUPABASE_URL` (auth) and `DATABASE_URL`
(persistence).

### Run

```bash
cd backend && dart run tool/dev.dart
```

```bash
cd frontend && flutter run -d chrome
```

The backend reads configuration from the **process environment and nothing
else** — correct for a container, wrong for a laptop, which is why `tool/dev.dart`
exists: it loads `backend/.env` into the environment and starts `dart_frog dev`
with it, prints which names it loaded (names only — a connection string carries
a password), and says so plainly when auth or the database is missing. Anything
already set in your shell wins over the file. Plain `dart_frog dev` still works
if you would rather export the variables yourself.

The frontend needs no flags — it defaults to `http://localhost:8080`. Point it
elsewhere with `--dart-define=API_BASE_URL=…`, or per-device from the settings
screen. To drive it from a browser tab instead of a Chrome window, useful for
watching a large scan without a debugger attached:

```bash
cd frontend && flutter run -d web-server --web-port 5000
```

### Test

```bash
cd backend && dart test
```

```bash
cd packages/shared && dart test
```

```bash
cd frontend && flutter test
```

**The backend suite is split, deliberately.** 601 tests run in about six
seconds; 25 more talk to a real Postgres and take 42 seconds — 88% of the wall
clock for 4% of the coverage, which is how a suite stops being something you run
while you work. Those are tagged `db` and skipped by default:

```bash
cd backend && dart test -P db
```

**CI runs the second form.** Worth stating plainly: the point of those tests is
that the repository layer meets real SQL rather than the in-memory double that
shares none of its behaviour, and a suite that quietly stops covering the
database is worse than one that goes red.

### Operator CLIs

Some work is deliberately kept out of the request path — the API only ever
serves results these have already produced. All of them need `DATABASE_URL`.

```bash
cd backend && dart run tool/rescan.dart --all        # re-scan everything, then announce
cd backend && dart run tool/fill_changelogs.dart     # drain the release-notes backlog
cd backend && dart run tool/fill_api_diffs.dart      # drain the API-diff backlog
```

```bash
cd tools/api_differ && dart run api_differ http 0.13.6 1.0.0   # compare two versions by hand
```

`rescan.dart` is a CLI rather than a timer inside the server because the API is
deployed with `min_machines_running = 0` and stops between requests — an
in-process schedule would fire only while somebody happened to be using the app,
which is exactly when they do not need to be told.
`.github/workflows/rescan.yml` runs it daily.

---

## API

Every endpoint is authenticated with a Supabase JWT and scoped to its owner. A
project owned by someone else is a `404`, not a `403`.

| | |
|---|---|
| `GET /` | health |
| `GET /me` | the authenticated user |
| `GET` `POST` `/projects` | list, add |
| `GET` `PATCH` `DELETE` `/projects/{id}` | fetch, archive/restore, delete |
| `POST /projects/{id}/refresh` | re-scan |
| `GET /scans/{id}` | scan progress |
| `GET /projects/{id}/history` | revisions; `?revision=` for one in full |
| `GET /projects/{id}/changes` | diff two revisions; `?changelogs=true` for release notes |
| `POST /projects/{id}/resolve` | simulate a constraint change |
| `GET /projects/{id}/upgrade/{package}` | upgrade impact and API diff |
| `GET /projects/{id}/remediation` | verified fixes for every advisory |
| `GET /projects/{id}/licenses` | license report; `?format=csv` to export |
| `GET` `PUT` `DELETE` `/policy/licenses` | your license policy |
| `GET` `POST` `/notifications`, `DELETE /notifications/{id}` | webhook targets |

Expensive endpoints — the ones that fetch a repository and query a registry —
are rate limited per user (`RATE_LIMIT_PER_MINUTE`). Reading stored reports is
not counted.

---

## Layout

```
project_cloud/            # repo root = pub workspace umbrella (not an app)
├── packages/shared/      # DTOs shared by both sides
├── backend/              # Dart Frog API
│   ├── routes/           # file-based routes → HTTP endpoints
│   ├── sql/              # schema for tables not created through a route
│   ├── tool/             # operator CLIs
│   └── lib/src/          # git fetch, registries, analyzer, resolver, repositories
├── frontend/             # Flutter Web app  ← the runnable app
└── tools/api_differ/     # NOT a workspace member — needs its own analyzer version
```

The root is the workspace umbrella, not an app; it ties the members together
under one lockfile. Native targets, when needed, get added to `frontend` or a
new workspace member — not to the root.

## More

- **[docs/DESIGN.md](docs/DESIGN.md)** — why it behaves the way it does: what a
  scan reads and costs, how the two ecosystems differ and why that is not
  smoothed over, what is never guessed, and the security assumptions the server
  makes about its inputs.
- **[docs/DEPLOY.md](docs/DEPLOY.md)** — deploying the API and the front end.

Nothing DepControl fetches is ever executed. Resolution is computed from
registry metadata — no subprocess, no `pub get`, no build hooks — and archives
are decompressed in memory under caps on compressed size, expanded size and file
count.
