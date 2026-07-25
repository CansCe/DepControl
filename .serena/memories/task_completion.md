# Task Completion Checklist

Run from repo root `C:\ProjectCloud\project_cloud`:

1. `flutter pub get`  (if any pubspec/workspace membership changed)
2. `dart format .`
3. `flutter analyze`  — must be clean for code you touched.

Baseline (as of 2026-07-25): workspace analyzes with **no errors**. Remaining items are
lint-level only, all in stub code: `backend/lib/src/services/pubspec_analyzer.dart`
(`unnecessary_null_comparison` ×3) plus a few info lints (relative `lib` imports in Dart
Frog routes — should be `package:backend/...`; `unnecessary_library_name` in
`packages/shared/lib/shared.dart`). Fix these if you touch that code; don't attribute them
to your change otherwise.

4. Tests where they exist: `dart test` (backend/shared) / `flutter test` (frontend).
5. CodeGraph is planned but not set up yet — no `.codegraph/` index exists.