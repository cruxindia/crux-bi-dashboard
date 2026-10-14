-- Applied to Supabase project via MCP on 20261014115404
create or replace function bi.test_organic() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare m date := (select max(report_month) from bi.zt_snapshot); s_store numeric; s_fn numeric; expd numeric; j jsonb; jz jsonb; zsum numeric; mtd numeric; ok boolean;
        v1 numeric; v2 numeric; v3 numeric; w0 int; w1 int; w2 int; w3 int; si0 numeric; si1 numeric; si2 numeric; si3 numeric;
begin
  perform bi.organic_refresh_if_stale();
  select sum(organic) into s_store from bi.organic_store where month = m;
  select sum(organic) into s_fn from bi.organic_pairs(m);
  -- independent Pan India recomputation from monthly totals (formula is linear, seasonal effect is Pan India)
  select sum(cases) filter (where month = (m - interval '1 month')::date), sum(cases) filter (where month = (m - interval '2 months')::date), sum(cases) filter (where month = (m - interval '3 months')::date)
    into v1, v2, v3 from bi.v_month_business where location_id is not null;
  w0 := bi.workdays(m, (m + interval '1 month - 1 day')::date); w1 := bi.workdays((m - interval '1 month')::date, (m - interval '1 day')::date);
  w2 := bi.workdays((m - interval '2 months')::date, (m - interval '1 month - 1 day')::date); w3 := bi.workdays((m - interval '3 months')::date, (m - interval '2 months - 1 day')::date);
  si0 := bi.organic_si(m); si1 := bi.organic_si((m - interval '1 month')::date); si2 := bi.organic_si((m - interval '2 months')::date); si3 := bi.organic_si((m - interval '3 months')::date);
  expd := (0.7 * v1 / w1 / si1 + 0.2 * v2 / w2 / si2 + 0.1 * v3 / w3 / si3) * si0 * w0;
  j := bi.api_organic(m, '{}', 'total', 'cases'); jz := bi.api_organic(m, '{}', 'zone', 'cases');
  select sum((x->>'organic_month')::numeric) into zsum from jsonb_array_elements(jz->'rows') x;
  select sum(mtd_cases) into mtd from bi.v_zt_leaf where snapshot_date = (select max(snapshot_date) from bi.zt_snapshot where report_month = m);
  ok := abs(s_store - s_fn) / s_fn < 0.001 and abs(s_store - expd) / expd < 0.001
        and abs((j->'total'->>'organic_month')::numeric - s_store) <= 1 and abs(zsum - s_store) <= jsonb_array_length(jz->'rows')
        and (j->'total'->>'actual')::numeric = mtd
        and (j->'total'->>'effort_to_date')::numeric = (j->'total'->>'actual')::numeric - (j->'total'->>'organic_to_date')::numeric;
  return jsonb_build_object('passed', ok, 'month', m, 'store', round(s_store), 'function', round(s_fn), 'independent', round(expd), 'api_total', j->'total'->'organic_month',
    'zone_rows_sum', round(zsum), 'actual', j->'total'->'actual', 'mtd_check', mtd, 'effort', j->'total'->'effort_to_date');
end $fn$;

create or replace function bi.test_potential() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare m date := (select max(report_month) from bi.zt_snapshot); fc jsonb; pt jsonb; pl jsonb; r jsonb; lsum numeric; ok boolean; req numeric;
begin
  fc := bi.api_forecast(m, '{}'); pt := bi.api_potential(m, '{}', 'cases', 'total'); pl := bi.api_potential(m, '{}', 'cases', 'location');
  r := pt->'rows'->0;
  select sum((x->>'mtd')::numeric) into lsum from jsonb_array_elements(pl->'rows') x;
  req := round(greatest((r->>'target')::numeric - (r->>'mtd')::numeric, 0) / nullif((pt->>'workdays_left')::numeric, 0));
  ok := (fc->>'curve_projection') is not null and abs((r->>'likely')::numeric - (fc->>'curve_projection')::numeric) <= 1
        and abs((r->>'low')::numeric - (fc->'curve_range'->>0)::numeric) <= 1 and abs((r->>'high')::numeric - (fc->'curve_range'->>1)::numeric) <= 1
        and abs(lsum - (r->>'mtd')::numeric) <= jsonb_array_length(pl->'rows') and (r->>'required_per_day')::numeric = req;
  return jsonb_build_object('passed', ok, 'month', m, 'likely', r->'likely', 'forecast', fc->'curve_projection', 'range', jsonb_build_array(r->'low', r->'high'), 'forecast_range', fc->'curve_range',
    'location_sum', lsum, 'mtd', r->'mtd', 'required_per_day', r->'required_per_day', 'expected_required', req);
end $fn$;

do $do$
declare d text := pg_get_functiondef('bi.run_acceptance_tests()'::regprocedure);
begin
  if position('T27' in d) = 0 then
    d := replace(d, 'test:=''T26 penalty sheet: admin entry with reason, totals and cancel''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;',
      'test:=''T26 penalty sheet: admin entry with reason, totals and cancel''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;' || chr(10) || chr(10) ||
      '  j := bi.test_organic();' || chr(10) ||
      '  test:=''T27 organic benchmark = documented formula; totals add up''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;' || chr(10) ||
      '  j := bi.test_potential();' || chr(10) ||
      '  test:=''T28 month-end potential matches the forecast; required per day''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;');
    if position('T27' in d) = 0 then raise exception 'run_acceptance_tests patch failed'; end if;
    execute d;
  end if;
end $do$;
