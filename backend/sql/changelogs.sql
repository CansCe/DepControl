-- Release notes, read out of published archives.
--
-- Modelled on api_diffs / api_diff_requests, and for the same reason: the
-- server never fetches an archive, so a lookup that misses records what it
-- wanted and `dart run tool/fill_changelogs.dart` drains the backlog.
--
-- Nothing here is owner-scoped. What an author wrote about `yaml 3.1.3` is the
-- same text for everyone and names only published packages, so one project's
-- upgrade populates the notes for every other project that later makes it.

-- One section per published version, as its author wrote it.
create table if not exists changelog_entries (
  ecosystem  text        not null,
  package    text        not null,
  version    text        not null,
  notes      text        not null,
  -- The release date, where the heading carried one. Most do not.
  released   date,
  -- Which archive this section was read out of. A changelog is cumulative, so
  -- the sections for 1.x usually arrive inside 3.0.0's archive — and knowing
  -- which reading produced a row is what makes it possible to replace them all
  -- when a newer archive is read.
  read_from  text        not null,
  read_at    timestamptz not null default now(),

  primary key (ecosystem, package, version)
);

-- Every archive that has been read, and how it went.
--
-- Separate from the entries because "read it and there was no changelog" is an
-- answer, and one that has to be recorded: a package that ships no changelog
-- would otherwise be requested again every day, forever, by a backlog that can
-- never be satisfied.
create table if not exists changelog_reads (
  ecosystem text        not null,
  package   text        not null,
  version   text        not null,
  -- Null when the archive was read. Set when it could not be — a cap refused,
  -- a host that would not answer — so the reason is visible rather than
  -- indistinguishable from a package with nothing to say.
  failure   text,
  read_at   timestamptz not null default now(),

  primary key (ecosystem, package, version)
);

create table if not exists changelog_requests (
  ecosystem    text        not null,
  package      text        not null,
  version      text        not null,
  requested_at timestamptz not null default now(),

  primary key (ecosystem, package, version)
);

-- The backlog is drained oldest-first.
create index if not exists changelog_requests_age
  on changelog_requests (requested_at);

alter table changelog_entries  enable row level security;
alter table changelog_reads    enable row level security;
alter table changelog_requests enable row level security;
