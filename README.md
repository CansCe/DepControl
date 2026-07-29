# DepControl (project_cloud)

A **100% Dart** hosted web app that ingests a Dart/Flutter project by **Git URL** and
lets you **inspect & report**, **resolve & simulate** dependency changes, and track a
**registry of many projects** over time.

- **Frontend:** Flutter Web
- **Backend:** Dart Frog (file-based routing, compiles to a single binary)
- **Shared:** a plain-Dart `shared` package of DTOs used by both sides
- **DB (Phase 3+):** Postgres

## Layout

`project_cloud/` is the pub workspace **umbrella** — it is not itself an app. It ties
the members together under one lockfile / `.dart_tool/`. The runnable app is the
`frontend` member; `backend` and `shared` are its peers.

```
project_cloud/            # repo root = pub workspace umbrella (not an app)
├── packages/shared/      # DTOs: Project, DepNode, DepReport, ResolutionResult
├── backend/              # Dart Frog API
│   ├── routes/           # file-based routes -> HTTP endpoints
│   ├── sql/              # schema for tables not created through a route
│   ├── tool/             # operator CLIs (smoke test, API-diff pipeline)
│   └── lib/src/          # services (git fetch, pub.dev, analyzer, resolver) + repo
├── frontend/             # Flutter Web app  <-- the runnable app
└── tools/api_differ/     # NOT a workspace member — see "Public API diffs"
```

> Native (mobile/desktop) targets, when needed, get added to `frontend` (via
> `flutter create --platforms=...`) or a new workspace member — not to the root.

## Roadmap

| Phase | Scope | Status |
|------:|-------|--------|
| 0 | Monorepo + shared models + wiring | done |
| 1 | Ingest Git URL -> dependency report | done |
| 2 | Resolve & simulate | done — resolved from pub.dev metadata, not by running pub |
| 3 | Postgres registry + auth | done — background drift check still TODO |
| 4 | Sandbox hardening, rate limits | TODO |

Upgrade reporting sits on top of these: what a version jump changes in published
metadata (`UpgradeImpact`), and what it changes in the package's public API
(`ApiDiff`, see below).

## What a scan covers

A repository is not always one package. Adding a project reads **every**
`pubspec.yaml` in the repository, not only the one at its root: a pub workspace
resolves its members into a single root lockfile, but a directory deliberately
kept *out* of the workspace resolves independently.

Packages are merged on **name and version, not name**. This repository is its
own example — the root lockfile has `analyzer 12.1.0` while
`tools/api_differ/pubspec.lock` has `7.7.1`, and those are two different things
to assess, because an advisory applies to a version. Each entry records which
pubspecs it came from.

That makes the count *distinct resolved packages*. GitHub's dependency graph
counts dependency edges per manifest and does not deduplicate across them, so
its number for a monorepo is legitimately higher — it counts a shared package
once per manifest.

A scan downloads the repository's source tarball — one request to
`codeload.github.com` or GitLab's archive endpoint — and reads everything out of
it. Where a repository holds more packages than a single report is worth, the
libraries are read before the example apps, since the cap has to fall somewhere.

When the tarball cannot be had (the ref is gone, the download is oversized, the
bytes do not decode) the scan falls back to the older path: list the tree, then
fetch each `pubspec.yaml` over raw HTTP. That still produces a complete
dependency report — it just cannot say anything about imports. If the tree API,
which is rate limited, is unavailable too, the scan falls back to the repository
root and the report says so rather than implying the repository holds one
package.

## What the source says

Reading the tarball means reading the Dart source, not just the manifests, and
the gap between the two is worth reporting:

- **Imported but not declared.** The package resolves today only because
  something else pulls it in. Nothing in the pubspec warns before the upgrade
  that stops it, so the build breaks for a reason that is nowhere in the diff.
- **Declared but never imported.** Dead weight: a package whose advisories
  somebody triages, whose version constrains everything else's resolution, and
  which buys nothing. Build tooling, lint sets and code generators are excluded,
  since those are used without ever being imported — `analysis_options.yaml`
  `include:` lines are read for the same reason.

Both are silent — not empty — on a report whose source was never read. "Nobody
looked" and "nothing uses it" are different claims, and only one of them is
worth acting on.

## Managing the registry

Projects can be **archived** (reversible — the project and its report are kept,
and it leaves the default listing) or **deleted** (the project and its report,
with nothing kept). In the list, swipe left to archive and right to delete; the
same two actions are in each row's menu, since a swipe is invisible with a
mouse and this is a web app.

Archiving offers an undo. Deleting asks first: the server keeps no copy, so an
"undo" would mean re-adding and re-analyzing under a new id, which is not the
same thing and is not presented as if it were.

**An archived project is frozen.** Re-analysis, simulation, upgrade detail and
remediation all refuse with `409` — a snapshot that keeps re-fetching a
repository and re-querying pub.dev is not archived in any sense that matters. It
still serves its stored report, showing what the project depended on: no
`Latest` or `Status` columns, no upgrade assessment, no remediation. Advisories
and licenses stay, because they are facts about the versions in the snapshot
rather than a comparison with today. Restoring the project makes all of it work
again.

## Public API diffs

Semver says whether an author *considers* a release breaking. It cannot say
whether the declarations your code calls still exist. `tools/api_differ` answers
that by comparing the public API of two published versions, read from their own
sources.

It is **deliberately outside the pub workspace**: parsing Dart needs an analyzer
version this workspace cannot resolve (it is shared with `dart_frog_cli` and
`test`), and a path dependency would join the same resolution. It also keeps
archive fetching and source parsing out of the request path — the API only ever
reads diffs the tool already produced.

```bash
# compare two versions by hand
cd tools/api_differ && dart run api_differ http 0.13.6 1.0.0
```

The pipeline into the app:

1. Someone opens a package in the UI. If no diff is stored for that exact
   version pair, the API records the pair as wanted and says so — a missing diff
   never renders as "nothing changed".
2. An operator drains that backlog. Each pair runs the differ and is stored:

```bash
cd backend && dart run tool/fill_api_diffs.dart
```

3. Every project depending on that package now gets the answer, since a diff is
   keyed by package and versions rather than by project.

To store a single diff directly (`--dry-run` on the filler shows the backlog
without computing anything):

```bash
dart run api_differ yaml 3.1.2 3.1.3 --json | dart run tool/import_api_diff.dart
```

Both CLIs need `DATABASE_URL`, the same connection string the server uses. The
tables they use are in `backend/sql/api_diffs.sql`.

## Prerequisites

- **Dart SDK >= 3.6** (required for pub workspaces) and Flutter **>= 3.27** (workspace support)
- Dart Frog CLI: `dart pub global activate dart_frog_cli`

## Setup (pub workspace)

This repo is a single pub workspace, so you resolve everything **once from the root**:

```bash
# from C:\ProjectCloud\project_cloud — resolves shared + backend + frontend together
flutter pub get
```

(`flutter pub get` at the root covers the Flutter members too; plain `dart pub get`
works if you only touch the Dart members.)

## Run

```bash
# backend
cd backend && dart_frog dev                    # http://localhost:8080

# frontend (separate terminal)
cd frontend && flutter run -d chrome
```

## Security

### Vulnerability scanning

Advisories come from pub.dev's `/advisories` endpoint, which serves **OSV
documents sourced from the GitHub Advisory Database** — GHSA identifiers, CVE
aliases, affected ranges and CVSS vectors. That is the same data a direct
OSV/CVE integration would fetch, so there is deliberately only one source here
rather than three overlapping ones.

What the report does with it:

- **Matched by version, not by package.** An advisory applies to the version
  actually in use, so a package with a historical CVE is not reported vulnerable
  forever.
- **Scored.** The published CVSS v3 vector is parsed to a base score and banded
  critical/high/medium/low (`backend/lib/src/services/cvss.dart`, checked
  against published scores). Where an advisory ships no vector, the database's
  own band is used; where it ships neither, the severity reads *unrated* — never
  "low".
- **Ordered.** Packages are listed worst-first and the card leads with a
  breakdown, because the reader deals with the top of the list.
- **Fixed version named.** Taken from the advisory range covering your version,
  or failing that from the release history. Where no fix is published, that is
  said outright — "no fix listed" and "no fix needed" are not the same thing.
- **Blame assigned.** For a vulnerable *transitive* package, the report names
  the direct dependency that pulls it in, because that is the only thing you can
  actually bump.

### Remediation

`GET /projects/<id>/remediation` returns a **verified** fix for each advisory.
Nothing is offered on the strength of the constraint arithmetic looking right:
every candidate is put through the resolver, and kept only if the vulnerable
package actually lands on a fixed version. Three shapes, in order of preference:

1. **Raise the constraint** — the project declares the package.
2. **Bump the parent** — it does not, but bumping what pulls it in reaches the
   fix. The right fix for a transitive problem: the tree keeps its shape.
3. **Promote to direct** — nothing declared owns it, so the package is declared
   with a floor. Flagged as a pin somebody will have to remove.

Where none of those resolve, the response says whether no fix is *published* or
no change to this pubspec can *reach* one — different problems with different
next steps. Each plan reports the knock-on version changes too, since one
advisory can drag a dozen packages with it.

Remediations are shown as a pubspec diff. Opening pull requests would need
GitHub write credentials, which this app deliberately does not hold.

## License compliance

Every dependency's license, judged against a policy, with a manifest to hand to
whoever signs off on shipping.

Licenses come from **pub.dev's own detection** — it analyses each published
version's `LICENSE` file and publishes the result as tags (`license:mit`,
`license:osi-approved`, `license:fsf-libre`, or `license:unknown`). That is the
same answer shown on the package page, so a report here matches what a reviewer
sees if they look the package up by hand.

- **Read per version, and it says when it could not be.** pub.dev keeps one
  analysis per version and drops the old ones, so a project pinned to an old
  release has none. The scan then reads the latest release instead and labels
  the finding as such — relicensing between the pinned version and today is
  exactly what this exists to catch, so the substitution is printed rather than
  smoothed over.
- **Classified by obligation, not by name.** A policy is decided on whether a
  dependency can oblige you to publish your own source, so licenses are grouped
  into permissive, weak copyleft, strong copyleft, network copyleft (AGPL — the
  one that catches a hosted service that never ships a binary), and not-open-
  source. The table is `backend/lib/src/services/license_catalog.dart`.
- **Never guessed.** A license the catalog does not recognise keeps its SPDX id
  and gets no family, which under the standard policy means a human looks at it.
  Filing an unrecognised license under "probably fine" is the one error that
  gets a package shipped.
- **"Unidentified" is a finding, not a clearance.** Code with no identifiable
  grant is not licensed to you by default, so it is never reported as clean.
- **Packages that are not on pub.dev are not looked up there.** An SDK, path or
  git dependency has no published analysis, and pub.dev *does* serve packages
  under some of those names — `flutter` and `sky_engine` there are discontinued
  placeholders with a few dozen downloads a month. Reading a license off one of
  those and printing it beside the SDK's name would be a fabricated answer that
  happens to look plausible. They are listed as unchecked, with where they come
  from, alongside packages from reports that predate this feature. Neither is a
  finding: "we could not check this" is not "somebody must review this", and
  filing them together buries the ones that are.

### Policy

`GET`/`PUT`/`DELETE` `/policy/licenses` holds one policy per user. Until someone
writes one, the standard policy applies: permissive allowed, weak copyleft
needs review, strong/network copyleft and non-open-source forbidden, and
anything unidentified needs review. The report says which of the two you are
reading — "your policy forbids this" and "nobody here has written a policy and
the default forbids this" send you to different places.

Rules are written per obligation family, with per-license exceptions
(`{"licenses": {"SSPL-1.0": "allowed"}}`) for the ones every policy accumulates.
The UI edits the families; the exceptions go through the API.

**Dev dependencies are not checked by default.** A GPL code generator is not
linked into what you ship. Which packages those are is worked out from the
graph, not from `dev_dependencies` alone: a package that only a dev dependency
pulls in is marked transitive and still does not ship. Set
`checkDevDependencies` if you redistribute your toolchain.

### Manifest

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "$API/projects/$ID/licenses?format=csv" -OJ
```

One row per dependency — including the permissive majority, because a manifest
is an inventory first and an exception list second, and a reviewer needs to see
that the whole tree was examined. Unchecked packages stay in the same table,
each with the reason, so filtering cannot hide them. Drop `?format=csv` for
JSON; the response carries
the policy it was evaluated under, so the document is still readable six months
later.

The endpoint reads the stored report and runs the policy over it. It makes no
outbound calls, so it is not rate limited and it works for an archived project —
a license is a fact about the versions in the snapshot, the same way an advisory
is. Re-analyze first if you want today's dependencies.

The table it needs is in `backend/sql/license_policies.sql`.

### What the server assumes about its inputs

Every project URL, ref and pubspec comes from a user, so:

- **Repository fetches are constrained.** Only `github.com` and `gitlab.com`
  over https; owner, repo and ref are validated before any request. A ref like
  `../../someone/else/main` normalises the repository out of the raw-content URL
  and would fetch a different project's pubspec — it is rejected rather than
  escaped.
- **Responses are bounded.** Size caps and timeouts on repository fetches and
  pub.dev calls; a remote host is under no obligation to be small or prompt.
- **Package names are validated, not escaped.** They arrive from fetched
  pubspecs and are interpolated into pub.dev request paths.
- **Nothing fetched is executed.** Resolution is computed from pub.dev metadata;
  no subprocess, no `dart pub get`, no build hooks. `tools/api_differ` parses
  package sources but never runs them, and decompresses archives in memory with
  caps on compressed size, expanded size and file count.
- **Projects are owner-scoped.** Reads are filtered by the JWT's `sub` in the
  query rather than after the fact, and a project owned by someone else is a 404
  rather than a 403, which would confirm the id exists.
- **Expensive endpoints are rate limited** per user — see
  `RATE_LIMIT_PER_MINUTE` in `.env.example`.

Still run the backend in a locked-down container with no outbound access except
pub.dev and the git hosts.
