-- Applied to Supabase project via MCP on 20261021182357
create or replace function bi.test_growth(p_month date default null)
returns table(test text, passed boolean, detail text)
language plpgsql stable security definer set search_path to 'bi', 'public' as $$
declare G jsonb; m date; cm date; cq date; c jsonb; x numeric; y numeric; z numeric; t record; v_partial boolean;
begin
  m := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date;
  G := bi.api_growth(m, '{}'::jsonb); cm := (G->>'completed_month')::date; cq := (G->>'completed_quarter')::date; v_partial := (G->>'partial')::boolean;
  test := 'F1 change % hidden below the minimum base'; passed := bi.pct_chg(40, 20, 30) is null and bi.pct_chg(40, 0, 30) is null and bi.pct_chg(null, 30, 30) is null; detail := 'pct_chg(40,20,30), (40,0,30), (null,30,30) are null'; return next;
  test := 'F2 change % at or above the base'; passed := bi.pct_chg(45, 30, 30) = 0.5 and bi.pct_chg(29, 30, 30) = -0.0333 and bi.pct_chg(30, 120, 90) = -0.75; detail := '45/30 → +50%, 29/30 → −3.33%, 30/120 → −75%'; return next;
  test := 'F3 financial-year quarters'; passed := bi.fy_qstart('2026-12-15') = '2026-10-01' and bi.fy_qstart('2027-03-31') = '2027-01-01' and bi.fy_qstart('2026-04-30') = '2026-04-01' and bi.fy_qstart('2026-06-01') = '2026-04-01'
      and bi.fy_qlabel('2026-01-01') = 'Q4 FY26 (Jan–Mar 2026)' and bi.fy_qlabel('2026-04-01') = 'Q1 FY27 (Apr–Jun 2026)' and bi.fy_qlabel('2026-10-01') = 'Q3 FY27 (Oct–Dec 2026)';
    detail := 'Apr–Jun = Q1; Jan–Mar = Q4 of the financial year that started the previous April'; return next;
  test := 'F4 completed quarter only when all three months have ended'; passed := cq = case when cm = (bi.fy_qstart(cm) + interval '2 months')::date then bi.fy_qstart(cm) else (bi.fy_qstart(cm) - interval '3 months')::date end and cq + interval '2 months' <= cm;
    detail := 'completed month ' || cm || ', completed quarter starts ' || cq; return next;
  c := G->'cards'->'mom';
  select sum(cases) filter (where month = cm), sum(cases) filter (where month = (cm - interval '1 month')::date) into x, y from bi.v_month_business v join bi.location l on l.id = v.location_id where not coalesce(l.is_rollup, false);
  test := 'L1 month on month = completed month vs the month before'; passed := (c->'current'->>'cases')::numeric = x and (c->'previous'->>'cases')::numeric = y and (c->>'cases_change')::numeric = x - y and (c->>'cases_pct')::numeric = round((x - y) / y, 4);
    detail := format('%s vs %s → %s (%s%%)', x, y, x - y, round((x - y) / y * 100, 2)); return next;
  c := G->'cards'->'qoq';
  select sum(cases) filter (where month between cq and (cq + interval '2 months')::date), sum(cases) filter (where month between (cq - interval '3 months')::date and (cq - interval '1 month')::date) into x, y
    from bi.v_month_business v join bi.location l on l.id = v.location_id where not coalesce(l.is_rollup, false);
  test := 'L2 quarter on quarter = sum of three months vs the previous three (not an average of monthly rates)'; passed := (c->'current'->>'cases')::numeric = x and (c->'previous'->>'cases')::numeric = y and (c->>'cases_pct')::numeric = round((x - y) / y, 4);
    detail := format('%s vs %s → %s%%', x, y, round((x - y) / y * 100, 2)); return next;
  c := G->'cards'->'yoy';
  select sum(cases) filter (where month = cm), sum(cases) filter (where month = (cm - interval '12 months')::date) into x, y from bi.v_month_business v join bi.location l on l.id = v.location_id where not coalesce(l.is_rollup, false);
  test := 'L3 year on year = completed month vs the same month last year'; passed := (c->'current'->>'cases')::numeric = x and (c->'previous'->>'cases')::numeric = y;
    detail := format('%s vs %s', x, y); return next;
  if v_partial then
    c := G->'cards'->'mtd';
    select sum(z.mtd_cases) into x from bi.v_zt_leaf z join bi.location l on l.id = z.location_id where not coalesce(l.is_rollup, false) and z.snapshot_date = (G->>'as_of')::date;
    select sum(z.mtd_cases) into y from bi.v_zt_leaf z join bi.location l on l.id = z.location_id where not coalesce(l.is_rollup, false) and z.snapshot_date = (G->'comparison_snapshots'->>'previous_month')::date;
    test := 'L4 month to date compared on the same working day, never with a full month'; passed := (c->'current'->>'cases')::numeric = x and (c->'previous'->>'cases')::numeric = y
        and (G->'comparison_snapshots'->>'previous_month_workday')::int <= (G->>'workdays_elapsed')::int and c->'previous'->'label'->>0 like 'to %';
      detail := format('%s to %s (working day %s) vs %s to %s (working day %s)', x, G->>'as_of', G->>'workdays_elapsed', y, G->'comparison_snapshots'->>'previous_month', G->'comparison_snapshots'->>'previous_month_workday'); return next;
  end if;
  select sum((pv->'mom'->>'chg')::numeric), sum((pv->'mom'->>'share_of_net')::numeric) into x, y from jsonb_array_elements(G->'pairs') p(pv);
  test := 'L5 pair changes add up to the net change; shares of net add up to ±100%'; passed := x = (G->'cards'->'mom'->>'cases_change')::numeric and abs(abs(y) - 1) < 0.01;
    detail := format('sum of pair changes %s, card %s, sum of shares %s', x, G->'cards'->'mom'->>'cases_change', round(y, 4)); return next;
  for t in select * from jsonb_to_record(G->'cards'->'mom') as r(like_for_like jsonb, structure jsonb, "current" jsonb, previous jsonb) loop
    test := 'L6 like for like + new pairs = reported (current); like for like + lost pairs = reported (earlier)';
    passed := (t.like_for_like->>'cases_current')::numeric + (t.structure->>'new_pair_cases')::numeric = (t."current"->>'cases')::numeric
          and (t.like_for_like->>'cases_previous')::numeric + (t.structure->>'lost_pair_cases')::numeric = (t.previous->>'cases')::numeric;
    detail := format('%s + %s = %s; %s + %s = %s', t.like_for_like->>'cases_current', t.structure->>'new_pair_cases', t."current"->>'cases', t.like_for_like->>'cases_previous', t.structure->>'lost_pair_cases', t.previous->>'cases'); return next;
  end loop;
  select count(*) into x from jsonb_array_elements(G->'pairs') p(pv) where coalesce((pv->'mom'->>'prev')::numeric, 0) between 1 and 29 and pv->'mom'->>'pct' is not null;
  select count(*) into y from jsonb_array_elements(G->'pairs') p(pv) where coalesce((pv->'mom'->>'prev')::numeric, 0) between 1 and 29;
  test := 'L7 no change % for a pair whose earlier month had under 30 cases'; passed := x = 0; detail := format('%s small-base pairs, %s with a %% shown', y, x); return next;
  select count(*) into x from jsonb_array_elements(G->'pairs') p(pv)
    where (pv->'organic'->>'expected') is not null and abs((pv->'organic'->>'expected')::numeric - round((select sum(o.organic) from bi.organic_store o left join bi.client cl on cl.code = o.client_code
            where o.month = cm and o.location_id = (pv->>'location_id')::int and coalesce(cl.family, o.client_code) = pv->>'client'))) > 0.5;
  select count(*) into y from jsonb_array_elements(G->'pairs') p(pv) where (pv->'organic'->>'expected') is not null and (pv->'organic'->>'effort')::numeric <> coalesce((pv->>'cases')::numeric, 0) - (pv->'organic'->>'expected')::numeric;
  test := 'L8 organic expectation per pair = the stored organic model; effort = actual − organic'; passed := x = 0 and y <= (select count(*) from jsonb_array_elements(G->'pairs')) * 0.02;
    detail := format('%s pairs differ from the model, %s rounding differences in effort', x, y); return next;
  test := 'L9 organic model accuracy is measured and reported'; passed := (G->'organic'->'validation'->>'months')::int >= 6 and (G->'organic'->'validation'->>'pan_mape')::numeric < 0.15;
    detail := format('%s months, Pan India mean error %s%%, pair WAPE %s%%', G->'organic'->'validation'->>'months', round((G->'organic'->'validation'->>'pan_mape')::numeric * 100, 1), round((G->'organic'->'validation'->>'pair_wape')::numeric * 100, 1)); return next;
  select pv into c from jsonb_array_elements(G->'pairs') p(pv) order by (pv->>'cases')::numeric desc nulls last limit 1;
  select sum(v.cases) filter (where v.month = cm), sum(v.cases) filter (where v.month = (cm - interval '1 month')::date), sum(v.cases) filter (where v.month between cq and (cq + interval '2 months')::date)
    into x, y, z from bi.v_month_business v left join bi.client cl on cl.code = v.client_code where v.location_id = (c->>'location_id')::int and coalesce(cl.family, v.client_code) = c->>'client';
  test := 'L10 sample pair recalculated: ' || (c->>'client_label') || ' · ' || (c->>'location'); passed := (c->>'cases')::numeric = x and (c->'mom'->>'prev')::numeric = y and (c->'qoq'->>'cur')::numeric = z;
    detail := format('%s: %s vs %s; quarter %s', to_char(cm, 'Mon-YY'), x, y, z); return next;
end $$;
