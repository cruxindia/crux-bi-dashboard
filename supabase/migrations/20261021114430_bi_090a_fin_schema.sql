-- Applied to Supabase project via MCP on 20261021114430
-- bi_090a (21-Oct-2026): finance layer — schema, helpers and ingest for the Collection workbook (bank receipts)
-- and the Outstanding workbook (dated snapshot of the open-invoice ledger).
-- Storage note: the project is close to the free-plan database limit, so invoice- and receipt-level rows are kept
-- as compressed row arrays per sheet (bi.fin_part) and everything the dashboard reads comes from small aggregate tables.
-- Nothing is ever removed: superseded uploads keep their rows; aggregates of non-current uploads are zeroed by bi.fin_derive.

create table if not exists bi.fin_upload (
  id bigserial primary key,
  kind text not null check (kind in ('collection', 'outstanding')),
  file_name text not null, file_hash text not null, source_ref text,
  as_of date not null,
  as_of_basis text,
  period_from date, period_to date, name_period date,
  status text not null default 'staging' check (status in ('staging', 'committed', 'superseded', 'rejected')),
  uploaded_by text, created_at timestamptz not null default now(), committed_at timestamptz,
  controls jsonb not null default '{}'::jsonb, summary jsonb, notes text,
  unique (kind, file_hash));
comment on table bi.fin_upload is 'Finance workbook uploads. Outstanding = dated snapshot (never summed across uploads); collection = cumulative receipt ledger (latest per financial year is current).';
comment on column bi.fin_upload.as_of is 'Outstanding: snapshot date. Collection: last receipt date in the file.';

create table if not exists bi.fin_part (
  upload_id bigint not null references bi.fin_upload(id), sheet text not null, seq int not null,
  role text not null check (role in ('ledger', 'bank', 'main')), cols text[] not null, rows jsonb not null,
  primary key (upload_id, sheet, seq));
comment on table bi.fin_part is 'Normalised source rows (no personal data), stored as row arrays per sheet chunk; column order in cols.';
do $do$ begin
  execute 'alter table bi.fin_part alter column rows set compression lz4';
exception when others then raise notice 'lz4 not available, default compression kept';
end $do$;

create table if not exists bi.fin_loc_map (
  key_type text not null check (key_type in ('prefix', 'label', 'sheet')), key text not null,
  location_id int references bi.location(id), confidence text not null default 'medium', note text,
  updated_by text not null default 'seed', updated_at timestamptz not null default now(),
  primary key (key_type, key));
comment on table bi.fin_loc_map is 'Finance location resolution. Invoice-series prefix first, then the row location label, then the sheet. location_id null = ambiguous or deliberately unallocated.';

create table if not exists bi.fin_client_map (key text primary key, family text not null, note text,
  updated_by text not null default 'seed', updated_at timestamptz not null default now());

create table if not exists bi.fin_config (key text primary key, value jsonb not null, note text,
  updated_by text not null default 'seed', updated_at timestamptz not null default now());
insert into bi.fin_config (key, value, note) values
  ('ageing_buckets', '[30, 60, 90, 180]', 'Upper bounds in days: 0–30, 31–60, 61–90, 91–180, over 180'),
  ('invoice_date_rule', '"month_end"', 'Invoice dates in the workbooks are incomplete and inconsistent, so age is counted from the last day of the invoice month (the month in the invoice number).'),
  ('credit_days', 'null', 'Agreed payment terms in days. Unknown, so nothing is called overdue. Set a number to show amounts beyond terms.'),
  ('recon_grace_days', '7', 'A receipt is compared with the ledger only if it is at least this many days older than the snapshot date.'),
  ('alert_rules', '{"over180_share": 0.30, "cash_ratio_min": 0.60, "collection_drop": 0.25, "unadj_share": 0.20, "rate_gap": 0.10, "os_stale_days": 35, "rc_stale_days": 20, "min_amount": 100000}', 'Thresholds for smart alerts')
on conflict (key) do nothing;

create table if not exists bi.fin_run (id bigserial primary key, started_at timestamptz not null default now(), finished_at timestamptz, actor text, summary jsonb);

create table if not exists bi.fin_os_agg (
  upload_id bigint not null, location_id int not null, family text not null, inv_month date not null,
  n int not null default 0, basic numeric not null default 0, net numeric not null default 0, partial numeric not null default 0,
  os numeric not null default 0, os_basic numeric not null default 0, neg_n int not null default 0, neg_os numeric not null default 0,
  dup_n int not null default 0, dup_os numeric not null default 0, run_id bigint,
  primary key (upload_id, location_id, family, inv_month));
comment on column bi.fin_os_agg.inv_month is '1900-01-01 = invoice month unknown';
comment on column bi.fin_os_agg.os_basic is 'Open amount restated on the ex-GST basic basis (basic x open share of net)';

create table if not exists bi.fin_unadj (upload_id bigint not null, label text not null, location_id int not null, amount numeric not null default 0, run_id bigint,
  primary key (upload_id, label));

create table if not exists bi.fin_rcpt_agg (
  upload_id bigint not null, location_id int not null, family text not null, bank text not null, rcpt_month date not null,
  n int not null default 0, amount numeric not null default 0, inv_n int not null default 0, inv_amount numeric not null default 0, basic numeric not null default 0,
  closed_n int not null default 0, closed_amount numeric not null default 0, partial_n int not null default 0, partial_amount numeric not null default 0,
  open_n int not null default 0, open_amount numeric not null default 0, lag_x_amount numeric not null default 0, lag_amount numeric not null default 0, run_id bigint,
  primary key (upload_id, location_id, family, bank, rcpt_month));
comment on column bi.fin_rcpt_agg.inv_amount is 'Receipts that quote an invoice number (the rest are unallocated)';
comment on column bi.fin_rcpt_agg.open_amount is 'Receipts against invoices the ledger snapshot still shows as fully unpaid (reconciliation gap)';

create table if not exists bi.fin_inv_month (
  location_id int not null, family text not null, inv_month date not null,
  inv_n int not null default 0, basic numeric not null default 0, open_basic numeric not null default 0, settled_basic numeric not null default 0,
  collected numeric not null default 0, in_ledger_n int not null default 0, receipt_only_n int not null default 0, run_id bigint,
  primary key (location_id, family, inv_month));
comment on table bi.fin_inv_month is 'Invoices identified in the current ledger snapshot and/or the current receipt ledger, by invoice month (each invoice once).';

create table if not exists bi.fin_review (
  id bigserial primary key, kind text not null, key text not null, upload_id bigint, location_id int, severity text not null default 'warn',
  amount numeric, n int, title text, detail jsonb, status text not null default 'open' check (status in ('open', 'accepted', 'resolved', 'ignored', 'cleared')),
  first_seen timestamptz not null default now(), last_seen timestamptz not null default now(), run_id bigint,
  resolved_by text, resolved_at timestamptz, note text, unique (kind, key));
comment on table bi.fin_review is 'Admin review queue for finance data. Status set by an admin is kept across re-derivations; items that disappear become cleared.';

alter table bi.fin_upload enable row level security; alter table bi.fin_part enable row level security;
alter table bi.fin_loc_map enable row level security; alter table bi.fin_client_map enable row level security;
alter table bi.fin_config enable row level security; alter table bi.fin_run enable row level security;
alter table bi.fin_os_agg enable row level security; alter table bi.fin_unadj enable row level security;
alter table bi.fin_rcpt_agg enable row level security; alter table bi.fin_inv_month enable row level security;
alter table bi.fin_review enable row level security;

create or replace function bi.fin_label(p text) returns text language sql immutable as $$
  select nullif(lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')), '') $$;

-- canonical invoice key PREFIX-YYMM-REST (same rule as invParse in web/extract.js)
create or replace function bi.fin_inv_key(p text) returns text language sql immutable as $$
  with a as (select regexp_replace(regexp_replace(upper(btrim(coalesce(p, ''))), '^[^A-Z0-9]+', ''), '^CRUX[\s\-]*', '') s),
       b as (select btrim(split_part(regexp_replace(s, '[,&]|\mAND\M|\s/\s', '|', 'g'), '|', 1)) s from a),
       c as (select regexp_replace(regexp_replace(s, '\s*-\s*|\s+', '-', 'g'), '-+', '-', 'g') s from b)
  select case when s ~ '^[A-Z]{2,5}-?[0-9]{4}-?[A-Z0-9][A-Z0-9\-]*$'
              then regexp_replace(s, '^([A-Z]{2,5})-?([0-9]{2})([0-9]{2})-?([A-Z0-9][A-Z0-9\-]*)$', '\1-\2\3-\4') else nullif(s, '') end from c $$;

create or replace function bi.fin_loc_ok(p_loc int, f jsonb) returns boolean language sql stable as $$
  select case when coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb then true
    else exists (select 1 from bi.location l where l.id = p_loc
      and (f->>'zone_group' is null or coalesce(l.zone_group, l.rollup_zone) = f->>'zone_group')
      and (f->>'region' is null or l.region = f->>'region') and (f->>'stakeholder' is null or l.stakeholder = f->>'stakeholder')
      and (f->>'location_id' is null or l.id = (f->>'location_id')::int)) end $$;

create or replace function bi.fin_fy(d date) returns date language sql immutable as $$
  select make_date(case when extract(month from d) >= 4 then extract(year from d)::int else extract(year from d)::int - 1 end, 4, 1) $$;

create or replace function bi.fin_os_lines(p_upload bigint)
returns table (sheet text, r int, loc text, im date, cl text, br text, inv text, inv_key text, prefix text,
               basic numeric, gross numeric, tds numeric, net numeric, partial numeric, os numeric, rk text,
               location_id int, loc_src text, family text)
language sql stable security definer set search_path to 'bi', 'public' as $$
  with x0 as materialized (
    select p.sheet, (x->>0)::int r, x->>1 loc, to_date(x->>2, 'YYYY-MM') im, x->>4 cl, x->>5 br, x->>6 inv, bi.fin_inv_key(x->>6) k,
           (x->>7)::numeric basic, (x->>8)::numeric gross, (x->>9)::numeric tds, (x->>10)::numeric net,
           coalesce((x->>11)::numeric, 0) partial, coalesce((x->>12)::numeric, 0) os, x->>13 rk,
           bi.fin_label(x->>1) lloc, bi.fin_label(x->>4) lcl, bi.fin_label(p.sheet) lsh
    from bi.fin_part p cross join lateral jsonb_array_elements(p.rows) x
    where p.upload_id = p_upload and p.role = 'ledger'),
  e as materialized (select x0.*, substring(x0.k from '^[A-Z]{2,5}') pfx from x0)
  select e.sheet, e.r, e.loc, e.im, e.cl, e.br, e.inv, e.k, e.pfx, e.basic, e.gross, e.tds, e.net, e.partial, e.os, e.rk,
         coalesce(pm.location_id, lm.location_id, sm.location_id, 0),
         case when pm.location_id is not null then 'prefix' when lm.location_id is not null then 'label' when sm.location_id is not null then 'sheet' else 'none' end,
         coalesce(cm.family, case when e.lcl is null then '(none)' when e.lcl ~ '^boi' then 'BOI' when e.lcl ~ '^bom' then 'BOM'
                                  when e.lcl ~ '^sbi' then 'SBI' when e.lcl ~ '^canara' then 'CANB' else 'OTHERS' end)
  from e
  left join bi.fin_loc_map pm on pm.key_type = 'prefix' and pm.key = e.pfx
  left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = e.lloc
  left join bi.fin_loc_map sm on sm.key_type = 'sheet' and sm.key = e.lsh
  left join bi.fin_client_map cm on cm.key = e.lcl $$;

create or replace function bi.fin_receipts(p_upload bigint)
returns table (sheet text, role text, r int, loc text, bank text, rm date, d date, amt numeric, cl text, br text, inv text, inv_key text, prefix text,
               basic numeric, im date, ims text, h text, map_loc int, map_state text, family text)
language sql stable security definer set search_path to 'bi', 'public' as $$
  with x0 as materialized (
    select p.sheet, p.role, (x->>0)::int r, x->>1 loc, x->>2 bank, to_date(x->>3, 'YYYY-MM') rm, (x->>4)::date d, (x->>5)::numeric amt,
           x->>6 cl, x->>7 br, x->>8 inv, bi.fin_inv_key(x->>8) k, (x->>9)::numeric basic, to_date(x->>10, 'YYYY-MM') im, x->>11 ims, x->>12 h,
           bi.fin_label(x->>1) lloc, bi.fin_label(x->>6) lcl
    from bi.fin_part p cross join lateral jsonb_array_elements(p.rows) x
    where p.upload_id = p_upload and p.role in ('bank', 'main')),
  e as materialized (select x0.*, substring(x0.k from '^[A-Z]{2,5}') pfx from x0)
  select e.sheet, e.role, e.r, e.loc, e.bank, e.rm, e.d, e.amt, e.cl, e.br, e.inv, e.k, e.pfx, e.basic, e.im, e.ims, e.h,
         coalesce(pm.location_id, lm.location_id, 0),
         case when pm.location_id is not null then 'prefix' when lm.location_id is not null then 'label'
              when e.k is null and (e.lloc is null or lm.confidence = 'unallocated') then 'unallocated' else 'none' end,
         coalesce(cm.family, case when e.lcl is null then '(none)' when e.lcl ~ '^boi' then 'BOI' when e.lcl ~ '^bom' then 'BOM'
                                  when e.lcl ~ '^sbi' then 'SBI' when e.lcl ~ '^canara' then 'CANB' else 'OTHERS' end)
  from e
  left join bi.fin_loc_map pm on pm.key_type = 'prefix' and pm.key = e.pfx
  left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = e.lloc
  left join bi.fin_client_map cm on cm.key = e.lcl $$;

-- begin -> stage (one call per sheet chunk) -> commit (row counts checked against the file) -> derive
create or replace function bi.fin_ingest_as(p_actor text, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '120s' as $function$
declare u bi.fin_upload; v_id bigint; v_cols text[]; v_exp text[]; n int; bad jsonb; d jsonb;
begin
  if p_action = 'begin' then
    if p->>'kind' not in ('collection', 'outstanding') then raise exception 'kind must be collection or outstanding'; end if;
    if coalesce(p->>'file_hash', '') !~ '^[0-9a-f]{64}$' then raise exception 'file_hash (sha-256 hex) required'; end if;
    if nullif(p->>'as_of', '') is null then raise exception 'as_of date required'; end if;
    select * into u from bi.fin_upload where kind = p->>'kind' and file_hash = p->>'file_hash';
    if found and u.status in ('committed', 'superseded') then
      return jsonb_build_object('duplicate', true, 'upload_id', u.id, 'status', u.status, 'committed_at', u.committed_at);
    end if;
    if found then
      update bi.fin_upload set status = 'staging', file_name = p->>'file_name', source_ref = p->>'source_ref', as_of = (p->>'as_of')::date,
             as_of_basis = p->>'as_of_basis', period_from = nullif(p->>'period_from', '')::date, period_to = nullif(p->>'period_to', '')::date,
             name_period = nullif(p->>'name_period', '')::date, controls = coalesce(p->'controls', '{}'::jsonb), uploaded_by = p_actor, notes = null
       where id = u.id;
      return jsonb_build_object('upload_id', u.id, 'resumed', true, 'parts', (select count(*) from bi.fin_part where upload_id = u.id));
    end if;
    insert into bi.fin_upload (kind, file_name, file_hash, source_ref, as_of, as_of_basis, period_from, period_to, name_period, controls, uploaded_by)
    values (p->>'kind', p->>'file_name', p->>'file_hash', p->>'source_ref', (p->>'as_of')::date, p->>'as_of_basis', nullif(p->>'period_from', '')::date,
            nullif(p->>'period_to', '')::date, nullif(p->>'name_period', '')::date, coalesce(p->'controls', '{}'::jsonb), p_actor)
    returning id into v_id;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_begin', 'fin_upload', v_id::text, jsonb_build_object('kind', p->>'kind', 'file', p->>'file_name'));
    return jsonb_build_object('upload_id', v_id);

  elsif p_action = 'stage' then
    select * into u from bi.fin_upload where id = (p->>'upload_id')::bigint;
    if not found or u.status <> 'staging' then raise exception 'upload % is not open for staging', p->>'upload_id'; end if;
    select array_agg(x order by o) into v_cols from jsonb_array_elements_text(p->'cols') with ordinality t(x, o);
    v_exp := case when p->>'role' = 'ledger' then array['r','loc','im','ims','cl','br','inv','basic','gross','tds','net','partial','os','rk']
                  else array['r','loc','bank','rm','d','amt','cl','br','inv','basic','im','ims','h'] end;
    if (u.kind = 'outstanding') <> (p->>'role' = 'ledger') or v_cols is distinct from v_exp then raise exception 'unexpected columns or role for a % upload', u.kind; end if;
    if jsonb_typeof(p->'rows') <> 'array' then raise exception 'rows must be an array'; end if;
    insert into bi.fin_part (upload_id, sheet, seq, role, cols, rows) values (u.id, p->>'sheet', (p->>'seq')::int, p->>'role', v_cols, p->'rows')
    on conflict (upload_id, sheet, seq) do update set rows = excluded.rows, role = excluded.role, cols = excluded.cols;
    return jsonb_build_object('ok', true, 'rows', jsonb_array_length(p->'rows'));

  elsif p_action = 'commit' then
    select * into u from bi.fin_upload where id = (p->>'upload_id')::bigint for update;
    if not found or u.status <> 'staging' then raise exception 'upload % is not open', p->>'upload_id'; end if;
    select jsonb_object_agg(e.key, jsonb_build_object('expected', e.value::int, 'stored', coalesce(s.n, 0))) into bad
    from jsonb_each_text(coalesce(p->'expected', '{}'::jsonb)) e
    left join (select sheet, sum(jsonb_array_length(rows))::int n from bi.fin_part where upload_id = u.id group by 1) s on s.sheet = e.key
    where coalesce(s.n, 0) <> e.value::int;
    if bad is not null then raise exception 'row counts differ from the file: %', bad; end if;
    if (select count(*) from bi.fin_part where upload_id = u.id) = 0 then raise exception 'nothing staged'; end if;
    update bi.fin_upload set status = 'committed', committed_at = now() where id = u.id;
    if u.kind = 'outstanding' then
      update bi.fin_upload set status = 'superseded', notes = coalesce(notes || ' ', '') || 'replaced by upload ' || u.id
       where kind = 'outstanding' and status = 'committed' and as_of = u.as_of and id <> u.id;
    else
      update bi.fin_upload set status = 'superseded', notes = coalesce(notes || ' ', '') || 'replaced by upload ' || u.id
       where kind = 'collection' and status = 'committed' and id <> u.id and bi.fin_fy(coalesce(period_from, as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of))
         and (as_of < u.as_of or (as_of = u.as_of and id < u.id));
      update bi.fin_upload set status = 'superseded', notes = coalesce(notes || ' ', '') || 'a file with later receipts is already current'
       where id = u.id and exists (select 1 from bi.fin_upload o where o.kind = 'collection' and o.status = 'committed' and o.id <> u.id
                                     and bi.fin_fy(coalesce(o.period_from, o.as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of)) and o.as_of > u.as_of);
    end if;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_commit', 'fin_upload', u.id::text,
      jsonb_build_object('kind', u.kind, 'file', u.file_name, 'as_of', u.as_of, 'status', (select status from bi.fin_upload where id = u.id)));
    return jsonb_build_object('ok', true, 'upload_id', u.id, 'status', (select status from bi.fin_upload where id = u.id), 'derive_pending', true);

  elsif p_action = 'derive' then
    d := bi.fin_derive(p_actor);
    update bi.fin_upload set summary = d where id = (select max(id) from bi.fin_upload where status in ('committed', 'superseded') and committed_at is not null);
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_derive', 'fin_run', d->>'run', d);
    return d;

  elsif p_action = 'reject' then
    update bi.fin_upload set status = 'rejected', notes = left(p->>'reason', 300) where id = (p->>'upload_id')::bigint and status = 'staging';
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'unknown action %', p_action;
end $function$;

create or replace function public.bi_fin_ingest(p_token text, p_action text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare v_actor text;
begin
  if bi.token_ok(p_token) then v_actor := 'loader-token';
  elsif bi.app_role() = 'admin' then v_actor := bi.current_email();
  else raise exception 'not authorised' using errcode = '42501'; end if;
  return bi.fin_ingest_as(v_actor, p_action, p_payload);
end $function$;
