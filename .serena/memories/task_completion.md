# Task Completion Checklist

Run from repo root `C:\ProjectCloud\project_cloud`:

1. `flutter pub get`  (if any pubspec/workspace membership changed)
2. `dart format .`
3. `flutter analyze`  — must be clean for code you touched.

Note baseline: the scaffold currently has KNOWN pre-existing analyze errors in stub code
(`backend/lib/src/services/pubspec_analyzer.dart` — `Version.tryParse`;
`frontend/lib/widgets/dep_graph.dart` — graphview `FruchtermanReingoldAlgorithm` API).
Don't attribute these to your change; do fix them if you touch that code.

4. Tests where they exist: `dart test` (backend/shared) / `flutter test` (frontend/root).
5. CodeGraph is planned but not set up yet — no `.codegraph/` index exists.