# Conventions

- Lints: `analysis_options.yaml` at root includes `package:flutter_lints/flutter.yaml`.
  Keep the tree analyze-clean (`flutter analyze`).
- Shared DTOs: define in `packages/shared/lib/src/models/`, export via
  `packages/shared/lib/shared.dart` (barrel). Consume in backend/frontend via
  `package:shared/shared.dart` — never relative paths across members.
- Backend Dart Frog routes import backend lib via `package:backend/...`, not relative
  `../lib` paths (avoid `avoid_relative_lib_imports`).
- Any dependency added to one member must resolve compatibly for the whole workspace
  (single shared resolution). Prefer aligning shared/lint dep versions across members.
- Backend security invariant: dependency resolution runs `dart pub upgrade --dry-run`
  against UNTRUSTED pubspecs. Never run `dart run` or build hooks on fetched projects;
  `--dry-run` avoids executing hooks. Intended to run sandboxed (no outbound except
  pub.dev + git host).