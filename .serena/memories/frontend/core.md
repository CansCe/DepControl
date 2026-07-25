# Frontend (Flutter Web UI)

Pkg `frontend`. THE single runnable app of the workspace (the repo root is a pure
umbrella, not an app). Talks to the backend API; renders dependency reports + graph.

## Layout
- `lib/main.dart` — app entry.
- `lib/api/api_client.dart` — HTTP client to backend (`package:http`).
- `lib/widgets/` — `dep_graph.dart` (graphview), `dep_table.dart`, `dep_status_chip.dart`.
- `web/` — web target. (Native targets added later via `flutter create --platforms=...` here.)

## Run
- `cd frontend; flutter run -d chrome`.

## graphview API note
Uses `graphview ^1.5.0`. `FruchtermanReingoldAlgorithm` takes a **positional**
`FruchtermanReingoldConfiguration(iterations: ...)` (config object), not a named
`iterations:` arg — that older 1.2.x form was fixed on 2026-07-25. Analyzes clean.