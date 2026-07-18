-- Power Flow OS — public schema
-- Structure only: no seed data. n8n connects with the service_role key
-- (bypasses RLS); the CRM app uses Supabase Auth (authenticated role).

-- ===== CORE TABLES =====

create table public.leads (
  id bigint generated always as identity primary key,
  name text not null,
  role text,
  company text,
  channel text not null default 'linkedin'
    check (channel in ('linkedin','upwork','agency','warm','referral')),
  linkedin_url text,
  company_url text,
  email text,
  context_notes text,
  status text not null default 'New'
    check (status in ('New','Ready','Contacted','T2 sent','T3 sent','Replied','Call booked','Proposal sent','Won','Lost','Dormant')),
  draft_msg text,
  sent_date date,
  last_touch date,
  next_action text,
  next_action_date date,
  reply_summary text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.agencies (
  id bigint generated always as identity primary key,
  agency text not null,
  website text,
  country text,
  contact_name text,
  email text,
  linkedin text,
  status text not null default 'New'
    check (status in ('New','Contacted','Follow-up sent','Replied','Test project','Dead')),
  sent_date date,
  followup_date date,
  notes text,
  created_at timestamptz not null default now()
);

create table public.content (
  id bigint generated always as identity primary key,
  week date,
  topic text not null,
  draft text,
  status text not null default 'topic'
    check (status in ('topic','draft','approved','posted')),
  post_url text,
  created_at timestamptz not null default now()
);

create table public.dashboard_weeks (
  id bigint generated always as identity primary key,
  week_start date not null unique,
  outreach_sent int not null default 0,
  replies int not null default 0,
  calls_booked int not null default 0,
  proposals_sent int not null default 0,
  revenue_usd numeric not null default 0,
  followups_due int not null default 0,
  followups_done int not null default 0,
  hours numeric not null default 0
);

-- Business config: offer copy, follow-up templates, sequence text.
-- n8n reads these at runtime, so editing copy never means editing a workflow.
-- No seed values are published here — this is Daniel's sales playbook, not
-- just data. Expected keys, documented so the structure is legible without
-- exposing content:
--
--   t2_touch               — WF3 reads this. Touch 2 template, sent when a
--                             lead sits in 'Contacted' for 4+ days.
--   t3_breakup              — WF3 reads this. Touch 3 (breakup) template,
--                             sent when a lead sits in 'T2 sent' for 8+ days.
--   proposal_followup_d3    — WF3 reads this. Check-in template, sent 3 days
--                             after a lead enters 'Proposal sent'.
--   proposal_followup_d7    — WF3 reads this. Direct-ask template, sent 7
--                             days after a lead enters 'Proposal sent'.
--   dormant_resurface        — seeded, not yet read by any workflow. Spec'd
--                             for a +60-day auto-resurface rule in WF3 that
--                             was never wired in — see docs/decisions.md.
--   agency_followup          — seeded, not yet read by any workflow. Agency
--                             follow-ups are manual today.
--   positioning_line,
--   offer_name,
--   offer_price_early,
--   offer_guarantee,
--   calendly_link            — reference values Daniel copies by hand today;
--                             no workflow reads them programmatically yet.
create table public.config (
  key text primary key,
  value text not null
);

-- ===== APP-INTERNAL TABLES (Fase A delta — CRM layer) =====

-- Append-only event log. Source of truth for every metric: status on `leads`
-- is mutable state that gets overwritten on every stage change, so weekly
-- counts (replies, calls booked, follow-ups done...) are derived from facts
-- logged here, not from diffing status snapshots.
create table public.activities (
  id bigint generated always as identity primary key,
  lead_id bigint references public.leads(id) on delete set null,
  agency_id bigint references public.agencies(id) on delete set null,
  kind text not null check (kind in (
    'sent','followup_done','reply_received','call_booked','proposal_sent',
    'won','lost','note','session_closed','client_task_done'
  )),
  detail text,
  created_at timestamptz not null default now()
);

-- One row per weekly ritual: the CRM's Sunday review captures the pipeline
-- bottleneck for that week so it's visible in the dashboard history.
create table public.weekly_reviews (
  id bigint generated always as identity primary key,
  week_start date not null unique,
  bottleneck_stage text,
  bottleneck_note text,
  completed_at timestamptz
);

-- CRM app configuration (daily target, default landing page, etc.).
-- Distinct from `config`, which is business config read by n8n.
create table public.settings (
  key text primary key,
  value text not null
);

-- ===== updated_at trigger =====

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger leads_updated_at
  before update on public.leads
  for each row execute function public.set_updated_at();

-- ===== RLS: locked by default; full access to authenticated users (the app) =====
-- n8n uses service_role, which bypasses RLS entirely.

alter table public.leads enable row level security;
alter table public.agencies enable row level security;
alter table public.content enable row level security;
alter table public.dashboard_weeks enable row level security;
alter table public.config enable row level security;
alter table public.activities enable row level security;
alter table public.weekly_reviews enable row level security;
alter table public.settings enable row level security;

create policy "auth full access leads" on public.leads
  for all to authenticated using (true) with check (true);
create policy "auth full access agencies" on public.agencies
  for all to authenticated using (true) with check (true);
create policy "auth full access content" on public.content
  for all to authenticated using (true) with check (true);
create policy "auth full access dashboard" on public.dashboard_weeks
  for all to authenticated using (true) with check (true);
create policy "auth full access config" on public.config
  for all to authenticated using (true) with check (true);
create policy "auth full access activities" on public.activities
  for all to authenticated using (true) with check (true);
create policy "auth full access weekly_reviews" on public.weekly_reviews
  for all to authenticated using (true) with check (true);
create policy "auth full access settings" on public.settings
  for all to authenticated using (true) with check (true);
