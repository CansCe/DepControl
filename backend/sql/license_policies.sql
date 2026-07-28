-- Which licenses a user's organisation will and will not ship.
--
-- One row per owner, holding the whole policy as JSONB. A policy is read and
-- written whole and never queried across, so there is nothing to gain from
-- normalising its rules into columns and something to lose: adding a field
-- would then need a migration.
--
-- Absence is meaningful. A user with no row here reads back the app's standard
-- policy rather than an empty one — see `LicensePolicyStore` — because an empty
-- policy clears every dependency, which is the one answer certain to be wrong.
--
-- RLS is enabled with no policies, matching `projects` and `dep_reports`: the
-- backend connects as the database user, and nothing should reach this table
-- through PostgREST with an end user's key.

create table if not exists license_policies (
  owner_id   uuid        primary key references auth.users (id) on delete cascade,
  policy     jsonb       not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table license_policies enable row level security;
