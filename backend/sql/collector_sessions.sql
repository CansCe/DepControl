-- One-shot grants for the local collector to submit a bundle without a
-- Supabase JWT in its hands.
--
-- The web app mints a row while the person is signed in, shows them a code,
-- and the collector binary posts a bundle against it. The grant is narrower
-- than the session that minted it on purpose: it can do exactly one thing —
-- submit one bundle — and nothing it carries can read a project or a report.
-- See phase 1.6 in the roadmap for the full disclosure statement.
--
-- code_hash, never the code. A dump of this table is a set of dead rows, not
-- a set of live grants — the same reason `scan_jobs` keys itself on a
-- client-chosen id rather than anything guessable, taken one step further
-- because this row's whole purpose is to be a bearer credential.
--
-- project_id null means "create a new project" (POST /projects); set means
-- "re-upload to this one" (POST /projects/<id>/bundle) — the same two shapes
-- `scan_jobs.project_id` already distinguishes for a scan once it exists.
--
-- scan_id is filled in once the code is claimed and a scan has been queued
-- from it, so `GET /collector/sessions/<id>` can hand the polling page
-- straight to `ScanQueue.reattach` with nothing more to ask.
--
-- RLS is enabled with no policies, matching every other table here: the
-- backend connects as the database user, and nothing should reach this table
-- through PostgREST with an end user's key.

create table if not exists collector_sessions (
  id         uuid        primary key default gen_random_uuid(),
  owner_id   uuid        not null references auth.users (id) on delete cascade,
  code_hash  text        not null unique,
  project_id uuid        references projects (id) on delete cascade,
  scan_id    text        references scan_jobs (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  claimed_at timestamptz
);

-- "What is still open for me", for the web page's own list if it ever needs
-- one, and for the mint route to reason about a caller's outstanding codes.
create index if not exists collector_sessions_owner_idx
  on collector_sessions (owner_id, created_at desc);

-- The claim path's whole query: a code hash that is not yet claimed and has
-- not expired. Partial, because claimed and expired rows are the overwhelming
-- majority soon after this ships and none of them are ever a candidate.
create index if not exists collector_sessions_claimable_idx
  on collector_sessions (code_hash)
  where claimed_at is null;

alter table collector_sessions enable row level security;
