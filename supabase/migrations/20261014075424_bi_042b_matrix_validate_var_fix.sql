-- Applied to Supabase project via MCP on 20261014075424
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
  pv as (select location_label, client_label, mtd_cases from bi.zt_row where snapshot_date = v_prev and row_type = 'leaf'),
  nx as (select location_label, client_label, mtd_cases from bi.zt_row where snapshot_date = v_next and row_type = 'leaf'),
  dr as (select * from bi.zt_matrix_draft where snapshot_date = p_date and committed_batch is null),
  j as (select l.location_label, l.client_label, case when v_sm then p.mtd_cases end pval, case when v_reopened then l.mtd_cases end oldv, d.mtd_cases cur, n.mtd_cases nextv,
               coalesce(d.target_cases, case when v_sm or v_reopened then l.target_cases end) tgt
        from leaf l left join pv p using (location_label, client_label) left join dr d using (location_label, client_label) left join nx n using (location_label, client_label)),
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
