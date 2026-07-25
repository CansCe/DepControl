# Suggested Commands (Windows / PowerShell; Git Bash also available)

All from repo root `C:\ProjectCloud\project_cloud` unless noted.

## Resolve (workspace-wide, run once from root)
- `flutter pub get`   # resolves root app + shared + backend + frontend together
- `dart pub get`      # enough if only Dart (non-Flutter) members touched
- `dart pub workspace list`   # confirm all 4 members are seen

## Analyze / format
- `flutter analyze`   # analyzes the whole workspace
- `dart format .`

## Run
- Backend:  `cd backend; dart_frog dev`        # http://localhost:8080
- Frontend: `cd frontend; flutter run -d chrome`
- Root app: `flutter run` (from root)

## Test
- `dart test` inside `backend` / `packages/shared`; `flutter test` inside `frontend` or root.

## dart_frog CLI
- Requires `dart pub global activate dart_frog_cli` once.

## Env note
- `dart`/`flutter` are on PATH as `dart.bat`/`flutter.bat`. A shell opened BEFORE the PATH
  was set won't see them — open a fresh shell.

## Windows shell specifics
- Chain commands with `;` (PowerShell), not `&&`.
- Git Bash tool is available for POSIX-style commands and `find`/`grep`.