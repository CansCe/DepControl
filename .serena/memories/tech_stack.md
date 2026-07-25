# Tech Stack

- Language: Dart. Dart SDK 3.12.2, Flutter 3.44.8 (stable), installed at `C:\SDKs\flutter\bin`.
- Pub workspace (Dart 3.6+ feature). Root SDK constraint `^3.12.2`; members `^3.6.0`
  (intersection resolves to installed 3.12.2).
- Root app `project_cloud`: Flutter (Material), deps `cupertino_icons`; dev `flutter_lints ^6`.
- `backend`: Dart Frog `^1.1.0` (file-based routing, compiles to single binary).
  Deps: `dart_frog`, `shared`, `pubspec_parse`, `pub_semver`, `yaml`, `http`, `uuid`.
  Dev: `dart_frog_cli`, `lints ^6`, `test`.
- `frontend`: Flutter Web. Deps: `flutter`, `http`, `shared`, `graphview ^1.2.0`.
  Dev: `flutter_lints ^6`.
- `packages/shared`: pure Dart, no runtime deps (DTOs only).
- DB (planned phase 3+): Postgres. Not present yet.
- Lockfile `pubspec.lock` is committed (app repo).