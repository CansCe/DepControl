-- Scans that have been asked for, whether or not anybody is still watching.
--
-- A scan used to be a request: the analysis ran inside the POST that started it
-- and the report came back in the response. That made the scan only as durable
-- as the browser tab, and on a deployment that scales to zero it made it only as
-- durable as the connection holding the machine up. This table is the scan
-- instead — the request writes a row and returns, and a worker drains it.
--
-- One row per scan, keyed by the id the *client* invents. That is deliberate and
-- predates this table: the caller names its own scan so it can start watching
-- without waiting for the server to hand an id back. It is also why `owner_id`
-- is here and why every read is scoped by it — an id a client chose is an id
-- another client could guess.
--
-- The row is both the queue and the durable progress record:
--
--   state     what the queue reasons about: what to pick up, what a dead
--             machine was holding.
--   progress  the ScanProgress a person watching reads. Written from memory on
--             every phase change and at most once a second otherwise — a scan
--             calls packageDone() once per package, which is 1,491 times on the
--             largest repository measured, and a write each would cost more than
--             the registry calls it is reporting on.
--
-- The two overlap only at the end, and the worker writes them together.
--
-- `heartbeat_at` is what makes an OOM survivable. A claimed job whose worker has
-- stopped saying anything is put back to `queued` on the next drain, bounded by
-- `attempts` so a scan that kills its machine every time cannot do it forever.
--
-- RLS is enabled with no policies, matching `projects` and `license_policies`:
-- the backend connects as the database user, and nothing should reach this table
-- through PostgREST with an end user's key.

create table if not exists scan_jobs (
  id           text        primary key,
  owner_id     uuid        not null references auth.users (id) on delete cascade,

  kind         text        not null check (kind in ('add', 'refresh')),

  -- What to scan. `project_id` is set from the start for a refresh, and only
  -- once the scan succeeds for an add — a git URL nobody can clone must not
  -- leave an empty project behind.
  git_url      text        not null,
  ref          text        not null default 'HEAD',
  project_id   uuid        references projects (id) on delete cascade,

  state        text        not null default 'queued'
                           check (state in ('queued', 'running', 'done', 'failed')),
  progress     jsonb       not null default '{}'::jsonb,
  error        text,

  attempts     integer     not null default 0,
  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  heartbeat_at timestamptz,
  finished_at  timestamptz
);

-- The drain query: the oldest job that is waiting, or one whose worker has gone
-- quiet. Partial, because finished jobs are the overwhelming majority of the
-- table and none of them are ever a candidate.
create index if not exists scan_jobs_pending_idx
  on scan_jobs (created_at)
  where state in ('queued', 'running');

-- "What is still running for me", for a client that has just been reopened.
create index if not exists scan_jobs_owner_idx
  on scan_jobs (owner_id, created_at desc);

alter table scan_jobs enable row level security;
