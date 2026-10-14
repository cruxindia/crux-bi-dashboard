-- Applied to Supabase project via MCP on 20261014071128
create or replace function bi.test_tracker_sheet() returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $$
declare s date := (select max(snapshot_date) from bi.zt_snapshot); j jsonb; pan numeric; leafsum numeric; mism int; nrows int; daily numeric; apid numeric;
begin
  j := bi.api_tracker_sheet(s, '{}', null, 0);
  select (x->>'mtd')::numeric, (x->>'d')::numeric into pan, daily from jsonb_array_elements(j->'rows') x where x->>'t'='summary' and lower(x->>'loc')='pan india';
  select sum(mtd_cases) into leafsum from bi.zt_row where snapshot_date=s and row_type='leaf';
  select count(*) into mism from jsonb_array_elements(j->'rows') x
    where x->>'t' in ('zone_total','location_total','zone_client_rollup','summary','stakeholder_summary') and x ? 'smtd' and abs(coalesce((x->>'smtd')::numeric,0)-coalesce((x->>'mtd')::numeric,0)) > 0.5;
  select count(*) into nrows from jsonb_array_elements(j->'rows') x where x->>'t'='leaf';
  select sum(change_cases) into apid from bi.v_zt_daily where snapshot_date=s;
  return jsonb_build_object('passed', pan = leafsum and mism = 0 and nrows = (select count(*) from bi.zt_row where snapshot_date=s and row_type='leaf') and daily = apid,
    'snapshot', s, 'pan_india_mtd', pan, 'leaf_sum', leafsum, 'block_total_mismatches', mism, 'leaf_rows', nrows, 'daily', daily, 'daily_view', apid);
end $$;

create or replace function bi.test_compare() returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $$
declare s date := (select max(snapshot_date) from bi.zt_snapshot); pm date; j jsonb; a numeric; b numeric; ea numeric; eb numeric; sm numeric;
begin
  pm := (date_trunc('month', s) - interval '1 month')::date;
  j := bi.api_compare(jsonb_build_object('a',jsonb_build_object('kind','snapshot','date',s),'b',jsonb_build_object('kind','month','date',pm),'group','location'), '{}');
  a := (j->'totals'->>'a_cases')::numeric; b := (j->'totals'->>'b_cases')::numeric;
  select sum(mtd_cases) into ea from bi.zt_row where snapshot_date=s and row_type='leaf';
  select sum(cases) into eb from bi.v_month_business where month=pm;
  select sum((x->>'d_cases')::numeric) into sm from jsonb_array_elements(j->'rows') x;
  return jsonb_build_object('passed', a = ea and b = eb and sm = a - b and jsonb_array_length(j->'warnings') >= 1,
    'a_cases', a, 'expected_a', ea, 'b_cases', b, 'expected_b', eb, 'sum_of_row_changes', sm, 'warnings', j->'warnings');
end $$;

do $do$
declare d text := pg_get_functiondef('bi.run_acceptance_tests'::regproc);
begin
  if position('T21' in d) = 0 then
    d := replace(d, E'detail:=j; return next;\nend $function$',
      E'detail:=j; return next;\n\n  -- T21 tracker replica: Pan India = leaf sum, every block/region/stakeholder total = source sheet, daily = MTD difference\n  j := bi.test_tracker_sheet();\n  test:=''T21 tracker view totals reconcile to the Zonal Tracker''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;\n\n  -- T22 compare: totals equal source, row changes add up, partial-vs-full warning shown\n  j := bi.test_compare();\n  test:=''T22 period comparison reconciles and labels non-like-for-like''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;\nend $function$');
    if position('T21' in d) = 0 then raise exception 'T21 patch failed'; end if;
    execute d;
  end if;
end $do$;
