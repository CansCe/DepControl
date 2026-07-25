# Frontend (Flutter Web UI)

Pkg `frontend`. Talks to the backend API; renders dependency reports + graph.

## Layout
- `lib/main.dart` — app entry.
- `lib/api/api_client.dart` — HTTP client to backend (`package:http`).
- `lib/widgets/` — `dep_graph.dart` (graphview), `dep_table.dart`, `dep_status_chip.dart`.

## Run
- `cd frontend; flutter run -d chrome`.

## Known issues (pre-existing stub bugs)
- `lib/widgets/dep_graph.dart:20` — `graphview` `FruchtermanReingoldAlgorithm` constructor
  API mismatch (expects a positional arg; no `iterations` named param in resolved version).
  Reconcile code to the resolved `graphview ^1.2.0` API (or pin the version the code targets).

## Note
Distinct from the root `project_cloud` Flutter app (`lib/main.dart` at repo root), which is
currently the default starter app. Relationship between the two Flutter apps is not yet
defined.