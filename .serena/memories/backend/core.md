# Backend (Dart Frog API)

Pkg `backend`, Dart Frog file-based routing. Compiles to a single binary.

## Layout
- `routes/` — file-based → HTTP endpoints:
  - `index.dart`, `projects/index.dart`, `projects/[id]/index.dart`,
    `projects/[id]/resolve.dart`, `_middleware.dart`.
- `lib/src/`
  - `deps.dart` — process-wide service locator (`Deps`), injected via
    `provider<Deps>` in `_middleware.dart`. Holds `repository`, `gitFetcher`,
    `pubApi`, `resolver`, `analyzer`. Currently eager `final deps = Deps()`.
  - `repository/project_repository.dart` — `ProjectRepository` interface +
    `InMemoryProjectRepository`. Persistence seam.
  - `services/` — `git_fetcher.dart`, `pub_api_client.dart`, `pubspec_analyzer.dart`,
    `resolver.dart` (git fetch, pub.dev client, analyzer, resolver).

## Run
- `cd backend; dart_frog dev` → http://localhost:8080 (needs `dart_frog_cli` activated).

## Persistence
Decided: Supabase (managed Postgres) via the `postgres` pkg, behind the
`ProjectRepository` seam. Details, schema, connection gotchas → `mem:backend/persistence`.

## Lint debt (stub code, not errors)
- `services/pubspec_analyzer.dart:44,86` — `unnecessary_null_comparison` (dead null checks).
- Route files use relative `../lib` imports → `avoid_relative_lib_imports`; should be
  `package:backend/...`.

## Security invariant
See `mem:conventions` — resolver runs untrusted pubspecs only via `pub upgrade --dry-run`
(no build hooks / `dart run`); run sandboxed. The Resolver already uses a temp dir +
`--dry-run`; container isolation is still required.