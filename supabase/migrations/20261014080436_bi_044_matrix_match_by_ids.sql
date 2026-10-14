-- Applied to Supabase project via MCP on 20261014080436
-- committed values, base MTD and previous/next comparisons matched by (location_id, client_code): tracker labels change between snapshots (e.g. Rajasthan move on 3-Oct)
create or replace function bi.api_matrix(p_from date, p_to date) returns jsonb language sql stable security definer set search_path to 'bi','public' as $fn$
with d as (select g::date dt from generate_series(p_from, least(p_to, (now() at time zone 'Asia/Kolkata')::date), '1 day') g),
dates as (select dt,
   case when exists (select 1 from bi.zt_reopen r where r.snapshot_date = dt and r.active) then 'reopened'
        when exists (select 1 from bi.zt_snapshot s where s.snapshot_date = dt) then 'loaded'
        when exists (select 1 from bi.report_calendar_exception e where e.report_date = dt) then 'no_report'
        when exists (select 1 from bi.zt_matrix_draft m where m.snapshot_date = dt and m.committed_batch is null and coalesce(m.mtd_cases, m.target_cases, m.rate) is not null) then 'draft'
        when extract(isodow from dt) = 7 then 'not_expected'
        else 'missing' end status,
   (select jsonb_build_object('file', s.file_name, 'by', b.uploaded_by, 'at', coalesce(b.committed_at, s.loaded_at), 'mtd', s.pan_india_mtd)
      from bi.zt_snapshot s left join bi.import_batch b on b.id = s.batch_id where s.snapshot_date = dt) info,
   (select control_mtd from bi.zt_matrix_meta where snapshot_date = dt) control,
   (select reason from bi.report_calendar_exception where report_date = dt) no_report_reason,
   (select jsonb_build_object('by', reopened_by, 'at', reopened_at, 'reason', reason) from bi.zt_reopen where snapshot_date = dt and active) reopen
 from d),
tpl as (select max(snapshot_date) t from bi.zt_snapshot where snapshot_date <= p_to),
bs as (select max(snapshot_date) b from bi.zt_snapshot where snapshot_date < p_from and snapshot_date >= date_trunc('month', p_from)::date),
dr as (select location_label, client_label, jsonb_object_agg(snapshot_date, jsonb_strip_nulls(jsonb_build_object('mtd', mtd_cases, 'target', target_cases, 'rate', rate))) j
       from bi.zt_matrix_draft where snapshot_date between p_from and p_to and committed_batch is null and coalesce(mtd_cases, target_cases, rate) is not null group by 1, 2),
cmd as (select location_id, client_code, snapshot_date, sum(mtd_cases) m from bi.zt_row
        where row_type = 'leaf' and snapshot_date between p_from and p_to group by 1, 2, 3),
cm as (select location_id, client_code, jsonb_object_agg(snapshot_date, m) j from cmd group by 1, 2),
bv as (select z.location_id, z.client_code, sum(z.mtd_cases) m from bi.zt_row z, bs where z.snapshot_date = bs.b and z.row_type = 'leaf' group by 1, 2),
rows as (select r.sheet_row, r.location_label, r.client_label, r.rate, r.target_cases, r.mtd_cases, r.zone_group, l.stakeholder, l.region, l.tier, dr.j drafts, cm.j committed, bv.m base
  from bi.zt_row r join tpl on r.snapshot_date = tpl.t left join bi.location l on l.id = r.location_id
  left join dr on dr.location_label = r.location_label and dr.client_label = r.client_label
  left join cm on cm.location_id = r.location_id and cm.client_code = r.client_code
  left join bv on bv.location_id = r.location_id and bv.client_code = r.client_code
  where r.row_type = 'leaf')
select jsonb_build_object(
  'template_snapshot', (select t from tpl), 'base_snapshot', (select b from bs),
  'dates', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('date', dt, 'status', status, 'info', info, 'control', control, 'reason', no_report_reason, 'reopen', reopen)) order by dt) from dates),
  'rows', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('r', sheet_row, 'zone', zone_group, 'location', location_label, 'client', client_label, 'stakeholder', stakeholder,
             'region', region, 'tier', tier, 'rate', rate, 'target', target_cases, 'last_mtd', mtd_cases, 'base', base, 'drafts', drafts, 'committed', committed)) order by sheet_row) from rows),
  'cadence_note', 'Expected dates = Monday–Saturday (observed tracker cadence) minus admin-marked no-report days. Rows and order come from the latest tracker snapshot on or before the end of the range; committed values are matched by location and client codes, so renamed rows still line up.')
$fn$;

create or replace function bi.matrix_validate(p_date date) returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare v_reopened boolean := exists (select 1 from bi.zt_reopen where snapshot_date = p_date and active);
        v_prev date := bi.matrix_template(p_date);
        v_struct date; v_next date; v_sm boolean; v_ctl numeric; res jsonb;
begin
  v_struct := case when v_reopened then p_date else v_prev end;
  if v_struct is null then
    return jsonb_build_object('date', p_date, 'errors', 1, 'warnings', 0, 'issues', jsonb_build_array(jsonb_build_object('severity','error','rule','no_template')));
  end if;
  v_next := (select min(snapshot_date) from bi.zt_snapshot where snapshot_date > p_date and date_trunc('month', snapshot_date) = date_trunc('month', p_date));
  v_sm := v_prev is not null and date_trunc('month', v_prev) = date_trunc('month', p_date);
  v_ctl := (select control_mtd from bi.zt_matrix_meta where snapshot_date = p_date);
  with leaf as (select * from bi.zt_row where snapshot_date = v_struct and row_type = 'leaf'),
  pv as (select location_id, client_code, sum(mtd_cases) mtd_cases from bi.zt_row where snapshot_date = v_prev and row_type = 'leaf' group by 1, 2),
  nx as (select location_id, client_code, sum(mtd_cases) mtd_cases from bi.zt_row where snapshot_date = v_next and row_type = 'leaf' group by 1, 2),
  dr as (select * from bi.zt_matrix_draft where snapshot_date = p_date and committed_batch is null),
  j as (select l.location_label, l.client_label, case when v_sm then p.mtd_cases end pval, case when v_reopened then l.mtd_cases end oldv, d.mtd_cases cur, n.mtd_cases nextv,
               coalesce(d.target_cases, case when v_sm or v_reopened then l.target_cases end) tgt
        from leaf l left join pv p on p.location_id = l.location_id and p.client_code = l.client_code
        left join dr d on d.location_label = l.location_label and d.client_label = l.client_label
        left join nx n on n.location_id = l.location_id and n.client_code = l.client_code),
  chg as (select percentile_cont(0.9) within group (order by abs(mtd_cases - coalesce(src_prev_value, 0))) p90 from bi.zt_row where snapshot_date = v_prev and row_type = 'leaf'),
  issues as (
    select 'error' sev, 'missing_value' rule, location_label, client_label, pval::numeric a, cur::numeric b from j where cur is null
    union all select 'error', 'negative_value', location_label, client_label, pval, cur from j where cur < 0
    union all select 'error', 'unknown_row', d.location_label, d.client_label, null, d.mtd_cases from dr d
       where d.mtd_cases is not null and not exists (select 1 from leaf l where l.location_label = d.location_label and l.client_label = d.client_label)
    union all select 'error', 'already_loaded', null, null, null, null where not v_reopened and exists (select 1 from bi.zt_snapshot where snapshot_date = p_date)
    union all select 'warning', 'mtd_decreased', location_label, client_label, pval, cur from j where v_sm and cur < pval
    union all select 'warning', 'large_jump', location_label, client_label, pval, cur from j, chg where v_sm and cur - pval > greatest(25, 3 * coalesce(chg.p90, 0))
    union all select 'warning', 'above_next_snapshot', location_label, client_label, nextv, cur from j where nextv is not null and cur > nextv
    union all select 'warning', 'targets_missing', null, null, null, count(*)::numeric from j where tgt is null and not v_sm and not v_reopened having count(*) > 0
    union all select 'warning', 'control_total_mismatch', null, null, v_ctl, (select coalesce(sum(cur), 0) from j) where v_ctl is not null and v_ctl <> (select coalesce(sum(cur), 0) from j))
  select jsonb_build_object('date', p_date, 'template', v_prev, 'structure', v_struct, 'reopened', v_reopened, 'same_month', v_sm, 'next_snapshot', v_next, 'control_mtd', v_ctl,
    'rows_expected', (select count(*) from leaf), 'rows_entered', (select count(*) from dr where mtd_cases is not null),
    'total_mtd', (select sum(cur) from j), 'prev_total_mtd', (select sum(pval) from j), 'old_total_mtd', (select sum(oldv) from j),
    'changed_vs_committed', (select count(*) from j where v_reopened and cur is distinct from oldv),
    'errors', (select count(*) from issues where sev = 'error'), 'warnings', (select count(*) from issues where sev = 'warning'),
    'issues', coalesce((select jsonb_agg(jsonb_build_object('severity', sev, 'rule', rule, 'location', location_label, 'client', client_label, 'previous', a, 'entered', b)) from issues), '[]'),
    'changes', case when v_reopened then coalesce((select jsonb_agg(jsonb_build_object('location', location_label, 'client', client_label, 'old', oldv, 'new', cur)) from j where cur is distinct from oldv), '[]') end)
  into res;
  return res;
end $fn$;
