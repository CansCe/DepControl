# DepControl (project_cloud) — Core

100% Dart web app: ingest a Dart/Flutter project by Git URL, inspect/report deps,
resolve & simulate dep changes, track a registry of projects over time.

## Repo = single Dart pub workspace
- Root is `project_cloud/` (the git repo root). It is the pub workspace **umbrella
  only** — NOT itself an app. Root `pubspec.yaml` is a minimal package that just
  declares `workspace:` members (no flutter dep, no `lib/`, no platform dirs).
- Members (each has `resolution: workspace`, all share one root lockfile + `.dart_tool/`):
  - `packages/shared` — plain-Dart DTOs shared by backend+frontend (pkg name `shared`).
  - `backend` — Dart Frog API (pkg name `backend`). See `mem:backend/core`.
  - `frontend` — Flutter Web app — the single runnable app. See `mem:frontend/core`.
- `dart pub workspace list` shows all four packages (project_cloud, shared, backend, frontend).
- Resolve everything once from repo root: `flutter pub get`. See `mem:suggested_commands`.

## Invariants
- One resolution for the whole workspace → a single version of any shared dep must satisfy
  every member (this is why lint deps were unified to `^6`). New deps must not create
  cross-member version conflicts.
- `shared` is depended on as `shared: ^0.1.0` from backend/frontend and resolves to the
  local workspace member (not pub.dev).
- Native (mobile/desktop) targets, when needed, get added to `frontend`
  (`flutter create --platforms=...`) or a new workspace member — never to the root.
- History: previously a separate `depcontrol` monorepo at `C:\ProjectCloud`; on 2026-07-25
  folded into `project_cloud`. Same day, the leftover default Flutter starter app at the
  root (from `flutter create`) was removed so the root is a pure umbrella.

## Status
Early scaffold ("stubs in place", phases 0–2). Workspace analyzes with NO errors; some
lint-level warnings/infos remain in `backend`/`shared` — see `mem:backend/core`.

## Map
- `mem:tech_stack` — languages, frameworks, version pins.
- `mem:suggested_commands` — resolve / run / analyze / dart_frog / git (Windows).
- `mem:conventions` — code style, DTO/analysis conventions.
- `mem:task_completion` — what to run before calling a task done.
- `mem:backend/core`, `mem:frontend/core` — per-module detail.