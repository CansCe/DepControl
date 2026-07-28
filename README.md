# DepControl (project_cloud)

A **100% Dart** hosted web app that ingests a Dart/Flutter project by **Git URL** and
lets you **inspect & report**, **resolve & simulate** dependency changes, and track a
**registry of many projects** over time.

- **Frontend:** Flutter Web
- **Backend:** Dart Frog (file-based routing, compiles to a single binary)
- **Shared:** a plain-Dart `shared` package of DTOs used by both sides
- **DB (Phase 3+):** Postgres

## Layout

`project_cloud/` is the pub workspace **umbrella** — it is not itself an app. It ties
the members together under one lockfile / `.dart_tool/`. The runnable app is the
`frontend` member; `backend` and `shared` are its peers.

```
project_cloud/            # repo root = pub workspace umbrella (not an app)
├── packages/shared/      # DTOs: Project, DepNode, DepReport, ResolutionResult
├── backend/              # Dart Frog API
│   ├── routes/           # file-based routes -> HTTP endpoints
│   ├── sql/              # schema for tables not created through a route
│   ├── tool/             # operator CLIs (smoke test, API-diff pipeline)
│   └── lib/src/          # services (git fetch, pub.dev, analyzer, resolver) + repo
├── frontend/             # Flutter Web app  <-- the runnable app
└── tools/api_differ/     # NOT a workspace member — see "Public API diffs"
```

> Native (mobile/desktop) targets, when needed, get added to `frontend` (via
> `flutter create --platforms=...`) or a new workspace member — not to the root.

## Roadmap

| Phase | Scope | Status |
|------:|-------|--------|
| 0 | Monorepo + shared models + wiring | done |
| 1 | Ingest Git URL -> dependency report | done |
| 2 | Resolve & simulate | done — resolved from pub.dev metadata, not by running pub |
| 3 | Postgres registry + auth | done — background drift check still TODO |
| 4 | Sandbox hardening, rate limits | TODO |

Upgrade reporting sits on top of these: what a version jump changes in published
metadata (`UpgradeImpact`), and what it changes in the package's public API
(`ApiDiff`, see below).

## Public API diffs

Semver says whether an author *considers* a release breaking. It cannot say
whether the declarations your code calls still exist. `tools/api_differ` answers
that by comparing the public API of two published versions, read from their own
sources.

It is **deliberately outside the pub workspace**: parsing Dart needs an analyzer
version this workspace cannot resolve (it is shared with `dart_frog_cli` and
`test`), and a path dependency would join the same resolution. It also keeps
archive fetching and source parsing out of the request path — the API only ever
reads diffs the tool already produced.

```bash
# compare two versions by hand
cd tools/api_differ && dart run api_differ http 0.13.6 1.0.0
```

The pipeline into the app:

1. Someone opens a package in the UI. If no diff is stored for that exact
   version pair, the API records the pair as wanted and says so — a missing diff
   never renders as "nothing changed".
2. An operator drains that backlog. Each pair runs the differ and is stored:

```bash
cd backend && dart run tool/fill_api_diffs.dart
```

3. Every project depending on that package now gets the answer, since a diff is
   keyed by package and versions rather than by project.

To store a single diff directly (`--dry-run` on the filler shows the backlog
without computing anything):

```bash
dart run api_differ yaml 3.1.2 3.1.3 --json | dart run tool/import_api_diff.dart
```

Both CLIs need `DATABASE_URL`, the same connection string the server uses. The
tables they use are in `backend/sql/api_diffs.sql`.

## Prerequisites

- **Dart SDK >= 3.6** (required for pub workspaces) and Flutter **>= 3.27** (workspace support)
- Dart Frog CLI: `dart pub global activate dart_frog_cli`

## Setup (pub workspace)

This repo is a single pub workspace, so you resolve everything **once from the root**:

```bash
# from C:\ProjectCloud\project_cloud — resolves shared + backend + frontend together
flutter pub get
```

(`flutter pub get` at the root covers the Flutter members too; plain `dart pub get`
works if you only touch the Dart members.)

## Run

```bash
# backend
cd backend && dart_frog dev                    # http://localhost:8080

# frontend (separate terminal)
cd frontend && flutter run -d chrome
```

## Security

### What the app reports

Dependencies carry their advisories through to the UI: identifier and CVE
aliases, the summary as published, and **the version that fixes it**. Where the
advisory names no fix, that is said outright rather than left blank — "no fix
listed" and "no fix needed" are not the same thing.

An advisory is matched against the version actually in use, not the package as a
whole, so a package with a historical CVE is not reported vulnerable forever.
For a vulnerable *transitive* package the report names the direct dependency
that pulls it in, because that is the only thing you can actually bump.

### What the server assumes about its inputs

Every project URL, ref and pubspec comes from a user, so:

- **Repository fetches are constrained.** Only `github.com` and `gitlab.com`
  over https; owner, repo and ref are validated before any request. A ref like
  `../../someone/else/main` normalises the repository out of the raw-content URL
  and would fetch a different project's pubspec — it is rejected rather than
  escaped.
- **Responses are bounded.** Size caps and timeouts on repository fetches and
  pub.dev calls; a remote host is under no obligation to be small or prompt.
- **Package names are validated, not escaped.** They arrive from fetched
  pubspecs and are interpolated into pub.dev request paths.
- **Nothing fetched is executed.** Resolution is computed from pub.dev metadata;
  no subprocess, no `dart pub get`, no build hooks. `tools/api_differ` parses
  package sources but never runs them, and decompresses archives in memory with
  caps on compressed size, expanded size and file count.
- **Projects are owner-scoped.** Reads are filtered by the JWT's `sub` in the
  query rather than after the fact, and a project owned by someone else is a 404
  rather than a 403, which would confirm the id exists.
- **Expensive endpoints are rate limited** per user — see
  `RATE_LIMIT_PER_MINUTE` in `.env.example`.

Still run the backend in a locked-down container with no outbound access except
pub.dev and the git hosts.
