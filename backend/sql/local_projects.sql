-- Projects whose repository this server cannot reach.
--
-- `GitFetcher` accepts github.com and gitlab.com over https and nothing else, so
-- an Azure DevOps repository, a GitHub Enterprise one, or anything behind a VPN
-- could not be scanned at all. A local project is one that was read by
-- `depcontrol collect` on the machine that holds it and uploaded already parsed:
-- package names, resolved versions, and where each manifest sits. No source, no
-- URLs, no file contents.
--
-- Two consequences are recorded here rather than inferred:
--
--   git_url             becomes nullable. "There is no URL" is a fact about a
--                       local project, not a missing value — and it is the one
--                       thing about a private repository that would let a hosted
--                       service try to reach it.
--   source              says which kind this is, rather than being read from
--                       whether the URL happens to be null. Existing rows are
--                       all `git`, which is what they were.
--   bundle_collected_at when the bundle was read, *by the clock of the machine
--                       that read it*. This is a local project's real freshness
--                       and it is not `last_checked_at`: the nightly sweep
--                       re-queries advisories and licences against the stored
--                       versions with no repository access at all, so a local
--                       project's advisories stay current while its dependency
--                       list is as old as the last collect. Showing only the
--                       server's timestamp would present a six-month-old
--                       dependency list as though it were checked this morning.
--
-- Self-reported, so a `bundle_collected_at` in the future says the clock is
-- wrong rather than that the bundle is fresh. Readers treat it that way.

alter table projects
  add column if not exists source text not null default 'git'
    check (source in ('git', 'local')),
  add column if not exists bundle_collected_at timestamptz;

alter table projects
  alter column git_url drop not null;

-- A git project without a URL cannot be fetched and a local one with a URL is
-- claiming a provenance it does not have. Added last, so it is checked against
-- columns that exist, and guarded so the file stays safe to re-run.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'projects_source_url'
  ) then
    alter table projects add constraint projects_source_url
      check (
        (source = 'git'   and git_url is not null) or
        (source = 'local' and git_url is null)
      );
  end if;
end
$$;
