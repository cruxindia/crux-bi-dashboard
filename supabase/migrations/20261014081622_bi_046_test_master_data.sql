-- Applied to Supabase project via MCP on 20261014081622
-- bi_046: acceptance test T24 — master imports, branch coverage, attrition (all writes rolled back)
create or replace function bi.test_master_data() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare cut date := (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date;
        rc text; oc text; emp text; r1 jsonb; r2 jsonb; dr jsonb; c0 jsonb; c jsonb; w1 jsonb; a0 jsonb; a jsonb; lv jsonb; m date; exp_ppm numeric; ok boolean := false; err text;
begin
  select branch_code into rc from bi.case_store where client_code = 'SBI' and nullif(branch_code, '') is not null group by branch_code having max(received_month) >= cut order by count(*) desc limit 1;
  select branch_code into oc from bi.case_store where client_code = 'SBI' and nullif(branch_code, '') is not null group by branch_code having max(received_month) < cut order by count(*) desc limit 1;
  select d.val into emp from bi.point_derived pd join bi.dim d on d.id = pd.verifier_id and d.kind = 'emp' group by d.val order by max(pd.created_month) desc, count(*) desc limit 1;
  m := (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '1 month')::date;
  select round(count(*)::numeric / 3, 1) into exp_ppm from bi.point_derived pd join bi.dim d on d.id = pd.verifier_id and d.kind = 'emp'
   where d.val = emp and pd.created_month >= (m - interval '3 months')::date and pd.created_month < m;
  c0 := bi.api_branch_coverage('{"client_family":"SBI"}');
  a0 := bi.api_attrition(m, '{}');
  begin
    dr := bi.master_import('test', jsonb_build_object('kind', 'branch', 'dry_run', true, 'rows', jsonb_build_array(
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24A', 'source', 't', 'verified_on', '2026-10-14'),
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24A', 'source', 't', 'verified_on', '2026-10-14'),
            jsonb_build_object('client', 'NO SUCH BANK', 'branch_code', 'T24B', 'source', 't', 'verified_on', 'x'))));
    r1 := bi.master_import('test', jsonb_build_object('kind', 'branch', 'dry_run', false, 'rows', jsonb_build_array(
            jsonb_build_object('client', 'SBI', 'branch_code', regexp_replace(rc, '^0+', ''), 'source', 't', 'verified_on', '2026-10-14'),
            jsonb_build_object('client', 'sbi', 'branch_code', oc, 'source', 't', 'verified_on', '14-Oct-2026'),
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24-NEVER', 'source', 't', 'verified_on', '46309'),
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24-CLOSED', 'status', 'closed', 'source', 't', 'verified_on', '2026-10-14'))));
    r2 := bi.master_import('test', jsonb_build_object('kind', 'branch', 'dry_run', false, 'rows', jsonb_build_array(
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24-NEVER', 'branch_name', 'renamed', 'source', 't', 'verified_on', '2026-10-14'))));
    c := bi.api_branch_coverage('{"client_family":"SBI"}');
    w1 := bi.master_import('test', jsonb_build_object('kind', 'workforce', 'dry_run', false, 'rows', jsonb_build_array(
            jsonb_build_object('name', emp, 'role', 'T24', 'joining_date', '2024-04-01', 'exit_date', (m + 14)::text, 'source', 't'),
            jsonb_build_object('name', 'T24 Stayer', 'role', 'T24', 'joining_date', '2024-01-01', 'source', 't'),
            jsonb_build_object('employee_id', 'T24-N1', 'name', 'T24 Joiner', 'role', 'T24', 'joining_date', (m + 9)::text, 'source', 't'),
            jsonb_build_object('name', 'T24 Old', 'role', 'T24', 'joining_date', '2023-01-01', 'exit_date', '2025-05-01', 'source', 't'))));
    a := bi.api_attrition(m, '{}');
    select x into lv from jsonb_array_elements(a->'leavers') x where x->>'name' = emp limit 1;
    ok := (dr->>'valid')::int = 0 and (dr->>'invalid')::int = 3 and (dr->>'duplicate_keys_in_file')::int = 1
      and (r1->>'inserted')::int + (r1->>'updated')::int = 4 and (r2->>'updated')::int = 1 and (r2->>'inserted')::int = 0
      and coalesce((c->'totals'->>'verified_active')::int, 0) - coalesce((c0->'totals'->>'verified_active')::int, 0) = 3
      and coalesce((c->'totals'->>'active_with_crux_6m')::int, 0) - coalesce((c0->'totals'->>'active_with_crux_6m')::int, 0) = 1
      and coalesce((c->'totals'->>'never_activated')::int, 0) - coalesce((c0->'totals'->>'never_activated')::int, 0) = 1
      and exists (select 1 from jsonb_array_elements(c->'dormant_verified') x where x->>'branch_code' = oc)
      and exists (select 1 from jsonb_array_elements(c->'never_activated') x where x->>'branch_code' = 'T24-NEVER' and x->>'branch' = 'renamed')
      and (w1->>'inserted')::int + (w1->>'updated')::int = 4
      and (a->'headcount'->>'opening')::int - coalesce((a0->'headcount'->>'opening')::int, 0) = 2
      and (a->'headcount'->>'joined')::int - coalesce((a0->'headcount'->>'joined')::int, 0) = 1
      and (a->'headcount'->>'left')::int - coalesce((a0->'headcount'->>'left')::int, 0) = 1
      and (a->'headcount'->>'closing')::int - coalesce((a0->'headcount'->>'closing')::int, 0) = 2
      and (a0->>'master_rows' <> '0' or (a->'headcount'->>'attrition_rate')::numeric = 0.5)
      and (lv->>'prior_points_per_month')::numeric = exp_ppm;
    raise exception 'rollback_t24';
  exception when others then
    err := sqlerrm;
  end;
  return jsonb_build_object('passed', ok and err = 'rollback_t24' and not exists (select 1 from bi.client_branch_master where branch_code like 'T24%')
           and not exists (select 1 from bi.workforce_master where role = 'T24'),
    'recent_branch', rc, 'old_branch', oc, 'dry_run', dr - 'errors', 'dry_run_errors', dr->'errors', 'import', r1 - 'errors', 'reimport', r2 - 'errors',
    'coverage', c->'totals', 'attrition_month', m, 'headcount', a->'headcount', 'leaver_prior_ppm', lv->'prior_points_per_month', 'expected_prior_ppm', exp_ppm,
    'error', nullif(err, 'rollback_t24'));
end $fn$;
