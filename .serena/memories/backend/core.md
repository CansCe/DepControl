# Backend (Dart Frog API)

Pkg `backend`, Dart Frog file-based routing. Compiles to a single binary.

## Layout
- `routes/` — file-based → HTTP endpoints:
  - `index.dart`, `projects/index.dart`, `projects/[id]/index.dart`,
    `projects/[id]/resolve.dart`, `_middleware.dart`.
- `lib/src/`
  - `deps.dart` — wiring / dependency provision.
  - `repository/project_repository.dart` — in-memory repo (Postgres planned phase 3+).
  - `services/` — `git_fetcher.dart`, `pub_api_client.dart`, `pubspec_analyzer.dart`,
    `resolver.dart` (git fetch, pub.dev client, analyzer, resolver).

## Run
- `cd backend; dart_frog dev` → http://localhost:8080 (needs `dart_frog_cli` activated).

## Known issues (pre-existing stub bugs)
- `services/pubspec_analyzer.dart:44,84,85` — uses `Version.tryParse` which pub_semver's
  `Version` doesn't define (use `Version.parse`).
- Route files use relative `../lib` imports → `avoid_relative_lib_imports`; should be
  `package:backend/...`.

## Security invariant
See `mem:conventions` — resolver runs untrusted pubspecs only via `pub upgrade --dry-run`,
never executes fetched code.