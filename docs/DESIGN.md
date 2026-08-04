# DepControl — design notes

Why the app behaves the way it does: what a scan reads, what it costs, what it
refuses to guess, and where each answer comes from. The [README](../README.md)
covers what the app does and how to run it; this file is the reasoning behind
it, kept because most of these decisions have a failure mode attached and the
failure mode is the useful part.

## Ecosystems

A dependency report is the same document whichever ecosystem produced it —
which packages, at which versions, with which advisories and licenses,
reachable from which manifests. None of that is a question about pub.dev, so
only four things are per-ecosystem (`backend/lib/src/ecosystem/`): the file
names, the manifest syntax, the registry protocol, and the constraint dialect.
Advisories are OSV documents and versions are semver on both sides, so scoring,
banding, blame assignment, license classification, resolution and remediation
are shared code that never learns which ecosystem it is serving.

| | Dart | npm |
|---|---|---|
| Manifest | `pubspec.yaml` | `package.json` |
| Lockfile | `pubspec.lock` | `package-lock.json`, `npm-shrinkwrap.json` |
| Registry | pub.dev | registry.npmjs.org |
| Advisories | OSV.dev | OSV.dev |
| Licenses | pub.dev's detection | the publisher's `license` field |
| Imports | `import 'package:…'` | `import`/`require`, `/// <reference types>` |
| Size | the archive's `Content-Length` | `dist.unpackedSize` |
| Resolve & simulate | yes | not yet |

**A repository can be more than one.** A Flutter app with a JavaScript front
end is the ordinary shape of that. Source files are attributed to the nearest
manifest *of their own kind* — in a repository holding both, the nearest
manifest of any kind is regularly the wrong one — and where two manifests share
a directory the report names the ecosystem alongside it.

Package identity carries the ecosystem, because `path`, `args`, `crypto`,
`http` and `stack_trace` are published on both registries, by different people,
doing different things. Merging those on name and version would attribute one's
advisories to the other.

### What differs, and why it is not smoothed over

- **npm's `^` is not pub's.** `^0.0.3` admits nothing but 0.0.3 on npm; pub
  reads the same text as `>=0.0.3 <0.1.0` and admits 0.0.4. npm also has `||`
  unions, `x` wildcards and hyphen ranges, none of which pub has. The ranges are
  translated rather than handed to pub's parser, which would be wrong in the
  direction that matters — admitting versions the manifest excludes.
- **npm licenses are weaker evidence.** pub.dev analyses each version's
  published LICENSE file; npm reports whatever the publisher typed in a field,
  and frequently that is an SPDX *expression* like `(MIT OR Apache-2.0)`. Those
  keep their text and get no family, which under the standard policy means a
  human looks at them.
- **`yarn.lock` and `pnpm-lock.yaml` are not read.** They are deliberately not
  listed as lockfiles either, because a lockfile the parser finds and cannot
  read would have a project report as having no locked versions at all. Their
  absence instead falls to resolving the declared constraints, which the report
  labels as inferred.
- **npm installs one package at several versions; this reports one.** The
  hoisted copy — the shallowest `node_modules/` path, which is what the tree
  resolves to unless something forced otherwise. A nested copy at a different
  version is missing from the report, along with any advisory that applies only
  to it.
- **`peerDependencies` are not counted.** A peer is a requirement a package
  makes of whoever installs it, not something it brings along.
  `optionalDependencies` *are* counted, because they ship when they install.

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

## What a scan costs

Enriching a package means asking a registry about it, and a large repository is
where the arithmetic stops being free. A scan is bounded by round trips, so the
two numbers worth watching are **how many requests it makes** and **how deep the
serial chain is per package**.

Both are held down at the client layer rather than in the analyzer, which is
where `PackageRegistry` says request shaping belongs.

**Each distinct package costs four requests**, not four per manifest. pub.dev's
package document already embeds every listed version's pubspec, so the latest
version, the resolution input and the graph edges all come out of one fetch; npm
serves the same three from one abbreviated packument. What is left is the
advisory query, the licence read and — for pub.dev, which publishes no size
field anywhere — a `HEAD` on the archive. Answers are cached in the client, so a
package reached from twenty manifests still costs those four.

Measured against a synthetic repository, before and after that caching:

| Repository | Requests before | After |
|---|---|---|
| 1 manifest × 10 packages | 50 | 40 |
| 5 manifests × 10 packages | 250 | 40 |
| 20 manifests × 20 packages | 2,000 | 80 |
| 20 manifests × 400 packages | 40,000 | 1,600 |

The shape is the point: the cost is now proportional to *distinct packages*,
which is the same number the report counts, rather than to packages × manifests.

**And against a real one.** `opengeos/GeoLibre` — 13 manifests, 1491 resolved
packages — scanned end to end with `tool/measure_scan.dart`, compiled, on the
same machine:

| | before | after |
|---|---|---|
| analysis | 186 s | **94 s** |
| peak RSS | **1035 MB** | **350 MB** |

The memory is the number that mattered. `fly.toml` allocates **512 MB**, so this
repository did not fail slowly — it was OOM-killed partway through, every time,
which took the in-flight request and the in-memory scan progress with it and
left the browser polling a machine that had already restarted. What fixed it was
not the request count but keeping the *distilled* form of a registry document
(see `_Packument`, `_PackageDoc`) rather than the decoded JSON it came from.

Measure with a compiled binary or not at all: the same scan reads 574 MB under
`dart run`, because the JIT VM carries machinery the deployment does not.
`Dockerfile` ships `dart compile exe`, and only that number says anything about
whether a scan fits.

**Cached answers expire**, and the expiry is not a detail. Most of what a
registry says is a fact about the rest of the world — the newest release moves
when somebody else publishes, an advisory appears when somebody else files one —
so a cache with no lifetime would turn a long-running server into one reporting
whatever was true when it started, and a nightly rescan would never notice
anything. Ten minutes, which is long enough that any one scan asks once. Facts
about an already-published artefact cannot go stale that way — an archive's
length, a released version's declared licence — and those are held for hours.

**Nothing waits on an answer it does not need.** Size and graph edges depend
only on the installed version, which the lockfile already gave us, so they go out
alongside the request describing the package rather than after it; the advisory
query and the version lookup are different hosts and go out together. Two waves
instead of four hops.

**A registry that will not answer degrades the node, not the scan.** Every
lookup is bounded and falls back to *unmeasured* — no latest version, an
undetermined licence, a null size — never to a value that would read as a
measured negative. The per-request timeouts in the clients are the first line;
the analyzer's own budget is the one that catches a socket which is open and
simply never going to reply, which is the failure that used to strand eight
workers and take a large scan down with them. A partial report that says what it
could not reach is worth having. A 500 after four minutes is not.

### A scan is not a request

It used to be. The analysis ran inside the POST that asked for it and the report
came back in the response, which made a scan exactly as durable as the browser
tab — and on a deployment that scales to zero, exactly as durable as the
connection holding the machine up. Closing the page ended the work.

So `POST /projects` and `POST /projects/{id}/refresh` write a row to `scan_jobs`
and answer `202`. `ScanRunner` drains it. Three consequences worth stating:

- **No project is created until the scan succeeds**, exactly as before. Creating
  one up front to hang the scan off would leave an empty project behind every
  time somebody mistyped a URL.
- **The request still refuses what it can judge without the network.** A host
  this cannot read is a `400` at the time of asking, not a job that turns up
  failed a minute later. Whether a repository *exists* is not in that category
  and stops being something the request answers.
- **`GET /scans/{id}` became owner-scoped.** While progress lived in a map keyed
  only on an id the client invented, a guessed id read somebody else's scan. It
  is a `404` for another owner, not a `403`, for the reason every other lookup
  here is.

**The worker is the same process as the API.** A separate one would have to be
always-on: the only thing that knows a scan was asked for is the API, so a worker
that scaled to zero would have nothing to start it, and one that did not scale to
zero is an always-on machine under a different name — which was ruled out on
cost. One image, one machine, started by the proxy on a request.

**Which means the app has to stop itself.** Fly's `auto_stop_machines` counts
connections, so it stops a machine with no open request however busy the process
is — harmless while the scan *was* the request, fatal now. It is off, and
`IdleWatchdog` does the job from inside with one extra condition: no request for
`IDLE_SHUTDOWN_SECONDS` **and** nothing in the scan queue. It stops by exiting 0,
which under an `on-failure` restart policy leaves the machine stopped until the
next request starts it. Unset means never, which is what every local run gets.

**It asks two questions, not one, and the order matters.** First, is a scan
running *in this process* — which needs no database and is therefore always
answerable. Only then, is anything outstanding in the queue.

The first version asked only the second, and treated "cannot read the queue" as a
reason to stay up: staying up costs money, stopping on top of a running scan
costs the scan. That is right for a blip and wrong for anything that does not
clear. A missing table, a revoked credential or a mistyped `DATABASE_URL` never
comes back on its own, so the machine stayed up for ever and announced it only as
a bill — the exact outcome the watchdog exists to prevent, arrived at by the
watchdog. It happened on the first deploy, against a database the migration had
not been applied to.

So the uncertainty is bounded. After a minute of consecutive failures with
nothing running here, the machine stops: it cannot claim a job it cannot read, so
there is nothing left to stay up *for*. The next request starts it again, and if
the queue is still unreadable it stops again — a loop paced by traffic rather
than a machine running all night. A single successful read resets the patience,
so two blips either side of a working minute do not add up.

**Progress is written twice, on purpose.** The in-memory `ScanProgressStore` is
the live copy and stays the hot path; the row is flushed about once a second and
is the durable one. `packageDone()` fires once per package — 1,491 times on the
largest repository measured — and a write each would cost more than the registry
calls it is reporting on. The flush doubles as the heartbeat, because they happen
together.

**A machine that dies loses the attempt, not the request.** A claimed job whose
heartbeat has gone stale is re-claimed by the next machine to drain, bounded by
`attempts` so a scan that reliably kills its worker is eventually reported as
failed rather than retried forever. It restarts from the beginning: a
half-scanned repository is not a resumable thing, and pretending otherwise would
mean persisting per-package state to save a minute.

The honest limit, and the one to quote: **a scan runs until it finishes or the
server stops.** A deploy still interrupts one. What changed is that interrupting
it no longer loses it.

### Watching a scan

The scan says nothing until it is over, so the only way to learn what it is doing
is to ask. That was true when it was a request and is still true now; what
changed is that asking is no longer a side channel onto an open connection. It is
the only channel, and it works from a device that never started the scan.

A null answer is still not an error. A scan this account never asked for reads
the same as a poll that could not reach the server at all, and neither says
anything about the scan — both mean *no news*, never *no progress*, and both
leave whatever was last known on screen under an indeterminate bar. What no
longer produces one is a restart or a second instance, which is most of what used
to.

**What was wrong until phase 0.6** was not the 404, which is correct, but that
the client never stopped asking. A flat 1200 ms poll is fifty requests a minute
for as long as the tab stays open, and the run of them observed in the metrics
was not a bug in the poller at all — the machine had been OOM-killed and
restarted, so the scan and the progress went with it and no later answer was ever
going to differ. That the flood was a *symptom* is why the fix was a small one
and the memory work above was the real one.

Now the interval doubles while the server says nothing, to a fifteen-second
ceiling, and the poller gives up once the silence has run for two minutes.
Silence is measured in time rather than in a count of replies, because with a
stretching interval those are not the same question, and the one worth asking is
how long it has been quiet. A single answer resets both — a scan that goes quiet,
recovers and goes quiet again has not been silent throughout.

Two things it deliberately does not do. It does not stop the **scan**, which is a
job on the server and finishes there; only this client's view of it is abandoned,
and the message says exactly that rather than calling it a failure, because
telling somebody a running scan failed invites them to start a second one. And it
does not clear what it last knew — giving up is about not asking again, not about
forgetting the answer, and a bar that emptied itself when the poller went quiet
would claim a regression that never happened.

`GET /scans` is the other half. Opening the app asks what this account still has
running and re-attaches to it, because a durable scan that the client cannot see
is worse than no durable scan: the panel would be empty and the obvious next move
would be to start the same work again.

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

## What a dependency weighs

Each package carries the size its registry publishes, and the report totals
them. The number that makes an unused dependency worth deleting is not what
that package weighs — it is what comes out **with** it: the transitive tail
nothing else pulls in. A 40 KB helper that is the only thing holding up eleven
other packages costs the tree all twelve, and that is the figure the report
gives for dropping it.

Asked about a *set* of packages rather than one at a time, because the answers
do not add up. Two unused packages that both pull in the same helper each
reclaim nothing of it alone, and dropping both reclaims it.

**This is install weight, not bundle size.** What survives tree-shaking and
minification into a production bundle depends on which symbols the project
imports and which bundler runs over them, and no registry knows either — the
tools that report bundle size run a bundler to find out. Reporting a download
figure under that name would be wrong in the direction people act on.

The two registries are also not answering the same question, so the report
keeps their totals apart rather than adding them:

- **npm states installed bytes.** `dist.unpackedSize` is recorded at publish
  time and arrives in the abbreviated packument the scan already fetches, so it
  costs no request. It is absent for anything published before npm began
  recording it — `sax` carries it on 9 of its 54 releases — and those small old
  packages are what a tree is full of.
- **pub.dev publishes no size at all,** so the figure is the `Content-Length` of
  the `.tar.gz`, taken with a HEAD. That is the compressed download. Source
  expands several times over, by a factor that depends on what the package is
  made of, so a multiplier would turn a measurement into an invention.

A package with no published size reports none, never zero, and every total says
how many it had to leave out. A tree that reported its unmeasured half as
weightless would understate itself in exactly the direction this exists to
expose.

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

## Report history

Every analysis is kept, so a project's dependencies can be compared with what
they were. `GET /projects/<id>/history` lists the states they have been in,
newest first; `?revision=<id>` returns one of them in full.

**A revision per change, not per scan.** A project re-scanned nightly and never
touched would otherwise produce three hundred identical entries a year with the
four that matter somewhere inside them. A scan that finds no difference marks
the newest revision seen again, so each row carries both when that state was
first seen and when it was last confirmed — "unchanged for six months" and
"nobody has looked in six months" are different facts about a project, and the
difference is usually the point.

What counts as a difference is decided by a digest over the packages, their
resolved versions and kinds, the advisories against them, their licenses, and
the manifests the scan read (`backend/lib/src/repository/report_digest.dart`).
Two things are deliberately excluded:

- **`latest` and `status`.** Those move whenever anybody else publishes a
  release. A project whose own dependencies have not moved has not changed, and
  recording that would file the rest of the ecosystem's activity under this
  project's history.
- **When the scan ran.** Otherwise every scan is a change and the history is a
  log of scans.

A newly published advisory against an unchanged version *is* a change, and so is
a relicensing — those are the two things a re-scan of an untouched project
exists to find.

Comparison is against the newest revision only, so a project that goes A → B → A
has three revisions rather than two. Folding the second A into the first would
stretch one row's window across the period when B held, which is a claim about
the project that nobody checked.

Revisions are capped per project (`maxRevisionsPerProject`), oldest dropped
first, since each holds a full node list. The table is in
`backend/sql/report_history.sql`, which also carries the existing `dep_reports`
rows over as each project's first revision.

## What changed

`GET /projects/<id>/changes` compares two of a project's stored reports. With
no arguments, the two newest — "what changed last time anything did".
`?from=<revision>&to=<revision>` compares any two, in either order, since
"what would reverting look like" is a legitimate question.

Packages are matched on **ecosystem and name**: the version is the thing being
compared, so it cannot also be part of the identity, and npm and pub.dev both
publish `path`, `http` and `crypto`.

What a change carries:

- **How far the version moved**, in the same vocabulary as the upgrade
  assessment — breaking, minor, patch — with the direction kept separate,
  because a downgrade across a major boundary is as breaking as the upgrade
  was. The pre-1.0 rules are each ecosystem's own: both treat a minor change
  below 1.0.0 as breaking, and npm goes further, treating the patch as breaking
  at `0.0.x`.
- **Advisories that newly apply.** Three ways that happens — newly published,
  the package moved into an affected range, or a new package arrived carrying
  it — and they are not distinguished, because they are the same news.
- **Advisories that no longer apply**, called *cleared* rather than *fixed*. An
  advisory clears because the package moved to a fixed version, because it left
  the project, or because it was **withdrawn** — and a withdrawal means the
  finding was never right rather than that anybody repaired anything. Two
  reports cannot tell those apart, so the name does not claim to.
- **Relicensing**, but only on a package that did not move. A different licence
  on a different version is part of that move rather than a separate event.
- **How the package is reached**, when a direct dependency becomes transitive
  or the reverse.

A repository can resolve one package at two versions at once — this one does.
Where that happens there is no single "it moved from here to there", so the
differing versions are listed as additions and removals rather than an invented
bump.

The diff is derived, never stored: two reports and this endpoint always produce
the same answer, so nothing has to be migrated when the comparison learns to
notice something new.

## Being told

A change nobody reads is a change nobody acts on. `tool/rescan.dart` re-scans
every tracked project, stores what it finds, compares it with the previous
revision, and announces anything that clears a bar you set.

```bash
cd backend && dart run tool/rescan.dart --all
```

It is a CLI rather than a timer inside the server, because the API is deployed
with `min_machines_running = 0` and stops between requests — an in-process
schedule would fire only while somebody happened to be using the app, which is
exactly when they do not need to be told. `.github/workflows/rescan.yml` runs it
daily; cron or a Fly scheduled machine would do as well. It needs `DATABASE_URL`,
the same string the server uses.

### What gets announced

`POST /notifications` registers a Slack or Teams incoming webhook, optionally
scoped to one project. Two rules, both opt-in, either sufficient:

- **A new advisory**, at or above `minSeverity`. Compared against the *worst*
  new advisory in the change, so one critical among nine lows clears a
  threshold of critical. An advisory nobody has rated clears every threshold —
  "we do not know how bad this is" is not a reason to stay quiet, the same
  rule that stops it being reported as low.
- **A breaking version move**, in either direction, advisory or not.

A target with both rules off is refused rather than saved: one that can never
fire is indistinguishable from one that works, until the day it matters.

### At most once

A change is announced at most once per target. The claim is written to the
database *before* the request goes out, keyed on the revision rather than on
the run, so a sweep that fires twice — or a machine that dies mid-send — cannot
produce a second alert. The cost is that a genuinely lost send is not retried,
which is the right way round: an alert repeated days later, about a change
already dealt with, does more damage to a channel's credibility than a missed
one does. A failed send stays claimed for the same reason — retrying on a
schedule is how a broken webhook becomes a loop.

Archived projects are not swept. Re-analysis already refuses them with `409`,
and a background job that quietly re-fetched them would be doing the one thing
archiving exists to stop.

### The webhook URL is a credential

Anything holding an incoming-webhook URL can post to the channel, so:

- **It is never returned.** A stored target reads back as its host and the last
  few characters of its path — enough to tell two apart, not enough to use.
  There is deliberately no "reveal" parameter.
- **Only known hosts.** `hooks.slack.com`, `*.webhook.office.com` and
  `*.logic.azure.com`. Everything else this application fetches is from a host
  *it* chose; a notification target is a URL a user supplies that the server
  then requests from inside its own network, which is a server-side request
  forgery primitive unless it is constrained. The constraint is an allowlist,
  because a denylist of private ranges loses to DNS rebinding, redirects, and
  the several spellings of `127.0.0.1` that parse as something else.
- **Re-validated on every send**, rather than trusted from storage: the
  allowlist can narrow, and a row can be edited by something other than this
  application.

Nothing is ever delivered from a request — only `tool/rescan.dart` posts to a
webhook — so no caller can use these endpoints to make the server reach an
address on demand.

**A Teams caveat.** Messages are sent as a MessageCard, which the Office 365
connector renders. Microsoft is retiring that in favour of Power Automate
workflows, which want an Adaptive Card; a workflow using the stock template
will not render these properly. Email is not implemented — it needs a provider
and credentials, and neither has been chosen.

## Release notes

A version moved; what did its author say about it? `GET
/projects/<id>/changes?changelogs=true` answers that for every package in a
diff, with the sections covering `(from, to]` — the ones the move actually
crosses, rather than a link to twelve releases' worth of notes and the job of
working out which apply.

The notes are kept **verbatim**. They are the author's account of their own
release, and paraphrasing them would be this application making claims about
somebody else's software.

Nothing is fetched in a request. A lookup that misses records what it wanted
and the backlog is drained out of process, exactly as the API diffs are:

```bash
cd backend && dart run tool/fill_changelogs.dart
```

**One archive answers many questions.** A changelog is cumulative, so reading
`foo 3.0.0` stores the sections for 2.x and 1.x too — and the aggregator checks
what is stored *before* asking whether a particular archive was read, so a
project moving to 2.0.0 is served from an archive somebody else's upgrade
already pulled.

**Empty is two different answers**, and they are not shown alike: nobody has
read the archive yet (queued — check back), or it was read and nothing covers
this range (the package ships no changelog, or did not write about these
versions). A changelog nobody has read must never render as a release that
said nothing.

### What it reads, and what it will not

The archive is fetched from a **constructed** URL — never from the registry's
own metadata, since npm publishes a `dist.tarball` field and following it would
let a package's publisher choose which host this server contacts. It is
decompressed in memory, so a crafted entry path has nowhere to escape to; the
compressed size, expanded size, file count and the changelog's own size are all
capped; and only the changelog is decoded.

Only a changelog at the archive root counts. One under `example/` or
`test/fixtures/` belongs to something else, and npm packages ship other
projects' files more often than one would like.

There is no changelog *format*, only a convention, so the heading parser is
permissive — `## 1.2.3`, `# [1.2.3]`, `## v1.2.3 (2024-05-01)` all read. Two
things it deliberately refuses: a heading that merely mentions a version
(`## Upgrading to 2.0.0` is prose in somebody's notes, and treating it as a
release boundary splits that release in half), and anything inside a fenced
code block (migration instructions routinely paste a manifest containing what
looks exactly like a heading).

**npm coverage is thinner than pub's**, and not because of this code: many npm
packages ship no `CHANGELOG.md` in their tarball at all. `lodash` publishes to
GitHub Releases instead, and `@babel/core` keeps one changelog at its monorepo
root rather than per package. Both read successfully and yield nothing, which
is reported as what it is.

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


## Security

### Vulnerability scanning

Advisories come from **OSV.dev**, for both ecosystems — GHSA identifiers, CVE
aliases, affected ranges and CVSS vectors. One source, one code path, and every
test in either ecosystem exercises the same version matching, scoring and
banding.

Dart's used to come from pub.dev's `/advisories` endpoint. Two reasons they no
longer do. npm publishes nothing comparable per package, so OSV had to be
spoken to regardless; and pub.dev's endpoint **serves withdrawn advisories**.
Asking it about `dio` returns `GHSA-jwpw-q68h-r678`, retracted in October 2023,
with nothing in the response marking it as different from the live advisory
beside it — so `dio` was reported vulnerable to a finding its own database had
taken back. OSV excludes withdrawn entries from a query, and `Advisory.affects`
refuses them besides.

The two sources were compared package by package before the switch. They agree
on every live advisory, field for field, and disagree only where pub.dev is
serving something withdrawn.

**An empty advisory list is not a clean bill of health.** OSV does not
distinguish "nothing published" from "the database could not be reached", and a
report presently reads both as no advisories. That is a real weakness of this
design and it is stated here rather than papered over.

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

## What the server assumes about its inputs

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
