-- wave 113b (18-Nov-2026, owner 19:30 IST): "November Target will take time ... in mean while you update the target as planned by you and when
-- I am ready I will update mine which should overwrite what you update."
-- Planned targets for a running month whose tracker files carry no targets: one row per team x client code, worked out with the same method as the
-- target sheet (owner-reviewed rules, waves 102k-103) with the previous month complete as the base. They are written into the month's tracker leaf
-- rows (so every page, export and Ask Crux reads one figure) and every change is logged with the value it replaced. A tracker file uploaded later:
--   * without targets  -> gets the planned targets too;
--   * with targets     -> the owner's targets win: the planned set ends and the month's other report dates take the owner's targets.

create table if not exists bi.target_fill_set (
  id bigserial primary key,
  month date not null,
  status text not null default 'active' check (status in ('active', 'replaced_by_owner', 'withdrawn')),
  method text, totals jsonb, bridge jsonb,
  created_by text, created_at timestamptz not null default now(), reason text,
  ended_at timestamptz, ended_by text, replaced_by_snapshot date);
create unique index if not exists target_fill_set_one_active on bi.target_fill_set (month) where status = 'active';
create table if not exists bi.target_fill_row (
  set_id bigint not null references bi.target_fill_set(id) on delete cascade,
  location_id integer not null, client_code text not null,
  target_cases numeric, revenue_target numeric, rate numeric, situation text, calc text, reason text,
  primary key (set_id, location_id, client_code));
create table if not exists bi.target_fill_log (
  id bigserial primary key,
  snapshot_date date not null, sheet_row integer not null, set_id bigint references bi.target_fill_set(id),
  kind text not null check (kind in ('planned', 'owner', 'withdrawn')),
  old_target_cases numeric, old_revenue_target numeric, old_achievement numeric, old_shortfall numeric,
  new_target_cases numeric, new_revenue_target numeric, source_snapshot date,
  current boolean not null default true, at timestamptz not null default now(), by text);
create index if not exists target_fill_log_cur on bi.target_fill_log (snapshot_date, sheet_row) where current;
alter table bi.target_fill_set enable row level security;
alter table bi.target_fill_row enable row level security;
alter table bi.target_fill_log enable row level security;
revoke all on bi.target_fill_set, bi.target_fill_row, bi.target_fill_log from public, anon, authenticated;

-- The target sheet for the running month, planned as at its start: a copy of bi.api_target_sheet whose base is the previous month (complete).
do $$ declare d text := pg_get_functiondef('bi.api_target_sheet(date,jsonb,jsonb)'::regprocedure); o text; n int; i int;
  reps text[] := array[
   'FUNCTION bi.api_target_sheet(', 'FUNCTION bi.target_sheet_running(',
   'into v_l, v_share, v_asof, v_inact from bi.potential_run x order by x.run_id desc limit 1;',
   'into v_l, v_share, v_asof, v_inact from bi.potential_run x order by x.run_id desc limit 1;
  -- wave 113b: planned targets for the running month (the latest tracker month), as at its start: the previous month is the complete base
  if v_m is distinct from v_l then return jsonb_build_object(''error'', format(''Planned targets are made only for the running tracker month (%s).'', to_char(v_l, ''Mon-YY''))); end if;
  v_l := (v_m - interval ''1 month'')::date; v_share := 1; v_asof := (v_m - 1);',
   'if v_m is null or v_m <= v_l or v_m > (v_l + interval ''12 months'')::date then', 'if v_m is null then'];
begin
  for i in 1..array_length(reps, 1) / 2 loop
    o := reps[2*i-1]; n := (length(d) - length(replace(d, o, ''))) / length(o);
    if n <> 1 then raise exception 'target_sheet_running: replacement % found % times', i, n; end if;
    d := replace(d, o, reps[2*i]);
  end loop;
  execute d;
end $$;
comment on function bi.target_sheet_running(date, jsonb, jsonb) is 'wave 113b: target sheet for the running tracker month with the previous month (complete) as the base; copy of bi.api_target_sheet as of 18-Nov-2026.';
revoke all on function bi.target_sheet_running(date, jsonb, jsonb) from public, anon, authenticated;

-- Does this report date carry targets of its own (from its file), i.e. a non-zero target that the dashboard did not write?
create or replace function bi.target_fill_has_own(p_snap date) returns boolean language sql stable security definer set search_path to 'bi', 'public' as $f$
  select exists (select 1 from bi.zt_row z where z.snapshot_date = p_snap and z.row_type = 'leaf'
                    and (coalesce(z.target_cases, 0) <> 0 or coalesce(z.revenue_target, 0) <> 0)
                    and not exists (select 1 from bi.target_fill_log g where g.snapshot_date = z.snapshot_date and g.sheet_row = z.sheet_row and g.current and g.kind in ('planned', 'owner')))
$f$;

-- Write targets into one report date's leaf rows from a set (p_set) or from another report date (p_src), logging every changed row.
create or replace function bi.target_fill_write(p_snap date, p_set bigint, p_src date, p_actor text) returns integer language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_n int; v_kind text := case when p_set is not null then 'planned' else 'owner' end;
begin
  create temp table if not exists _tf (sheet_row int, ntc numeric, nrt numeric) on commit drop;
  truncate _tf;
  insert into _tf
  with lf as (select z.sheet_row, z.location_id, z.client_code, z.target_cases, z.revenue_target,
                     row_number() over (partition by z.location_id, z.client_code order by z.sheet_row) rn
                from bi.zt_row z where z.snapshot_date = p_snap and z.row_type = 'leaf'),
       src as (select r.location_id, r.client_code, r.target_cases tc, r.revenue_target rt from bi.target_fill_row r where p_set is not null and r.set_id = p_set
               union all
               select s.location_id, s.client_code, sum(coalesce(s.target_cases, 0)), sum(coalesce(s.revenue_target, 0)) from bi.zt_row s
                where p_set is null and s.snapshot_date = p_src and s.row_type = 'leaf' and s.location_id is not null group by 1, 2),
       nv as (select lf.sheet_row, lf.target_cases, lf.revenue_target,
                     case when lf.rn = 1 then coalesce(src.tc, 0) else 0 end ntc, case when lf.rn = 1 then coalesce(src.rt, 0) else 0 end nrt
                from lf left join src on src.location_id = lf.location_id and src.client_code = lf.client_code)
  select sheet_row, ntc, nrt from nv where coalesce(target_cases, 0) <> ntc or coalesce(revenue_target, 0) <> nrt;
  update bi.target_fill_log g set current = false from _tf t where g.snapshot_date = p_snap and g.sheet_row = t.sheet_row and g.current;
  insert into bi.target_fill_log (snapshot_date, sheet_row, set_id, kind, old_target_cases, old_revenue_target, old_achievement, old_shortfall,
                                  new_target_cases, new_revenue_target, source_snapshot, by)
  select p_snap, z.sheet_row, p_set, v_kind, z.target_cases, z.revenue_target, z.achievement, z.shortfall_revenue, t.ntc, t.nrt, p_src, p_actor
    from bi.zt_row z join _tf t on t.sheet_row = z.sheet_row where z.snapshot_date = p_snap;
  update bi.zt_row z set target_cases = t.ntc, revenue_target = t.nrt,
         achievement = case when t.ntc > 0 then z.mtd_cases / t.ntc else 0 end,
         shortfall_revenue = case when z.revenue_actual is not null then z.revenue_actual - t.nrt end
    from _tf t where z.snapshot_date = p_snap and z.sheet_row = t.sheet_row;
  get diagnostics v_n = row_count;
  update bi.zt_snapshot set pan_india_target = round((select coalesce(sum(target_cases), 0) from bi.zt_row where snapshot_date = p_snap and row_type = 'leaf'))
   where snapshot_date = p_snap;
  return v_n;
end $f$;

-- Apply an active planned set to the month's report dates that have no targets of their own (or to one date).
create or replace function bi.target_fill_apply(p_set bigint, p_snap date, p_actor text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare s bi.target_fill_set; d date; v_rows int := 0; v_dates int := 0; v_skip int := 0; n int;
begin
  select * into s from bi.target_fill_set where id = p_set;
  if s.id is null or s.status <> 'active' then raise exception 'planned target set % is not active', p_set; end if;
  for d in select snapshot_date from bi.zt_snapshot where report_month = s.month and (p_snap is null or snapshot_date = p_snap) order by 1 loop
    if bi.target_fill_has_own(d) then v_skip := v_skip + 1; continue; end if;
    n := bi.target_fill_write(d, p_set, null, p_actor); v_rows := v_rows + n; v_dates := v_dates + 1;
  end loop;
  return jsonb_build_object('set', p_set, 'report_dates', v_dates, 'rows_changed', v_rows, 'dates_with_own_targets', v_skip);
end $f$;

-- Owner's targets arrived in p_src: the planned set ends and the month's other report dates without targets of their own take the owner's targets.
create or replace function bi.target_fill_owner_apply(p_src date, p_actor text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := (select report_month from bi.zt_snapshot where snapshot_date = p_src); d date; v_rows int := 0; v_dates int := 0; n int;
begin
  update bi.target_fill_set set status = 'replaced_by_owner', ended_at = now(), ended_by = p_actor, replaced_by_snapshot = p_src where month = v_m and status = 'active';
  for d in select snapshot_date from bi.zt_snapshot where report_month = v_m and snapshot_date <> p_src order by 1 loop
    if bi.target_fill_has_own(d) then continue; end if;
    n := bi.target_fill_write(d, null, p_src, p_actor); v_rows := v_rows + n; v_dates := v_dates + 1;
  end loop;
  return jsonb_build_object('owner_targets_from', p_src, 'report_dates', v_dates, 'rows_changed', v_rows);
end $f$;

-- Called at the end of every tracker upload (bi.commit_zonal).
create or replace function bi.target_fill_on_commit(p_snap date) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := (select report_month from bi.zt_snapshot where snapshot_date = p_snap); v_set bigint; v_src date; r jsonb;
begin
  update bi.target_fill_log set current = false where snapshot_date = p_snap and current;   -- the rows were just replaced by the new file
  if not exists (select 1 from bi.target_fill_set where month = v_m) then return null; end if;
  if bi.target_fill_has_own(p_snap) then
    if exists (select 1 from bi.target_fill_set where month = v_m and status in ('active', 'replaced_by_owner')) then
      r := bi.target_fill_owner_apply(p_snap, 'tracker upload');
      insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('tracker upload', 'target_fill_owner', 'zt_snapshot', p_snap::text, r);
      return r;
    end if;
    return null;
  end if;
  select id into v_set from bi.target_fill_set where month = v_m and status = 'active';
  if v_set is not null then
    r := bi.target_fill_apply(v_set, p_snap, 'tracker upload');
  else   -- the owner's targets already came for this month: a later file without targets keeps them
    select max(z.snapshot_date) into v_src from bi.zt_snapshot z where z.report_month = v_m and z.snapshot_date <> p_snap and bi.target_fill_has_own(z.snapshot_date)
       and exists (select 1 from bi.target_fill_set x where x.month = v_m and x.status = 'replaced_by_owner');
    if v_src is null then return null; end if;
    r := jsonb_build_object('owner_targets_from', v_src, 'rows_changed', bi.target_fill_write(p_snap, null, v_src, 'tracker upload'));
  end if;
  insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('tracker upload', 'target_fill_apply', 'zt_snapshot', p_snap::text, r);
  return r;
end $f$;

-- Make planned targets for the running month (admin); withdraw them (restores the values they replaced); status.
create or replace function bi.target_fill_plan(p_actor text, p_month date, p_reason text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := date_trunc('month', p_month)::date; v_latest date; j jsonb; v_id bigint; r jsonb;
begin
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
  if exists (select 1 from bi.target_fill_set where month = v_m and status = 'active') then
    raise exception 'Planned targets for % are already set; withdraw them first.', to_char(v_m, 'Mon-YY'); end if;
  select max(snapshot_date) into v_latest from bi.zt_snapshot where report_month = v_m;
  if v_latest is null then raise exception 'No tracker file for % yet.', to_char(v_m, 'Mon-YY'); end if;
  if bi.target_fill_has_own(v_latest) then raise exception 'The latest tracker file for % already has targets.', to_char(v_m, 'Mon-YY'); end if;
  j := bi.target_sheet_running(v_m, '{}'::jsonb, '{}'::jsonb);
  if j ? 'error' then raise exception '%', j->>'error'; end if;
  insert into bi.target_fill_set (month, method, totals, bridge, created_by, reason)
  values (v_m, j->>'method', j->'totals', j->'bridge', p_actor, p_reason) returning id into v_id;
  insert into bi.target_fill_row (set_id, location_id, client_code, target_cases, revenue_target, rate, situation, calc, reason)
  select v_id, (x->>'location_id')::int, x->>'client_code', sum((x->>'tgt_cases')::numeric), sum((x->>'tgt_rev')::numeric), max((x->>'rate')::numeric),
         string_agg(x->>'situation', ', '), string_agg(x->>'calc', ' | '), string_agg(x->>'reason', ' | ')
    from jsonb_array_elements(j->'rows') x
   where x->>'location_id' is not null and x->>'client_code' is not null
     and (coalesce((x->>'tgt_cases')::numeric, 0) > 0 or coalesce((x->>'tgt_rev')::numeric, 0) > 0)
   group by 2, 3;
  r := bi.target_fill_apply(v_id, null, p_actor);
  update bi.target_fill_set set totals = totals || jsonb_build_object('placed_rows', (select count(*) from bi.target_fill_row where set_id = v_id),
           'placed_rev', (select round(sum(revenue_target)) from bi.target_fill_row where set_id = v_id),
           'placed_cases', (select sum(target_cases) from bi.target_fill_row where set_id = v_id)) where id = v_id;
  insert into bi.audit_log (actor, action, entity, entity_key, detail)
  values (p_actor, 'target_fill_plan', 'target_fill_set', v_id::text, jsonb_build_object('month', v_m, 'reason', p_reason, 'apply', r,
          'revenue', (select round(sum(revenue_target)) from bi.target_fill_row where set_id = v_id), 'cases', (select sum(target_cases) from bi.target_fill_row where set_id = v_id)));
  return jsonb_build_object('ok', true, 'set', v_id, 'apply', r) || bi.target_source(v_m);
end $f$;

create or replace function bi.target_fill_withdraw(p_actor text, p_month date, p_reason text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := date_trunc('month', p_month)::date; v_id bigint; v_n int;
begin
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
  select id into v_id from bi.target_fill_set where month = v_m and status = 'active';
  if v_id is null then raise exception 'No active planned targets for %.', to_char(v_m, 'Mon-YY'); end if;
  create temp table if not exists _tw (id bigint, snapshot_date date, sheet_row int, otc numeric, ort numeric, oa numeric, osf numeric) on commit drop;
  truncate _tw;
  insert into _tw select g.id, g.snapshot_date, g.sheet_row, g.old_target_cases, g.old_revenue_target, g.old_achievement, g.old_shortfall
    from bi.target_fill_log g where g.set_id = v_id and g.kind = 'planned' and g.current;
  update bi.target_fill_log g set current = false from _tw w where g.id = w.id;
  insert into bi.target_fill_log (snapshot_date, sheet_row, set_id, kind, old_target_cases, old_revenue_target, new_target_cases, new_revenue_target, current, by)
  select w.snapshot_date, w.sheet_row, v_id, 'withdrawn', z.target_cases, z.revenue_target, w.otc, w.ort, false, p_actor
    from _tw w join bi.zt_row z on z.snapshot_date = w.snapshot_date and z.sheet_row = w.sheet_row;
  update bi.zt_row z set target_cases = w.otc, revenue_target = w.ort, achievement = w.oa, shortfall_revenue = w.osf
    from _tw w where z.snapshot_date = w.snapshot_date and z.sheet_row = w.sheet_row;
  get diagnostics v_n = row_count;
  update bi.zt_snapshot s set pan_india_target = round((select coalesce(sum(target_cases), 0) from bi.zt_row where snapshot_date = s.snapshot_date and row_type = 'leaf'))
   where s.snapshot_date in (select distinct snapshot_date from _tw);
  update bi.target_fill_set set status = 'withdrawn', ended_at = now(), ended_by = p_actor where id = v_id;
  insert into bi.audit_log (actor, action, entity, entity_key, detail)
  values (p_actor, 'target_fill_withdraw', 'target_fill_set', v_id::text, jsonb_build_object('month', v_m, 'reason', p_reason, 'rows_restored', v_n));
  return jsonb_build_object('ok', true, 'set', v_id, 'rows_restored', v_n);
end $f$;

-- Where the month's targets come from (shown on the Overview, read by Ask Crux, Admin -> Plan & targets).
create or replace function bi.target_source(p_month date) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with m as (select date_trunc('month', p_month)::date m),
       snap as (select max(z.snapshot_date) d from bi.zt_snapshot z, m where z.report_month = m.m),
       cur as (select g.kind, g.set_id, g.source_snapshot from bi.target_fill_log g, snap where g.snapshot_date = snap.d and g.current),
       st as (select s.* from bi.target_fill_set s, m where s.month = m.m order by s.id desc limit 1)
  select jsonb_build_object('target_source', jsonb_build_object(
    'source', case when exists (select 1 from cur where kind = 'planned') then 'planned'
                   when exists (select 1 from cur where kind = 'owner') then 'owner'
                   when exists (select 1 from bi.zt_row z, snap where z.snapshot_date = snap.d and z.row_type = 'leaf' and coalesce(z.target_cases, 0) <> 0) then 'tracker'
                   else 'none' end,
    'as_of', (select d from snap),
    'owner_targets_from', coalesce((select max(source_snapshot) from cur where kind = 'owner'), (select replaced_by_snapshot from st)),
    'set', (select jsonb_build_object('id', st.id, 'status', st.status, 'created_at', st.created_at, 'created_by', st.created_by, 'ended_at', st.ended_at,
                     'revenue', (select round(sum(r.revenue_target)) from bi.target_fill_row r where r.set_id = st.id),
                     'cases', (select sum(r.target_cases) from bi.target_fill_row r where r.set_id = st.id),
                     'rows', (select count(*) from bi.target_fill_row r where r.set_id = st.id)) from st)))
$f$;

create or replace function bi.target_fill_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'get'); v_m date := coalesce((p->>'month')::date, (select max(report_month) from bi.zt_snapshot));
begin
  if op = 'plan' then return bi.target_fill_plan(p_actor, v_m, p->>'reason');
  elsif op = 'withdraw' then return bi.target_fill_withdraw(p_actor, v_m, p->>'reason');
  elsif op = 'get' then
    return bi.target_source(v_m) || jsonb_build_object('month', v_m,
      'sets', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'month', s.month, 'status', s.status, 'created_at', s.created_at, 'created_by', s.created_by,
                 'reason', s.reason, 'ended_at', s.ended_at, 'ended_by', s.ended_by, 'replaced_by_snapshot', s.replaced_by_snapshot, 'bridge', s.bridge, 'totals', s.totals,
                 'report_dates', (select count(distinct g.snapshot_date) from bi.target_fill_log g where g.set_id = s.id and g.kind = 'planned' and g.current)) order by s.id desc), '[]'::jsonb)
               from bi.target_fill_set s where s.month >= (v_m - interval '3 months')::date),
      'rows', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', l.zone_group, 'location', l.label, 'client_code', r.client_code, 'client', coalesce(c.label, r.client_code),
                 'target_cases', r.target_cases, 'revenue_target', round(r.revenue_target), 'situation', r.situation, 'calc', r.calc, 'reason', r.reason)
                 order by l.zone_group, l.label, r.revenue_target desc), '[]'::jsonb)
               from bi.target_fill_row r join bi.location l on l.id = r.location_id left join bi.client c on c.code = r.client_code
              where r.set_id = (select max(id) from bi.target_fill_set where month = v_m)));
  end if;
  raise exception 'op must be get, plan or withdraw';
end $f$;

revoke all on function bi.target_fill_has_own(date), bi.target_fill_write(date, bigint, date, text), bi.target_fill_apply(bigint, date, text),
  bi.target_fill_owner_apply(date, text), bi.target_fill_on_commit(date), bi.target_fill_plan(text, date, text), bi.target_fill_withdraw(text, date, text),
  bi.target_fill_admin(text, jsonb) from public, anon, authenticated;   -- bi.target_source stays readable: the Overview function calls it

-- hooks: tracker upload, Overview (target source), admin action
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '113b');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.commit_zonal(bigint)'::regprocedure, array[
  $r$declare b bi.import_batch; h jsonb;$r$, $r$declare v_fill jsonb; b bi.import_batch; h jsonb;$r$,
  $r$  delete from bi.stg_row where batch_id=p_batch;$r$,
  $r$  delete from bi.stg_row where batch_id=p_batch;
  begin v_fill := bi.target_fill_on_commit(v_snap);   -- wave 113b: planned targets / the owner's targets
  exception when others then
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'zonal',v_snap::text,'target_fill_failed','warning',jsonb_build_object('error',sqlerrm));
  end;$r$,
  $r$'leaf_target',v_leaf_t,'leaf_mtd',v_leaf_m);$r$, $r$'leaf_target',v_leaf_t,'leaf_mtd',v_leaf_m,'target_fill',v_fill);$r$], array[1, 1, 1]);
select pg_temp.patch('bi.api_overview(date,jsonb)'::regprocedure, array[
  $r$  return j;$r$, $r$  j := j || bi.target_source(p_month);   -- wave 113b: where the month's targets come from
  return j;$r$], array[1]);
select pg_temp.patch('public.bi_admin(text,jsonb)'::regprocedure, array[
  $r$    when 'drive_config' then return bi.drive_config_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');   -- wave 112d$r$,
  $r$    when 'drive_config' then return bi.drive_config_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');   -- wave 112d
    when 'target_fill' then return bi.target_fill_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');   -- wave 113b$r$], array[1]);

-- applied 18-Nov-2026 14:20 UTC (owner request 19:30 IST): select bi.target_fill_plan('wave 113b', '2026-11-01', 'Owner 18-Nov-2026 19:30 IST: use the planned November targets until the owner uploads tracker files with targets (they replace these).');
-- result: set 4, 193 team x client rows, Rs 2,56,38,012 / 67,778 cases written to 12 November report dates (2,316 leaf rows); cache floor 7.
