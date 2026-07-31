-- Makes "the newest revision" a deterministic question.
--
-- `dep_report_revisions` was ordered by `first_seen_at` alone. That is unique
-- in practice — the timestamp comes from `DateTime.now()` at the end of a scan —
-- but it is not unique by construction, and two revisions sharing one means
-- `order by first_seen_at desc limit 1` returns whichever row Postgres reached
-- first. Everything that matters here is built on that query: which report is
-- current, which digest a new scan is compared against, and which revisions
-- survive pruning.
--
-- The in-memory store already breaks the tie on insertion order. This gives
-- Postgres the same tiebreak, so the two agree by construction rather than by
-- the timestamps happening to differ.
--
-- `bigserial` backfills existing rows as it is added, in physical order, which
-- for rows written oldest-first is the order they were written in.

alter table dep_report_revisions
  add column if not exists seq bigserial;

-- Replaces the index the ordered reads use, so the tiebreak is covered too.
create index if not exists dep_report_revisions_project_order
  on dep_report_revisions (project_id, first_seen_at desc, seq desc);

drop index if exists dep_report_revisions_project_time;
