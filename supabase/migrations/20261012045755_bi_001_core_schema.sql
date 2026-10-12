-- Applied to Supabase project via MCP on 20261012045755

create schema if not exists bi;
revoke all on schema bi from public, anon, authenticated;

-- ===== Access control =====
create table bi.app_user (
  email text primary key check (email = lower(email)),
  role text not null check (role in ('admin','viewer')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into bi.app_user(email, role) values ('shantanu.suravase@cruxindia.co.in','admin');

create table bi.ingest_token (
  token_hash text primary key,
  label text not null,
  expires_at timestamptz not null,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

-- ===== Import control & audit =====
create table bi.import_batch (
  id bigserial primary key,
  source_category text not null check (source_category in ('zonal','case','point')),
  file_name text not null,
  file_hash text not null,
  location_group text,
  period_month date,
  snapshot_date date,
  status text not null default 'staged' check (status in ('staged','committed','rejected','superseded','duplicate')),
  rows_in int default 0, rows_new int default 0, rows_changed int default 0,
  rows_unchanged int default 0, rows_rejected int default 0,
  uploaded_by text not null,
  created_at timestamptz not null default now(),
  committed_at timestamptz,
  notes text
);
create unique index import_batch_hash_committed on bi.import_batch(file_hash) where status = 'committed';

create table bi.audit_log (
  id bigserial primary key,
  actor text not null, action text not null, entity text, entity_key text,
  detail jsonb, created_at timestamptz not null default now()
);

create table bi.dq_exception (
  id bigserial primary key,
  batch_id bigint references bi.import_batch(id),
  source_category text not null,
  record_key text,
  rule text not null,
  severity text not null check (severity in ('info','warning','error')),
  detail jsonb,
  status text not null default 'open' check (status in ('open','accepted','resolved')),
  created_at timestamptz not null default now()
);
create index on bi.dq_exception(rule, status);

-- ===== Reference data =====
create table bi.zone_group (          -- tracker reporting block, e.g. "Bhopal MP Zone"
  code text primary key, label text not null
);
create table bi.location (            -- canonical tracker location (leaf row column A)
  id serial primary key,
  code text unique not null,          -- normalised key
  label text not null,                -- display label from tracker
  zone_group text references bi.zone_group(code),
  region text,                         -- North/South/East/West (tracker col C on total rows)
  tier text,                           -- Zone A / Zone B (tracker col B on total rows)
  stakeholder text,                    -- Operation stakeholder block
  recon_unit text                      -- Case/Point file group that covers this location
);
create table bi.location_alias (
  id bigserial primary key,
  source text not null,               -- zonal_label | case_file | branch | area_office
  alias text not null,
  location_id int references bi.location(id),
  recon_unit text,
  method text not null, confidence numeric(4,3) not null,
  evidence jsonb, review_status text not null default 'auto' check (review_status in ('auto','confirmed','rejected','needs_review')),
  reviewed_by text, reviewed_at timestamptz,
  unique(source, alias)
);
create table bi.client (
  code text primary key, label text not null, family text not null
);
create table bi.client_alias (
  source text not null, alias text not null, client_code text references bi.client(code),
  method text not null, confidence numeric(4,3) not null,
  review_status text not null default 'auto', primary key(source, alias)
);
create table bi.point_type (
  name text primary key, category text not null check (category in ('field','document','tele','unknown')),
  rule text not null, evidence jsonb, review_status text not null default 'auto',
  reviewed_by text, reviewed_at timestamptz
);
create table bi.employee (
  name_key text primary key, display_name text not null,
  classification text not null default 'unclassified'
    check (classification in ('field_executive','back_office','mixed','unclassified')),
  rule text, evidence jsonb, override boolean not null default false,
  reviewed_by text, reviewed_at timestamptz
);

-- ===== Facts: Zonal tracker =====
create table bi.zt_snapshot (
  snapshot_date date primary key,
  report_month date not null,
  batch_id bigint references bi.import_batch(id),
  file_name text not null,
  pan_india_target int, pan_india_mtd int,    -- control totals as printed by the source
  loaded_at timestamptz not null default now()
);
create table bi.zt_row (
  snapshot_date date not null references bi.zt_snapshot(snapshot_date) on delete cascade,
  sheet_row int not null,
  row_type text not null check (row_type in ('leaf','zone_client_rollup','location_total','zone_total','summary','client_summary','stakeholder_summary')),
  zone_group text, location_label text, client_label text,
  location_id int references bi.location(id), client_code text references bi.client(code),
  target_cases numeric, mtd_cases numeric, rate numeric,
  revenue_target numeric, revenue_actual numeric, achievement numeric,
  bd_revenue numeric, shortfall_revenue numeric,
  expense_projected numeric, margin_after_expense numeric, col_n_value numeric,
  src_daily_value numeric,           -- column O as computed by the source (cases on leaf, revenue on totals)
  src_prev_value numeric,            -- hard-coded previous value parsed from column O formula
  primary key (snapshot_date, sheet_row)
);
create index on bi.zt_row(row_type, location_id, client_code, snapshot_date);

create table bi.zt_month_history (    -- monthly actuals from the tracker's historical columns
  month date not null, location_label text not null, client_label text not null,
  location_id int references bi.location(id), client_code text references bi.client(code),
  cases numeric, revenue numeric, billing numeric,
  source_snapshot date not null, source_columns text,
  primary key (month, location_label, client_label)
);

-- ===== Facts: Case Wise =====
create table bi.fact_case (
  case_id bigint primary key,
  client_raw text, client_code text references bi.client(code),
  branch text, branch_code text, branch_type text, area_office text,
  status text, received_at timestamptz, completed_at timestamptz, due_at timestamptz,
  product text, points_declared int,
  file_group text not null,          -- Case Wise file location group
  recon_unit text, location_id int references bi.location(id),
  received_month date generated always as (date_trunc('month', (received_at at time zone 'Asia/Kolkata'))::date) stored,
  row_hash text not null,
  first_batch bigint, last_batch bigint,
  updated_at timestamptz not null default now()
);
create index on bi.fact_case(received_month, recon_unit, client_code);
create index on bi.fact_case(location_id);

-- ===== Facts: Point Wise =====
create table bi.fact_point (
  point_id bigint primary key,
  case_id bigint not null,
  branch text, client_code_raw text, branch_type text, area_office text,
  user_type text, point_type text, created_by text, created_at timestamptz,
  assign_to text, status text, report_status text, verified_by text, completed_by text,
  assigned_at timestamptz, field_reviewed_at timestamptz, completed_at timestamptz,
  pincode text, has_address boolean, product text,
  file_group text not null, recon_unit text,
  created_month date generated always as (date_trunc('month', (created_at at time zone 'Asia/Kolkata'))::date) stored,
  row_hash text not null, first_batch bigint, last_batch bigint,
  updated_at timestamptz not null default now()
);
create index on bi.fact_point(case_id);
create index on bi.fact_point(created_month, recon_unit, point_type);
create index on bi.fact_point(verified_by);

-- ===== Staging =====
create table bi.stg_row (
  batch_id bigint not null references bi.import_batch(id) on delete cascade,
  seq int not null, payload jsonb not null,
  primary key(batch_id, seq)
);

alter table bi.app_user enable row level security;
alter table bi.ingest_token enable row level security;
alter table bi.import_batch enable row level security;
alter table bi.audit_log enable row level security;
alter table bi.dq_exception enable row level security;
alter table bi.zone_group enable row level security;
alter table bi.location enable row level security;
alter table bi.location_alias enable row level security;
alter table bi.client enable row level security;
alter table bi.client_alias enable row level security;
alter table bi.point_type enable row level security;
alter table bi.employee enable row level security;
alter table bi.zt_snapshot enable row level security;
alter table bi.zt_row enable row level security;
alter table bi.zt_month_history enable row level security;
alter table bi.fact_case enable row level security;
alter table bi.fact_point enable row level security;
alter table bi.stg_row enable row level security;
-- No policies on purpose: the bi schema is not exposed to the API and no direct table access is granted.
-- All access goes through SECURITY DEFINER functions in public that check bi.current_role().

