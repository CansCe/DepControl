-- Where a project's changes get announced, and what has already been sent.
--
-- Run against the same database as the server. See the "Change tracking"
-- section of the README for what fires and when.

create table if not exists notification_targets (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid        not null references auth.users (id)
                       on delete cascade,
  -- The one project this watches, or null for every project the owner has.
  -- Cascades: a target scoped to a deleted project has nothing left to watch,
  -- and leaving it would silently widen to "all projects".
  project_id         uuid        references projects (id) on delete cascade,
  channel            text        not null check (channel in ('slack', 'teams')),
  -- The incoming-webhook URL, which is a bearer credential: anything holding it
  -- can post to the channel. The API never returns it — reads get the host and
  -- a stub instead. Stored in the clear because the server has to present it to
  -- the provider on every send, so encrypting it here would only move the key.
  url                text        not null,
  min_severity       text        not null default 'high',
  on_new_advisory    boolean     not null default true,
  on_breaking_change boolean     not null default true,
  created_at         timestamptz not null default now(),

  -- A target with both rules off would never fire. Refused here as well as in
  -- the route, because a saved intention that looks like a subscription is
  -- discovered months later, by not going off.
  constraint notification_targets_actionable
    check (on_new_advisory or on_breaking_change)
);

create index if not exists notification_targets_owner
  on notification_targets (owner_id, created_at desc);

alter table notification_targets enable row level security;

-- What has been announced, so a change is announced at most once per target.
--
-- The row is written *before* the request goes out — it is a claim rather than
-- a receipt. A scan that runs twice, or a machine that dies mid-send, cannot
-- produce a second alert; the cost is that a genuinely lost send is not
-- retried. That is the right way round for an alert naming a security
-- advisory: a repeat, days later, about a change already dealt with, does more
-- damage to a channel's credibility than a missed one does.
--
-- Keyed on the *revision* rather than on the scan, so two runs that arrive at
-- the same revision share one claim between them.
create table if not exists notification_deliveries (
  target_id    uuid        not null references notification_targets (id)
                 on delete cascade,
  revision_id  uuid        not null references dep_report_revisions (id)
                 on delete cascade,
  claimed_at   timestamptz not null default now(),
  succeeded    boolean,
  detail       text,

  primary key (target_id, revision_id)
);

alter table notification_deliveries enable row level security;
