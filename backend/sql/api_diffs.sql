-- Public-API diffs between two published versions of a pub package, and the
-- comparisons that have been asked for but not computed yet.
--
-- The API never writes to `api_diffs`: rows arrive from `tools/api_differ`,
-- which runs out of process (see backend/tool/fill_api_diffs.dart). A request
-- that cannot be answered inserts into `api_diff_requests` instead, which is
-- the queue that tool drains.
--
-- Neither table is owner-scoped. `yaml 3.1.2 -> 3.1.3` is the same comparison
-- for every user and names only published packages, so one computation serves
-- every project that depends on it.
--
-- RLS is enabled with no policies, matching `projects` and `dep_reports`: the
-- backend connects as the database user, and nothing should reach these tables
-- through PostgREST with an end user's key.

create table if not exists api_diffs (
  package      text        not null,
  from_version text        not null,
  to_version   text        not null,
  changes      jsonb       not null default '[]'::jsonb,
  generated_at timestamptz not null default now(),
  primary key (package, from_version, to_version)
);

create table if not exists api_diff_requests (
  package      text        not null,
  from_version text        not null,
  to_version   text        not null,
  requested_at timestamptz not null default now(),
  primary key (package, from_version, to_version)
);

-- The backlog is drained oldest-first.
create index if not exists api_diff_requests_requested_at_idx
  on api_diff_requests (requested_at);

alter table api_diffs enable row level security;
alter table api_diff_requests enable row level security;
