-- Lets a project be put out of the way without losing it.
--
-- Archiving is the reversible half of "stop showing me this": the project and
-- its report stay, and `allForOwner` leaves it out unless asked. Deleting is
-- the other half and keeps nothing — `dep_reports` already cascades from
-- `projects`, so a delete takes the report with it.

alter table projects
  add column if not exists archived_at timestamptz;

-- The registry's default query is "mine, not archived, newest first".
create index if not exists projects_owner_active_idx
  on projects (owner_id, added_at desc)
  where archived_at is null;
