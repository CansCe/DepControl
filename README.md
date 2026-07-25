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
│   └── lib/src/          # services (git fetch, pub.dev, analyzer, resolver) + repo
└── frontend/             # Flutter Web app  <-- the runnable app
```

> Native (mobile/desktop) targets, when needed, get added to `frontend` (via
> `flutter create --platforms=...`) or a new workspace member — not to the root.

## Roadmap

| Phase | Scope | Status |
|------:|-------|--------|
| 0 | Monorepo + shared models + wiring | scaffolded |
| 1 | Ingest Git URL -> dependency report | stubs in place |
| 2 | Resolve & simulate (`pub upgrade --dry-run`) | stubs in place |
| 3 | Postgres registry + background drift check | in-memory repo for now |
| 4 | Sandbox hardening, auth, rate limits | TODO |

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

## Security note

Resolution runs `dart pub upgrade --dry-run` against untrusted pubspecs. `--dry-run`
does not execute build hooks or `dart run`. Still run the backend in a locked-down
container (no outbound except pub.dev + the git host). Never run `dart run` / build
hooks on fetched projects.
