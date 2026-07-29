-- Keeps a project's dependency reports over time instead of one at a time.
--
-- `dep_reports` was keyed on `project_id` and upserted, so every re-analysis
-- destroyed what it replaced. Nothing could answer "what changed", because
-- there was never anything to compare against — the previous answer had already
-- been overwritten by the one that superseded it.
--
-- A row here is a distinct *state* the dependencies were in, not a scan that
-- ran. A scheduled re-scan of a project nobody is touching finds the same thing
-- every day; writing that down 365 times a year would bury the handful of
-- moments that mattered. So a scan that finds no difference updates
-- `last_seen_at` on the newest row, and the history reads as the times
-- something changed. `content_digest` is what decides which of the two
-- happened; see backend/lib/src/repository/report_digest.dart for what it
-- covers and, more importantly, what it leaves out.
--
-- Only against the *newest* revision, which is why there is no unique index on
-- (project_id, content_digest). A project that goes A -> B -> A has genuinely
-- been in three states over time, and folding the second A into the first would
-- stretch one row's window across the period when B held — a claim the history
-- would then be making and nobody checked. Consecutive identical scans are
-- noise; a revert is not.
--
-- `first_seen_at` and `last_seen_at` are both kept because collapsing them
-- would make an unchanged project read as either stale or freshly changed, and
-- both are wrong. "Unchanged for six months" and "nobody has looked in six
-- months" are different facts about a project and the difference is the point.

create table if not exists dep_report_revisions (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid not null references projects (id) on delete cascade,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  content_digest text        not null,
  -- The repository revision this report describes, where it was recorded.
  -- Null is ordinary: a scan reads a ref, and resolving a branch name to a
  -- commit is a separate request to a rate-limited API. Null means "not
  -- recorded", never "the default branch".
  commit_sha     text,
  nodes          jsonb       not null,
  manifests      jsonb       not null default '[]'::jsonb,
  coverage_note  text
);

-- The history is always read newest-first for one project, pruned by the same
-- order, and every write reads the newest row to compare digests against it.
create index if not exists dep_report_revisions_project_time
  on dep_report_revisions (project_id, first_seen_at desc);

alter table dep_report_revisions enable row level security;

-- Carry the existing latest reports over as each project's first revision.
-- `generated_at` becomes both timestamps: it is the only thing the old row
-- said, and claiming a wider window than was recorded would be an invention.
--
-- The digest cannot be computed in SQL — it is defined by Dart code that knows
-- which fields count as a change — so these rows get a placeholder naming
-- themselves. They will not match any digest a scan produces, which means the
-- next scan of each project writes a genuine second revision rather than
-- silently folding into this one. That is the safe direction: an extra revision
-- is noise, a wrongly merged one is a change nobody was told about.
insert into dep_report_revisions
  (project_id, first_seen_at, last_seen_at, content_digest, nodes, manifests,
   coverage_note)
select
  project_id,
  generated_at,
  generated_at,
  'migrated:' || project_id::text,
  nodes,
  coalesce(manifests, '[]'::jsonb),
  coverage_note
from dep_reports
where not exists (
  select 1 from dep_report_revisions r where r.project_id = dep_reports.project_id
);

-- `dep_reports` is deliberately left in place. Everything reads from
-- `dep_report_revisions` after this migration, so the old table is inert; drop
-- it once you have confirmed the copy above landed:
--
--   drop table dep_reports;
