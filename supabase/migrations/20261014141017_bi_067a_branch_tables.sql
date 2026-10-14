-- Applied to Supabase project via MCP on 20261014141017
create table if not exists bi.client_family_research(
  family text primary key,
  display_name text not null,
  entity_type text not null check (entity_type in ('bank','housing_finance','nbfc','not_branch_network','unresolved')),
  ifsc_bank_code text,
  official_site text,
  locator_url text,
  primary_source text,
  research_status text not null default 'pending' check (research_status in ('pending','researched','partial','not_applicable','unresolved')),
  coverage_note text,
  sources jsonb not null default '[]',
  last_researched_at timestamptz,
  last_verified_at timestamptz,
  source_version text,
  listed_total int,
  listed_in_scope int,
  updated_at timestamptz not null default now());
alter table bi.client_family_research enable row level security;

create table if not exists bi.location_territory(
  id bigserial primary key,
  location_id int references bi.location(id),
  zone_group text,
  state text not null,
  district text,
  basis text not null check (basis in ('location_name','city_district','observed_cases','zone_state','state_unassigned')),
  confidence text not null check (confidence in ('high','medium','low')),
  evidence jsonb not null default '{}',
  effective_from date not null default current_date,
  effective_to date,
  updated_at timestamptz not null default now());
alter table bi.location_territory enable row level security;
create unique index if not exists location_territory_current_uq on bi.location_territory(state, coalesce(district, '*')) where effective_to is null;

alter table bi.client_branch_master
  add column if not exists branch_uid text,
  add column if not exists client_family text,
  add column if not exists ifsc text,
  add column if not exists micr text,
  add column if not exists aliases text[] not null default '{}',
  add column if not exists address text,
  add column if not exists district text,
  add column if not exists pincode text,
  add column if not exists centre text,
  add column if not exists latitude numeric,
  add column if not exists longitude numeric,
  add column if not exists branch_type text,
  add column if not exists zone_group text,
  add column if not exists territory_basis text,
  add column if not exists source_type text,
  add column if not exists source_url text,
  add column if not exists source_version text,
  add column if not exists first_seen date,
  add column if not exists last_seen date,
  add column if not exists last_seen_run bigint,
  add column if not exists verification_status text,
  add column if not exists research_notes text,
  add column if not exists row_hash text;
create unique index if not exists client_branch_master_uid_uq on bi.client_branch_master(branch_uid);
create index if not exists client_branch_master_fam_loc on bi.client_branch_master(client_family, location_id);

create table if not exists bi.client_branch_history(
  id bigserial primary key,
  branch_uid text not null,
  client_family text,
  change_type text not null check (change_type in ('added','renamed','address_changed','relocated','territory_changed','missing_from_source','reappeared','closed','status_changed')),
  old jsonb,
  new jsonb,
  effective_on date not null default current_date,
  run_id bigint,
  source_version text,
  recorded_at timestamptz not null default now());
alter table bi.client_branch_history enable row level security;
create index if not exists client_branch_history_uid on bi.client_branch_history(branch_uid);

create table if not exists bi.branch_review(
  id bigserial primary key,
  client_family text,
  branch_uid text,
  location_id int,
  issue text not null check (issue in ('missing_from_source','duplicate_candidate','territory_unmapped','source_changed','source_incomplete','source_unavailable','identity_unresolved','conflict')),
  reason text not null,
  evidence jsonb not null default '{}',
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  opened_at timestamptz not null default now(),
  opened_run bigint,
  last_seen_run bigint,
  resolved_at timestamptz,
  resolved_by text,
  resolution text);
alter table bi.branch_review enable row level security;
create unique index if not exists branch_review_open_uq on bi.branch_review(coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open';

create table if not exists bi.job_run(
  id bigserial primary key,
  job text not null,
  trigger text not null,
  started_at timestamptz not null default now(),
  heartbeat_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running','succeeded','partial','failed','skipped')),
  source_version text,
  stats jsonb not null default '{}',
  errors jsonb not null default '[]',
  summary text);
alter table bi.job_run enable row level security;
create index if not exists job_run_job on bi.job_run(job, started_at desc);

create table if not exists bi.branch_source(
  source_key text primary key,
  url text,
  version text,
  published_at timestamptz,
  content_hash text,
  fetched_at timestamptz,
  status text,
  note text);
alter table bi.branch_source enable row level security;

create or replace function bi.norm_code(p text) returns text language sql immutable as $$
  select nullif(ltrim(regexp_replace(regexp_replace(upper(coalesce(p, '')), '^[A-Z_]+-', ''), '[^0-9A-Z]', '', 'g'), '0'), '') $$;

create or replace function bi.territory_of(p_state text, p_district text)
returns table(location_id int, zone_group text, basis text, confidence text) language sql stable as $$
  select t.location_id, t.zone_group, t.basis, t.confidence from bi.location_territory t
  where t.effective_to is null and t.state = upper(p_state) and (t.district = upper(p_district) or t.district is null)
  order by (t.district is null), t.id limit 1 $$;

create or replace function bi._br_parse(p jsonb)
returns table(uid text, code text, ifsc text, micr text, name text, address text, district text, state text, centre text, city text,
              pincode text, branch_type text, location_id int, zone_group text, basis text, h text, conf text)
language sql stable set search_path = bi, public as $$
  select x->>'uid', x->>'code', nullif(x->>'ifsc', ''), nullif(x->>'micr', ''), x->>'name', nullif(x->>'address', ''), upper(nullif(x->>'district', '')), upper(x->>'state'),
         nullif(x->>'centre', ''), nullif(x->>'city', ''), coalesce(nullif(x->>'pincode', ''), substring(x->>'address' from '([1-9][0-9]{2}\s?[0-9]{3})\D*$')),
         coalesce(x->>'branch_type', 'branch'), t.location_id, t.zone_group, t.basis,
         md5(concat_ws('|', x->>'name', x->>'address', upper(x->>'district'), upper(x->>'state'), x->>'centre', x->>'branch_type', x->>'micr')),
         coalesce(x->>'confidence', 'high')
  from jsonb_array_elements(coalesce(p->'rows', '[]')) x
  left join lateral bi.territory_of(x->>'state', x->>'district') t on true $$;
