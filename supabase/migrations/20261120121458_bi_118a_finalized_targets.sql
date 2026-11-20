-- Applied to Supabase project via MCP on 20261120121458
-- wave 118a (20-Nov-2026, owner 17:35 IST): "I cant see an option where I can upload/update/edit the finalized target of November, and coming months,
-- as you would be using your planned target in mean while till I upload the finalized target."
-- Finalized targets = the owner's own targets for a month, uploaded (Excel) or edited on the dashboard (Admin → Plan & targets), for the running month and
-- up to 12 months ahead. A month's targets come from, in this order: finalized (dashboard) → the tracker files' own targets → planned by the dashboard.
--   * Saving writes the set into every report date of its month at once (rows not in the set keep their values) and into each later report date of the
--     month as its tracker file is imported. A set for a coming month waits and is written when that month's first tracker file arrives.
--   * Withdrawing restores exactly what the set replaced (the tracker's own targets, planned targets or an earlier finalized set).
--   * Planned targets for a new month are made automatically at night (01:05 IST) when its tracker files carry no targets and nothing is set yet.
--   * The quarter plan uses finalized targets for the months they cover.
-- Additive: new columns and functions; three existing functions patched with counted replacements (old bodies in bi.fn_backup, wave 118a).

alter table bi.target_fill_set add column if not exists kind text not null default 'planned';
alter table bi.target_fill_set add column if not exists file_name text;
alter table bi.target_fill_set add column if not exists replaced_by_set bigint;
alter table bi.target_fill_set drop constraint if exists target_fill_set_status_check;
alter table bi.target_fill_set add constraint target_fill_set_status_check check (status in ('active', 'replaced_by_owner', 'withdrawn', 'replaced_by_final', 'replaced'));
alter table bi.target_fill_set drop constraint if exists target_fill_set_kind_check;
alter table bi.target_fill_set add constraint target_fill_set_kind_check check (kind in ('planned', 'final'));
alter table bi.target_fill_row add column if not exists note text;
alter table bi.target_fill_log add column if not exists prev_log_id bigint;
alter table bi.target_fill_log drop constraint if exists target_fill_log_kind_check;
alter table bi.target_fill_log add constraint target_fill_log_kind_check check (kind in ('planned', 'owner', 'withdrawn', 'final'));

-- Write a finalized set into one report date: only the team × client rows in the set change (the first leaf row of a pair takes the value, repeats 0),
-- each change logged with the value it replaced and the log row that was in use before (restored on withdraw).
create or replace function bi.target_final_write(p_snap date, p_set bigint, p_actor text) returns integer language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_n int;
begin
  create temp table if not exists _tfn (sheet_row int, ntc numeric, nrt numeric, prev bigint) on commit drop;
  truncate _tfn;
  insert into _tfn
  with lf as (select z.sheet_row, z.location_id, z.client_code, z.target_cases, z.revenue_target,
                     row_number() over (partition by z.location_id, z.client_code order by z.sheet_row) rn
                from bi.zt_row z where z.snapshot_date = p_snap and z.row_type = 'leaf'),
       nv as (select lf.sheet_row, lf.target_cases, lf.revenue_target,
                     case when lf.rn = 1 then coalesce(r.target_cases, 0) else 0 end ntc, case when lf.rn = 1 then coalesce(r.revenue_target, 0) else 0 end nrt
                from lf join bi.target_fill_row r on r.set_id = p_set and r.location_id = lf.location_id and r.client_code = lf.client_code)
  select nv.sheet_row, nv.ntc, nv.nrt,
         (select g.id from bi.target_fill_log g where g.snapshot_date = p_snap and g.sheet_row = nv.sheet_row and g.current order by g.id desc limit 1)
    from nv where coalesce(nv.target_cases, 0) <> nv.ntc or coalesce(nv.revenue_target, 0) <> nv.nrt;
  update bi.target_fill_log g set current = false from _tfn t where g.snapshot_date = p_snap and g.sheet_row = t.sheet_row and g.current;
  insert into bi.target_fill_log (snapshot_date, sheet_row, set_id, kind, old_target_cases, old_revenue_target, old_achievement, old_shortfall,
                                  new_target_cases, new_revenue_target, by, prev_log_id)
  select p_snap, z.sheet_row, p_set, 'final', z.target_cases, z.revenue_target, z.achievement, z.shortfall_revenue, t.ntc, t.nrt, p_actor, t.prev
    from bi.zt_row z join _tfn t on t.sheet_row = z.sheet_row where z.snapshot_date = p_snap;
  update bi.zt_row z set target_cases = t.ntc, revenue_target = t.nrt,
         achievement = case when t.ntc > 0 then z.mtd_cases / t.ntc else 0 end,
         shortfall_revenue = case when z.revenue_actual is not null then z.revenue_actual - t.nrt end
    from _tfn t where z.snapshot_date = p_snap and z.sheet_row = t.sheet_row;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    update bi.zt_snapshot set pan_india_target = round((select coalesce(sum(target_cases), 0) from bi.zt_row where snapshot_date = p_snap and row_type = 'leaf'))
     where snapshot_date = p_snap;
  end if;
  return v_n;
end $f$;

-- Apply an active finalized set to every report date of its month (or one date).
create or replace function bi.target_final_apply(p_set bigint, p_snap date, p_actor text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare s bi.target_fill_set; d date; v_rows int := 0; v_dates int := 0; n int; v_last date; v_missing int;
begin
  select * into s from bi.target_fill_set where id = p_set;
  if s.id is null or s.kind <> 'final' or s.status <> 'active' then raise exception 'finalized target set % is not in use', p_set; end if;
  for d in select snapshot_date from bi.zt_snapshot where report_month = s.month and (p_snap is null or snapshot_date = p_snap) order by 1 loop
    n := bi.target_final_write(d, p_set, p_actor); v_rows := v_rows + n; v_dates := v_dates + 1;
  end loop;
  select max(snapshot_date) into v_last from bi.zt_snapshot where report_month = s.month;
  if v_last is not null then
    select count(*) into v_missing from bi.target_fill_row r where r.set_id = p_set
       and not exists (select 1 from bi.zt_row z where z.snapshot_date = v_last and z.row_type = 'leaf' and z.location_id = r.location_id and z.client_code = r.client_code);
  end if;
  return jsonb_build_object('set', p_set, 'report_dates', v_dates, 'rows_changed', v_rows, 'rows_not_in_tracker', v_missing, 'waiting_for_tracker', v_last is null);
end $f$;

-- Save finalized targets for a month (rows: location_id, client_code, target_cases, revenue_target, note). Replaces the set in use for the month.
create or replace function bi.target_final_save(p_actor text, p_month date, p_rows jsonb, p_reason text, p_file text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := date_trunc('month', p_month)::date; v_run date := (select max(report_month) from bi.zt_snapshot); v_last date := (select max(snapshot_date) from bi.zt_snapshot);
        v_prev bi.target_fill_set; v_id bigint; v_bad int; r jsonb; v_tot jsonb;
begin
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
  if v_m < v_run then raise exception 'Finalized targets can be set for the running month (%) and later months only.', to_char(v_run, 'Mon-YY'); end if;
  if v_m > (v_run + interval '12 months')::date then raise exception 'Finalized targets can be set up to 12 months ahead.'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'no target rows'; end if;
  if jsonb_array_length(p_rows) > 3000 then raise exception 'too many rows (%)', jsonb_array_length(p_rows); end if;
  create temp table if not exists _fr (location_id int, client_code text, tc numeric, rt numeric, note text) on commit drop;
  truncate _fr;
  insert into _fr select nullif(x->>'location_id', '')::int, nullif(upper(trim(x->>'client_code')), ''), nullif(x->>'target_cases', '')::numeric,
                         nullif(x->>'revenue_target', '')::numeric, left(nullif(trim(x->>'note'), ''), 300)
    from jsonb_array_elements(p_rows) x;
  select count(*) into v_bad from _fr f
   where f.location_id is null or f.client_code is null or coalesce(f.tc, 0) < 0 or coalesce(f.rt, 0) < 0 or (f.tc is null and f.rt is null)
      or not exists (select 1 from bi.location l where l.id = f.location_id) or not exists (select 1 from bi.client c where c.code = f.client_code);
  if v_bad > 0 then raise exception '% row(s) have an unknown team or client, a negative figure or no figure — fix them first', v_bad; end if;
  if exists (select 1 from _fr group by location_id, client_code having count(*) > 1) then raise exception 'the same team × client appears more than once'; end if;
  select * into v_prev from bi.target_fill_set where month = v_m and status = 'active' order by id desc limit 1;
  if v_prev.id is not null then
    update bi.target_fill_set set status = case when kind = 'planned' then 'replaced_by_final' else 'replaced' end, ended_at = now(), ended_by = p_actor where id = v_prev.id;
  end if;
  insert into bi.target_fill_set (month, kind, status, method, totals, created_by, reason, file_name)
  values (v_m, 'final', 'active', 'Your finalized targets (uploaded or edited on the dashboard)', '{}'::jsonb, p_actor, p_reason, nullif(trim(p_file), ''))
  returning id into v_id;
  if v_prev.id is not null then update bi.target_fill_set set replaced_by_set = v_id where id = v_prev.id; end if;
  insert into bi.target_fill_row (set_id, location_id, client_code, target_cases, revenue_target, rate, note)
  select v_id, f.location_id, f.client_code, coalesce(f.tc, case when rr.rate > 0 then round(f.rt / rr.rate) end), coalesce(f.rt, f.tc * rr.rate), rr.rate, f.note
    from _fr f left join lateral (select max(z.rate) rate from bi.zt_row z where z.snapshot_date = v_last and z.row_type = 'leaf'
                                    and z.location_id = f.location_id and z.client_code = f.client_code) rr on true;
  r := bi.target_final_apply(v_id, null, p_actor);
  v_tot := jsonb_build_object('rows', (select count(*) from bi.target_fill_row where set_id = v_id), 'cases', (select sum(target_cases) from bi.target_fill_row where set_id = v_id),
                              'revenue', (select round(sum(revenue_target)) from bi.target_fill_row where set_id = v_id), 'apply', r,
                              'replaced', case when v_prev.id is not null then jsonb_build_object('set', v_prev.id, 'kind', v_prev.kind) end);
  update bi.target_fill_set set totals = v_tot where id = v_id;
  if coalesce((r->>'rows_changed')::int, 0) > 0 then
    insert into bi.api_cache_floor (floor_at, reason, set_by) values (now(), 'finalized targets ' || to_char(v_m, 'Mon-YY'), p_actor);
  end if;
  insert into bi.audit_log (actor, action, entity, entity_key, detail)
  values (p_actor, 'target_final_save', 'target_fill_set', v_id::text, jsonb_build_object('month', v_m, 'reason', p_reason, 'file', p_file) || v_tot);
  return jsonb_build_object('ok', true, 'set', v_id) || v_tot || bi.target_source(v_m);
end $f$;

-- Withdraw the finalized targets in use for a month: every value they replaced comes back, and what was in use before (planned, the tracker's own
-- targets or an earlier finalized set) is in use again — also for report dates imported while they were in use.
create or replace function bi.target_final_withdraw(p_actor text, p_month date, p_reason text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := date_trunc('month', p_month)::date; s bi.target_fill_set; p bi.target_fill_set; v_n int; d date; v_src date; v_re jsonb := '[]'::jsonb;
begin
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
  select * into s from bi.target_fill_set where month = v_m and status = 'active' and kind = 'final';
  if s.id is null then raise exception 'No finalized targets in use for %.', to_char(v_m, 'Mon-YY'); end if;
  create temp table if not exists _tw2 (id bigint, snapshot_date date, sheet_row int, otc numeric, ort numeric, oa numeric, osf numeric, prev bigint) on commit drop;
  truncate _tw2;
  insert into _tw2 select g.id, g.snapshot_date, g.sheet_row, g.old_target_cases, g.old_revenue_target, g.old_achievement, g.old_shortfall, g.prev_log_id
    from bi.target_fill_log g where g.set_id = s.id and g.kind = 'final' and g.current;
  update bi.target_fill_log g set current = false from _tw2 w where g.id = w.id;
  insert into bi.target_fill_log (snapshot_date, sheet_row, set_id, kind, old_target_cases, old_revenue_target, new_target_cases, new_revenue_target, current, by)
  select w.snapshot_date, w.sheet_row, s.id, 'withdrawn', z.target_cases, z.revenue_target, w.otc, w.ort, false, p_actor
    from _tw2 w join bi.zt_row z on z.snapshot_date = w.snapshot_date and z.sheet_row = w.sheet_row;
  update bi.zt_row z set target_cases = w.otc, revenue_target = w.ort, achievement = w.oa, shortfall_revenue = w.osf
    from _tw2 w where z.snapshot_date = w.snapshot_date and z.sheet_row = w.sheet_row;
  get diagnostics v_n = row_count;
  update bi.target_fill_log g set current = true from _tw2 w where g.id = w.prev;
  update bi.zt_snapshot x set pan_india_target = round((select coalesce(sum(target_cases), 0) from bi.zt_row where snapshot_date = x.snapshot_date and row_type = 'leaf'))
   where x.snapshot_date in (select distinct snapshot_date from _tw2);
  update bi.target_fill_set set status = 'withdrawn', ended_at = now(), ended_by = p_actor where id = s.id;
  -- the set it replaced is in use again; report dates imported meanwhile get its targets too
  select * into p from bi.target_fill_set where replaced_by_set = s.id and status in ('replaced_by_final', 'replaced') order by id desc limit 1;
  if p.id is not null then
    update bi.target_fill_set set status = 'active', ended_at = null, ended_by = null, replaced_by_set = null where id = p.id;
    if p.kind = 'final' then v_re := to_jsonb(bi.target_final_apply(p.id, null, p_actor));
    else v_re := to_jsonb(bi.target_fill_apply(p.id, null, p_actor)); end if;
  elsif exists (select 1 from bi.target_fill_set where month = v_m and status = 'replaced_by_owner') then
    -- the owner's tracker targets: report dates without targets of their own carry the latest file that has them
    select max(x.snapshot_date) into v_src from bi.zt_snapshot x where x.report_month = v_m and bi.target_fill_has_own(x.snapshot_date);
    if v_src is not null then
      for d in select snapshot_date from bi.zt_snapshot where report_month = v_m and snapshot_date <> v_src order by 1 loop
        if not bi.target_fill_has_own(d) then perform bi.target_fill_write(d, null, v_src, p_actor); end if;
      end loop;
      v_re := jsonb_build_object('owner_targets_from', v_src);
    end if;
  end if;
  insert into bi.api_cache_floor (floor_at, reason, set_by) values (now(), 'finalized targets withdrawn ' || to_char(v_m, 'Mon-YY'), p_actor);
  insert into bi.audit_log (actor, action, entity, entity_key, detail)
  values (p_actor, 'target_final_withdraw', 'target_fill_set', s.id::text, jsonb_build_object('month', v_m, 'reason', p_reason, 'rows_restored', v_n,
          'back_in_use', case when p.id is not null then jsonb_build_object('set', p.id, 'kind', p.kind) end, 'reapplied', v_re));
  return jsonb_build_object('ok', true, 'set', s.id, 'rows_restored', v_n) || bi.target_source(v_m);
end $f$;

-- Rows for the template / on-screen editor of a month: every team × client of the month's latest tracker file (running month) or of the dashboard's
-- suggested target sheet (coming month), with the target in use now, the dashboard's suggestion and the finalized target if one is saved.
create or replace function bi.target_final_template(p_month date) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := date_trunc('month', p_month)::date; v_last date := (select max(snapshot_date) from bi.zt_snapshot where report_month = date_trunc('month', p_month)::date);
        v_fin bigint := (select id from bi.target_fill_set where month = date_trunc('month', p_month)::date and kind = 'final' and status = 'active' order by id desc limit 1);
        v_pl bigint := (select max(id) from bi.target_fill_set where month = date_trunc('month', p_month)::date and kind = 'planned');
        j jsonb; v_rows jsonb;
begin
  create temp table if not exists _ft (location_id int, client_code text, rate numeric, cur_cases numeric, cur_rev numeric, sug_cases numeric, sug_rev numeric) on commit drop;
  truncate _ft;
  if v_last is not null then
    insert into _ft select z.location_id, z.client_code, max(z.rate), sum(coalesce(z.target_cases, 0)), sum(coalesce(z.revenue_target, 0)), null, null
      from bi.zt_row z where z.snapshot_date = v_last and z.row_type = 'leaf' and z.location_id is not null and z.client_code is not null group by 1, 2;
    update _ft t set sug_cases = r.target_cases, sug_rev = r.revenue_target from bi.target_fill_row r where r.set_id = v_pl and r.location_id = t.location_id and r.client_code = t.client_code;
  else
    j := bi.api_target_sheet(v_m, '{}'::jsonb, '{"catchup": 1, "cap_over_last": 0.5, "gmin": 0.02}'::jsonb);
    if j ? 'error' then raise exception '%', j->>'error'; end if;
    insert into _ft select (x->>'location_id')::int, x->>'client_code', max((x->>'rate')::numeric), null, null, sum((x->>'tgt_cases')::numeric), sum((x->>'tgt_rev')::numeric)
      from jsonb_array_elements(j->'rows') x where x->>'location_id' is not null and x->>'client_code' is not null group by 1, 2;
  end if;
  insert into _ft (location_id, client_code, rate)   -- finalized rows that are not in the list above
  select r.location_id, r.client_code, r.rate from bi.target_fill_row r where r.set_id = v_fin
     and not exists (select 1 from _ft t where t.location_id = r.location_id and t.client_code = r.client_code);
  select coalesce(jsonb_agg(jsonb_build_object('zone_group', l.zone_group, 'location_id', t.location_id, 'location', l.label, 'client_code', t.client_code, 'client', coalesce(c.label, t.client_code),
           'rate', t.rate, 'cur_cases', t.cur_cases, 'cur_rev', round(t.cur_rev), 'sug_cases', t.sug_cases, 'sug_rev', round(t.sug_rev),
           'fin_cases', f.target_cases, 'fin_rev', round(f.revenue_target), 'note', f.note)
           order by l.zone_group, l.label, coalesce(t.cur_rev, t.sug_rev, f.revenue_target, 0) desc), '[]'::jsonb)
    into v_rows
    from _ft t join bi.location l on l.id = t.location_id left join bi.client c on c.code = t.client_code
    left join bi.target_fill_row f on f.set_id = v_fin and f.location_id = t.location_id and f.client_code = t.client_code;
  return jsonb_build_object('month', v_m, 'has_tracker', v_last is not null, 'as_of', v_last, 'final_set', v_fin,
    'basis', case when v_last is not null then 'team × client rows of the latest tracker file of the month' else 'team × client rows of the dashboard''s suggested target sheet for the month' end,
    'rows', v_rows) || bi.target_source(v_m);
end $f$;

-- Planned targets for a new month whose tracker files carry no targets (nightly; nothing happens when any target set exists for the month).
create or replace function bi.target_fill_auto() returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_m date := (select max(report_month) from bi.zt_snapshot); v_last date; r jsonb;
begin
  if v_m is null then return jsonb_build_object('skipped', 'no tracker files'); end if;
  if exists (select 1 from bi.target_fill_set where month = v_m) then return jsonb_build_object('skipped', 'a target set exists for ' || to_char(v_m, 'Mon-YY')); end if;
  select max(snapshot_date) into v_last from bi.zt_snapshot where report_month = v_m;
  if bi.target_fill_has_own(v_last) then return jsonb_build_object('skipped', 'the tracker files of ' || to_char(v_m, 'Mon-YY') || ' carry targets'); end if;
  r := bi.target_fill_plan('nightly (automatic)', v_m, 'Automatic: the tracker files of this month carry no targets yet; planned targets are used until your finalized targets or a tracker file with targets arrive.');
  insert into bi.api_cache_floor (floor_at, reason, set_by) values (now(), 'planned targets ' || to_char(v_m, 'Mon-YY'), 'nightly');
  return r;
end $f$;

-- Where the month's targets come from: finalized → planned → the tracker's targets carried from the owner's file → the tracker files → none.
create or replace function bi.target_source(p_month date) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with m as (select date_trunc('month', p_month)::date m),
       snap as (select max(z.snapshot_date) d from bi.zt_snapshot z, m where z.report_month = m.m),
       cur as (select g.kind, g.set_id, g.source_snapshot from bi.target_fill_log g, snap where g.snapshot_date = snap.d and g.current),
       st as (select s.* from bi.target_fill_set s, m where s.month = m.m order by s.id desc limit 1),
       fin as (select s.* from bi.target_fill_set s, m where s.month = m.m and s.kind = 'final' and s.status = 'active' order by s.id desc limit 1)
  select jsonb_build_object('target_source', jsonb_build_object(
    'source', case when exists (select 1 from fin) then 'final'
                   when exists (select 1 from cur where kind = 'planned') then 'planned'
                   when exists (select 1 from cur where kind = 'owner') then 'owner'
                   when exists (select 1 from bi.zt_row z, snap where z.snapshot_date = snap.d and z.row_type = 'leaf' and coalesce(z.target_cases, 0) <> 0) then 'tracker'
                   else 'none' end,
    'as_of', (select d from snap),
    'owner_targets_from', coalesce((select max(source_snapshot) from cur where kind = 'owner'), (select replaced_by_snapshot from st)),
    'set', (select jsonb_build_object('id', st.id, 'kind', st.kind, 'status', st.status, 'created_at', st.created_at, 'created_by', st.created_by, 'ended_at', st.ended_at,
                     'revenue', (select round(sum(r.revenue_target)) from bi.target_fill_row r where r.set_id = st.id),
                     'cases', (select sum(r.target_cases) from bi.target_fill_row r where r.set_id = st.id),
                     'rows', (select count(*) from bi.target_fill_row r where r.set_id = st.id)) from st),
    'final', (select jsonb_build_object('id', fin.id, 'created_at', fin.created_at, 'created_by', fin.created_by, 'file_name', fin.file_name, 'reason', fin.reason,
                     'revenue', (select round(sum(r.revenue_target)) from bi.target_fill_row r where r.set_id = fin.id),
                     'cases', (select sum(r.target_cases) from bi.target_fill_row r where r.set_id = fin.id),
                     'rows', (select count(*) from bi.target_fill_row r where r.set_id = fin.id),
                     'applied', (select d from snap) is not null) from fin)))
$f$;

create or replace function bi.target_fill_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'get'); v_run date := (select max(report_month) from bi.zt_snapshot); v_m date := coalesce((p->>'month')::date, (select max(report_month) from bi.zt_snapshot));
begin
  if op = 'plan' then return bi.target_fill_plan(p_actor, v_m, p->>'reason');
  elsif op = 'withdraw' then return bi.target_fill_withdraw(p_actor, v_m, p->>'reason');
  elsif op = 'final_template' then return bi.target_final_template(v_m);   -- wave 118a
  elsif op = 'final_save' then return bi.target_final_save(p_actor, v_m, p->'rows', p->>'reason', p->>'file');
  elsif op = 'final_withdraw' then return bi.target_final_withdraw(p_actor, v_m, p->>'reason');
  elsif op = 'get' then
    return bi.target_source(v_m) || jsonb_build_object('month', v_m, 'running_month', v_run,
      'months', (select jsonb_agg(jsonb_build_object('month', g::date) || bi.target_source(g::date) order by g)
                   from generate_series(v_run, v_run + interval '3 months', interval '1 month') g),
      'sets', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'month', s.month, 'kind', s.kind, 'status', s.status, 'created_at', s.created_at, 'created_by', s.created_by,
                 'reason', s.reason, 'file_name', s.file_name, 'ended_at', s.ended_at, 'ended_by', s.ended_by, 'replaced_by_snapshot', s.replaced_by_snapshot, 'replaced_by_set', s.replaced_by_set,
                 'bridge', s.bridge, 'totals', s.totals,
                 'report_dates', (select count(distinct g.snapshot_date) from bi.target_fill_log g where g.set_id = s.id and g.kind in ('planned', 'final') and g.current)) order by s.id desc), '[]'::jsonb)
               from bi.target_fill_set s where s.month >= (v_m - interval '3 months')::date),
      'rows', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', l.zone_group, 'location', l.label, 'client_code', r.client_code, 'client', coalesce(c.label, r.client_code),
                 'target_cases', r.target_cases, 'revenue_target', round(r.revenue_target), 'situation', r.situation, 'calc', r.calc, 'reason', r.reason)
                 order by l.zone_group, l.label, r.revenue_target desc), '[]'::jsonb)
               from bi.target_fill_row r join bi.location l on l.id = r.location_id left join bi.client c on c.code = r.client_code
              where r.set_id = (select max(id) from bi.target_fill_set where month = v_m and kind = 'planned')));
  end if;
  raise exception 'op must be get, plan, withdraw, final_template, final_save or final_withdraw';
end $f$;

revoke all on function bi.target_final_write(date, bigint, text), bi.target_final_apply(bigint, date, text), bi.target_final_save(text, date, jsonb, text, text),
  bi.target_final_withdraw(text, date, text), bi.target_final_template(date), bi.target_fill_auto(), bi.target_fill_admin(text, jsonb) from public, anon, authenticated;

-- patches: tracker upload (finalized targets win), "own targets" test, planned-only operations, the quarter plan
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '118a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.target_fill_on_commit(date)'::regprocedure, array[
  $r$  update bi.target_fill_log set current = false where snapshot_date = p_snap and current;   -- the rows were just replaced by the new file$r$,
  $r$  update bi.target_fill_log set current = false where snapshot_date = p_snap and current;   -- the rows were just replaced by the new file
  -- wave 118a: the owner's finalized targets win over the file's own targets and over planned targets
  select id into v_set from bi.target_fill_set where month = v_m and status = 'active' and kind = 'final';
  if v_set is not null then
    r := jsonb_build_object('final_set', v_set, 'rows_changed', bi.target_final_write(p_snap, v_set, 'tracker upload'));
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('tracker upload', 'target_final_apply', 'zt_snapshot', p_snap::text, r);
    return r;
  end if;$r$], array[1]);

select pg_temp.patch('bi.target_fill_has_own(date)'::regprocedure, array[
  $r$g.kind in ('planned', 'owner')$r$, $r$g.kind in ('planned', 'owner', 'final')$r$], array[1]);

select pg_temp.patch('bi.target_fill_owner_apply(date,text)'::regprocedure, array[
  $r$where month = v_m and status = 'active';$r$, $r$where month = v_m and status = 'active' and kind = 'planned';$r$], array[1]);

select pg_temp.patch('bi.target_fill_withdraw(text,date,text)'::regprocedure, array[
  $r$select id into v_id from bi.target_fill_set where month = v_m and status = 'active';$r$,
  $r$select id into v_id from bi.target_fill_set where month = v_m and status = 'active' and kind = 'planned';$r$], array[1]);

select pg_temp.patch('bi.api_plan(date,jsonb,jsonb)'::regprocedure, array[
  $r$  _f as materialized (select pf.month, pf.factor from bi.plan_factors(v_ref, v_q0, (v_q0 + interval '5 months')::date) pf),$r$,
  $r$  -- wave 118a: the owner's finalized targets (Admin → Plan & targets) for the months they cover
  _fi as materialized (
    select s.month, coalesce(c.family, r.client_code) fam, r.location_id, l.zone_group, sum(r.revenue_target) fi
      from bi.target_fill_set s join bi.target_fill_row r on r.set_id = s.id join bi.location l on l.id = r.location_id left join bi.client c on c.code = r.client_code
     where s.kind = 'final' and s.status = 'active' and s.month in (select month from _m)
       and bi.loc_ok(r.location_id, l.recon_unit, f, s.month) and bi.fam_ok(r.client_code, f)
     group by 1, 2, 3, 4),
  _f as materialized (select pf.month, pf.factor from bi.plan_factors(v_ref, v_q0, (v_q0 + interval '5 months')::date) pf),$r$,
  $r$union select month, fam, location_id from _sg),$r$, $r$union select month, fam, location_id from _sg union select month, fam, location_id from _fi),$r$,
  $r$coalesce(l.zone_group, pl.zone_group, fc.zone_group, sg.zone_group) zone_group$r$, $r$coalesce(l.zone_group, pl.zone_group, fc.zone_group, sg.zone_group, fi.zone_group) zone_group$r$,
  $r$a.actual, a.tt, a.as_of, pl.plan, fc.fc, sg.sg$r$, $r$a.actual, a.tt, a.as_of, pl.plan, fc.fc, sg.sg, fi.fi$r$,
  $r$            left join bi.location l on l.id = k.location_id),$r$,
  $r$            left join _fi fi on fi.month = k.month and fi.fam = k.fam and fi.location_id is not distinct from k.location_id
            left join bi.location l on l.id = k.location_id),$r$,
  $r$case when j.plan is not null then 'plan' when j.tt is not null then 'tracker target'$r$,
  $r$case when j.fi is not null then 'your finalized target' when j.plan is not null then 'plan' when j.tt is not null then 'tracker target'$r$,
  $r$coalesce(j.plan, j.tt, j.sg) plan_value$r$, $r$coalesce(j.fi, j.plan, j.tt, j.sg) plan_value$r$], array[1, 1, 1, 1, 1, 1, 1]);

-- nightly: planned targets for a new month whose tracker files carry no targets (01:05 IST)
select cron.schedule('bi-target-auto', '35 19 * * *', $c$set statement_timeout = '170s'; select bi.target_fill_auto()$c$);
