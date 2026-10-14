-- Applied to Supabase project via MCP on 20261014112359
create or replace function bi.test_rate_change() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare s date := (select max(snapshot_date) from bi.zt_snapshot); m0 date; loc int; cli text; old_rate numeric; v_wef date; d date;
        pv jsonb; ap jsonb; en jsonb; cm jsonb; exp_rev numeric; got_rev numeric; exp_tgt numeric; got_tgt numeric; after_end numeric; mtd_s numeric; tgt_s numeric;
        rc_rows int; d_rev numeric; d_exp numeric; d_mtd numeric; persisted int; ok boolean := false; err text; cells jsonb; lbl_l text; lbl_c text;
begin
  m0 := date_trunc('month', s)::date;
  select z.location_id, z.client_code, z.rate, z.location_label, z.client_label into loc, cli, old_rate, lbl_l, lbl_c
    from bi.zt_row z where z.snapshot_date = s and z.row_type = 'leaf' and z.rate > 0 and z.target_cases > 0
     and (select count(*) from bi.zt_row y where y.row_type = 'leaf' and y.location_id = z.location_id and y.client_code = z.client_code and y.snapshot_date between m0 and s) >= 3
    order by z.mtd_cases desc limit 1;
  select snapshot_date into v_wef from bi.zt_snapshot where report_month = m0 order by snapshot_date desc offset 1 limit 1;
  begin
    pv := bi.rate_admin('test', jsonb_build_object('op', 'preview', 'rate', old_rate + 10, 'wef', v_wef, 'reason', 'T25 test change', 'rows', jsonb_build_array(jsonb_build_object('location_id', loc, 'client_code', cli))));
    select count(*) into persisted from bi.rate_change where reason = 'T25 test change';
    ap := bi.rate_admin('test', jsonb_build_object('op', 'apply', 'rate', old_rate + 10, 'wef', v_wef, 'reason', 'T25 test change', 'rows', jsonb_build_array(jsonb_build_object('location_id', loc, 'client_code', cli))));
    select sum(de * case when dd >= v_wef then old_rate + 10 else old_rate end) into exp_rev from (
      select snapshot_date dd, mtd_cases - coalesce(lag(mtd_cases) over (order by snapshot_date), 0) de
      from bi.zt_row where row_type = 'leaf' and location_id = loc and client_code = cli and snapshot_date between m0 and s) q;
    select revenue_actual, revenue_target, mtd_cases, target_cases into got_rev, got_tgt, mtd_s, tgt_s from bi.zt_row where snapshot_date = s and row_type = 'leaf' and location_id = loc and client_code = cli;
    exp_tgt := case when mtd_s < tgt_s then exp_rev + (tgt_s - mtd_s) * (old_rate + 10) else tgt_s * exp_rev / mtd_s end;
    en := bi.rate_admin('test', jsonb_build_object('op', 'end', 'id', (select id from bi.rate_change where reason = 'T25 test change' and active), 'reason', 'T25 undo test'));
    select revenue_actual into after_end from bi.zt_row where snapshot_date = s and row_type = 'leaf' and location_id = loc and client_code = cli;

    d := s + 1; if extract(isodow from d) = 7 then d := d + 1; end if;
    select jsonb_agg(jsonb_build_object('date', d, 'location', location_label, 'client', client_label,
             'mtd', mtd_cases + case when location_id = loc and client_code = cli then 3 else 0 end,
             'rate', case when location_id = loc and client_code = cli then old_rate + 20 end))
      into cells from bi.zt_row where snapshot_date = s and row_type = 'leaf';
    perform bi.matrix_save('test', jsonb_build_object('cells', cells));
    cm := bi.matrix_commit('test', d, true, 'T25 rate via daily table');
    select count(*) into rc_rows from bi.rate_change where location_id = loc and client_code = cli and wef = d and source = 'daily_table' and active and rate = old_rate + 20;
    select revenue_actual, mtd_cases into d_rev, d_mtd from bi.zt_row where snapshot_date = d and row_type = 'leaf' and location_id = loc and client_code = cli;
    d_exp := case when date_trunc('month', d) = m0 then after_end + 3 * (old_rate + 20) else d_mtd * (old_rate + 20) end;
    ok := persisted = 0 and (pv->>'applied')::boolean = false and (ap->>'applied')::boolean
          and abs(got_rev - exp_rev) < 0.01 and abs(got_tgt - exp_tgt) < 0.01 and got_rev <> mtd_s * old_rate
          and (en->>'ended')::boolean and abs(after_end - mtd_s * old_rate) < 0.01
          and coalesce((cm->>'committed')::boolean, false) and rc_rows = 1 and abs(d_rev - d_exp) < 0.01;
    raise exception 'rollback_t25';
  exception when others then
    err := sqlerrm;
  end;
  return jsonb_build_object('passed', ok and err = 'rollback_t25' and not exists (select 1 from bi.rate_change where reason like 'T25%' or reason like '%T25%'),
    'row', lbl_l || ' / ' || lbl_c, 'old_rate', old_rate, 'wef', v_wef, 'snapshot', s,
    'expected_revenue', exp_rev, 'revenue', got_rev, 'expected_revenue_target', exp_tgt, 'revenue_target', got_tgt, 'revenue_single_rate', mtd_s * old_rate,
    'after_undo', after_end, 'daily_table_date', d, 'daily_table_revenue', d_rev, 'daily_table_expected', d_exp, 'rate_change_recorded', rc_rows,
    'preview_persisted', persisted, 'commit', cm - 'rates', 'error', nullif(err, 'rollback_t25'));
end $fn$;
