-- Applied to Supabase project via MCP on 20261022044410
-- bi_092k (22-Oct-2026): tests for revenue-first growth (live data, read-only), recomputed independently from the base tables.
create or replace function bi.test_growth_rev(p_month date default null)
returns table(test text, passed boolean, detail text)
language plpgsql stable security definer set search_path to 'bi', 'public' as $$
declare G jsonb; GC jsonb; B jsonb; bm date; fc date; c jsonb; x numeric; y numeric; z numeric; w numeric; n int; k int; t text;
begin
  G := bi.api_growth_rev(p_month, '{}'::jsonb); B := G->'billing'; bm := (G->>'billing_month')::date; fc := (B->>'first_complete')::date;
  -- R1 MoM actual billed = invoices identified for the month (all locations, each invoice once) — straight from the invoice aggregate
  c := G->'cards'->'mom';
  select sum(basic) filter (where inv_month = bm), sum(basic) filter (where inv_month = (bm - interval '1 month')::date) into x, y from bi.fin_inv_month where inv_n > 0;
  test := 'R1 MoM actual billed = invoice basic of the month vs the month before';
  passed := round(x) = (c->'current'->>'billed')::numeric and round(y) = (c->'previous'->>'billed')::numeric and round(x - y) = (c->>'billed_change')::numeric;
  detail := format('%s: %s vs %s → %s', to_char(bm, 'Mon-YY'), round(x), round(y), round(x - y)); return next;
  -- R2 quarter to date (billing) = sum of the completed billing months of the running quarter vs the same months of the previous quarter
  c := G->'cards'->'qtd';
  if c is not null and (c->>'available')::boolean then
    select sum(basic) filter (where inv_month between bi.fy_qstart(bm) and bm),
           sum(basic) filter (where inv_month between (bi.fy_qstart(bm) - interval '3 months')::date and (bm - interval '3 months')::date) into x, y
    from bi.fin_inv_month where inv_n > 0;
    test := 'R2 QTD (billing) = sum of months, never an average'; passed := round(x) = (c->'current'->>'billed')::numeric and round(y) = (c->'previous'->>'billed')::numeric;
    detail := format('%s vs %s', round(x), round(y)); return next;
  end if;
  -- R3 expected minimum revenue = Zonal Tracker revenue of the same months (non-rollup locations)
  c := G->'cards'->'mom';
  select sum(v.revenue) filter (where v.month = bm), sum(v.revenue) filter (where v.month = (bm - interval '1 month')::date) into x, y
  from bi.v_month_business v join bi.location l on l.id = v.location_id where not coalesce(l.is_rollup, false);
  test := 'R3 expected minimum revenue = Zonal Tracker cases × rate for the same months, shown separately';
  passed := round(x) = (c->'current'->>'expected')::numeric and round(y) = (c->'previous'->>'expected')::numeric;
  detail := format('%s vs %s', round(x), round(y)); return next;
  -- R4 YoY / quarter YoY / YTD unavailable while the comparison months are not completely billed, with a reason and an expected-minimum benchmark
  test := 'R4 YoY unavailable (comparison months not completely billed) with reason and benchmark';
  passed := ((bm - interval '12 months')::date < fc) = not coalesce((G->'cards'->'yoy'->>'available')::boolean, false)
            and (G->'cards'->'yoy'->>'reason' is not null or (G->'cards'->'yoy'->>'available')::boolean) and (G->'cards'->'yoy'->'benchmark'->>'expected_current' is not null or (G->'cards'->'yoy'->>'available')::boolean);
  detail := coalesce(G->'cards'->'yoy'->>'reason', 'available'); return next;
  -- R5 growth beyond organic = actual growth − organic growth = effort now − effort then (every available card)
  n := 0; k := 0;
  for t in select key from jsonb_each(G->'cards') loop
    c := G->'cards'->t;
    if (c->>'available')::boolean and c->'organic'->>'organic_current' is not null then
      n := n + 1;
      if abs((c->'organic'->>'beyond_organic')::numeric - (((c->'organic'->>'actual_current')::numeric - (c->'organic'->>'actual_previous')::numeric) - ((c->'organic'->>'organic_current')::numeric - (c->'organic'->>'organic_previous')::numeric))) <= 1
         and abs((c->'organic'->>'effort_change')::numeric - (c->'organic'->>'beyond_organic')::numeric) <= 1 then k := k + 1; end if;
    end if;
  end loop;
  test := 'R5 growth beyond organic = actual growth − organic growth = change in effort (all available periods)'; passed := n > 0 and k = n; detail := k || ' of ' || n || ' periods'; return next;
  -- R6 organic per period recomputed from the organic revenue model (covered pairs only)
  c := G->'cards'->'mom';
  with o as (select * from bi.fin_org_rev(array[bm, (bm - interval '1 month')::date], '{}'::jsonb, (bm + interval '1 month - 1 day')::date)),
       cov as (select unit_id, fam from o group by 1, 2 having count(org_billed) = 2)
  select sum(o.org_billed) filter (where o.month = bm), sum(o.org_billed) filter (where o.month = (bm - interval '1 month')::date) into x, y
  from o join cov using (unit_id, fam);
  test := 'R6 organic expectation (both periods) = Σ organic cases × billed revenue per case over covered pairs';
  passed := abs(round(x) - (c->'organic'->>'organic_current')::numeric) <= 1 and abs(round(y) - (c->'organic'->>'organic_previous')::numeric) <= 1;
  detail := format('organic %s vs %s', round(x), round(y)); return next;
  -- R7 pair rows reconcile to the card (sum of pair changes = card change; shares add to ±100%)
  select sum((pv->'mom'->>'chg')::numeric), sum((pv->'mom'->>'cur')::numeric), sum((pv->>'share_of_net')::numeric) into x, y, z from jsonb_array_elements(G->'pairs') p(pv);
  test := 'R7 billing unit × client rows add up to the Pan India card'; passed := abs(x - (G->'cards'->'mom'->>'billed_change')::numeric) <= jsonb_array_length(G->'pairs') and abs(y - (G->'cards'->'mom'->'current'->>'billed')::numeric) <= jsonb_array_length(G->'pairs') and abs(abs(z) - 1) < 0.01;
  detail := format('Σ pair change %s vs card %s; Σ pair billed %s vs card %s; Σ shares %s', x, G->'cards'->'mom'->>'billed_change', y, G->'cards'->'mom'->'current'->>'billed', round(z, 4)); return next;
  -- R8 revenue per case uses the same months' cases
  c := G->'cards'->'mom';
  select sum(v.cases) into x from bi.v_month_business v join bi.location l on l.id = v.location_id where not coalesce(l.is_rollup, false) and v.month = bm;
  test := 'R8 billed per case = invoiced revenue ÷ tracker cases of the same month'; passed := (c->'current'->>'cases')::numeric = x and abs((c->'current'->>'billed_per_case')::numeric - round((c->'current'->>'billed')::numeric / x, 1)) <= 0.1;
  detail := format('%s ÷ %s = %s', c->'current'->>'billed', x, c->'current'->>'billed_per_case'); return next;
  -- R9 settlement ratio on one basis (ex-GST settled ÷ ex-GST invoiced), cash kept apart
  select sum(settled_basic), sum(basic), sum(collected) into x, y, z from bi.fin_inv_month where inv_n > 0 and inv_month = bm;
  test := 'R9 realisation = settled ÷ invoiced (both ex-GST); cash allocated reported separately'; passed := (c->'settlement'->>'realisation')::numeric = round(x / y, 4) and (c->'settlement'->>'cash_allocated')::numeric = round(z);
  detail := format('%s ÷ %s = %s; cash %s', round(x), round(y), round(x / y, 4), round(z)); return next;
  -- R10 months still being billed are not compared
  test := 'R10 month after the last completely billed month is listed as in progress, not compared';
  passed := exists (select 1 from jsonb_array_elements(G->'in_progress') e where (e->>'month')::date = (bm + interval '1 month')::date and e->>'status' = 'partial') and (G->'cards'->'mom'->'current'->'label'->>0) = to_char(bm, 'Mon-YY');
  detail := coalesce(G->'in_progress'->0->>'note', '–'); return next;
  -- R11 a filter that splits a billing unit leaves it out of the totals and says so
  GC := bi.api_growth_rev(p_month, '{"location_id": 12}'::jsonb);
  test := 'R11 location filter inside a zone-billed unit: unit excluded from totals and listed';
  passed := jsonb_array_length(GC->'not_in_totals') >= 1 and coalesce((GC->'cards'->'mom'->'current'->>'billed')::numeric, 0) = 0;
  detail := (GC->'not_in_totals')::text; return next;
  -- R12 the organic back-test is reported
  test := 'R12 organic revenue back-test: months, Pan India error, pair WAPE, coverage';
  passed := (G->'organic'->'validation'->>'months')::int >= 3 and (G->'organic'->'validation'->>'pan_mape') is not null;
  detail := format('%s months, mean error %s%%, pair WAPE %s%%, coverage %s%%', G->'organic'->'validation'->>'months', round((G->'organic'->'validation'->>'pan_mape')::numeric * 100, 1),
                   round((G->'organic'->'validation'->>'pair_wape')::numeric * 100, 1), round((G->'organic'->'validation'->>'coverage')::numeric * 100, 1)); return next;
  -- C1 cases view: organic for both periods on every card, identity holds
  GC := bi.api_growth(p_month, '{}'::jsonb); n := 0; k := 0;
  for t in select key from jsonb_each(GC->'cards') loop
    c := GC->'cards'->t;
    if c->'organic'->>'organic_current' is not null and c->'organic'->>'organic_previous' is not null then
      n := n + 1;
      if abs((c->'organic'->>'beyond_organic')::numeric - (((c->'organic'->>'actual_current')::numeric - (c->'organic'->>'actual_previous')::numeric) - ((c->'organic'->>'organic_current')::numeric - (c->'organic'->>'organic_previous')::numeric))) <= 1 then k := k + 1; end if;
    end if;
  end loop;
  test := 'C1 cases: organic for both periods on every comparison; beyond organic identity'; passed := n >= 5 and k = n; detail := k || ' of ' || n || ' cards'; return next;
  -- C2 cases MoM organic recomputed from the organic store (covered pairs)
  c := GC->'cards'->'mom';
  with o as (select o.location_id, coalesce(cl.family, o.client_code) fam, o.month, sum(o.organic) org from bi.organic_store o join bi.location l on l.id = o.location_id and not coalesce(l.is_rollup, false)
             left join bi.client cl on cl.code = o.client_code where o.month in ((GC->>'completed_month')::date, ((GC->>'completed_month')::date - interval '1 month')::date) group by 1, 2, 3),
       a as (select v.location_id, coalesce(cl.family, v.client_code) fam, v.month, sum(v.cases) cs from bi.v_month_business v join bi.location l on l.id = v.location_id and not coalesce(l.is_rollup, false)
             left join bi.client cl on cl.code = v.client_code where v.month in ((GC->>'completed_month')::date, ((GC->>'completed_month')::date - interval '1 month')::date) group by 1, 2, 3),
       cov as (select location_id, fam from o group by 1, 2 having count(*) = 2
               intersect select location_id, fam from a group by 1, 2)
  select sum(o.org) filter (where o.month = (GC->>'completed_month')::date), sum(o.org) filter (where o.month < (GC->>'completed_month')::date) into x, y from o join cov using (location_id, fam);
  test := 'C2 cases: MoM organic for both months = organic store over covered pairs';
  passed := abs(round(x) - (c->'organic'->>'organic_current')::numeric) <= 2 and abs(round(y) - (c->'organic'->>'organic_previous')::numeric) <= 2;
  detail := format('%s vs card %s; %s vs card %s', round(x), c->'organic'->>'organic_current', round(y), c->'organic'->>'organic_previous'); return next;
end $$;
revoke all on function bi.test_growth_rev(date) from public, anon, authenticated;
