-- Applied to Supabase project via MCP on 20261022113439
-- bi_094d (22-Oct-2026): growth by EXPECTED REVENUE (business side, Zonal Tracker cases × rate) — p.value = 'revenue'.
-- Same periods as cases (MTD and QTD to the latest daily report, MoM, QoQ, YoY), same pairs and groups; organic is the case model valued
-- at each location × client's tracker rate; small-base threshold ₹25,000. Billing (invoices) stays in api_growth_rev.
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth(date,jsonb,jsonb)'::regprocedure);
  o := array[
$o1$  v_minc numeric := 30; v_minr numeric := 25000; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
$o1$,
$o2$sum(v.cases) cases, sum(v.revenue) revenue,
           count(*) filter (where v.revenue is null and coalesce(v.cases, 0) > 0) rev_missing, sum(v.target_cases) tgt, sum(v.revenue_target) rtgt$o2$,
$o3$sum(z.mtd_cases) cases, sum(z.revenue_actual) revenue,
           sum(z.target_cases) tgt, sum(z.revenue_target) rtgt$o3$,
$o4$  orgx as materialized (
    select ss.pid, ss.side, o.location_id, coalesce(c.family, o.client_code) fam, sum(o.organic * ss.sh) org, count(distinct ss.om) nmo
    from ss join bi.organic_store o on o.month = ss.om join loc on loc.location_id = o.location_id left join bi.client c on c.code = o.client_code
$o4$,
$o5$round(sum(o.organic) filter (where o.month = v_cm)) org_cm, sum(o.organic) filter (where o.month = v_m) org_m
    from bi.organic_store o join loc on loc.location_id = o.location_id left join bi.client c on c.code = o.client_code
$o5$,
$o6$select 'small base (' || coalesce(r.mom_c0, 0) || ' cases last month)' w where$o6$,
$o7$'measure', 'cases', 'month', v_m,$o7$,
$o8$'method', jsonb_build_object(
      'periods',$o8$];
  n := array[
$n1$  v_minc numeric := 30; v_minr numeric := 25000; res jsonb; v_val text := coalesce(p->>'value', 'cases');
begin
  f := coalesce(f, '{}'::jsonb);
  if v_val = 'revenue' then v_minc := 25000; end if;
$n1$,
$n2$sum(case when v_val = 'revenue' then v.revenue else v.cases end) cases, sum(v.revenue) revenue,
           count(*) filter (where v.revenue is null and coalesce(v.cases, 0) > 0) rev_missing, sum(case when v_val = 'revenue' then v.revenue_target else v.target_cases end) tgt, sum(v.revenue_target) rtgt$n2$,
$n3$sum(case when v_val = 'revenue' then z.revenue_actual else z.mtd_cases end) cases, sum(z.revenue_actual) revenue,
           sum(case when v_val = 'revenue' then z.revenue_target else z.target_cases end) tgt, sum(z.revenue_target) rtgt$n3$,
$n4$  rt as materialized (
    select v.month, v.location_id, v.client_code, sum(v.revenue) / nullif(sum(v.cases), 0) rate from bi.v_month_business v
     where v_val = 'revenue' and v.month in (select ss.om from ss union select v_cm union select v_m) group by 1, 2, 3),
  lr as materialized (
    select z.location_id, z.client_code, max(z.rate) rate from bi.v_zt_leaf z where v_val = 'revenue' and z.snapshot_date = v_last group by 1, 2),
  orgx as materialized (
    select ss.pid, ss.side, o.location_id, coalesce(c.family, o.client_code) fam,
           sum(o.organic * ss.sh * case when v_val = 'revenue' then coalesce(rt.rate, lr.rate) else 1 end) org, count(distinct ss.om) nmo
    from ss join bi.organic_store o on o.month = ss.om join loc on loc.location_id = o.location_id left join bi.client c on c.code = o.client_code
      left join rt on rt.month = o.month and rt.location_id = o.location_id and rt.client_code = o.client_code
      left join lr on lr.location_id = o.location_id and lr.client_code = o.client_code
$n4$,
$n5$round(sum(o.organic * case when v_val = 'revenue' then coalesce(rt.rate, lr.rate) else 1 end) filter (where o.month = v_cm)) org_cm,
           sum(o.organic * case when v_val = 'revenue' then coalesce(rt.rate, lr.rate) else 1 end) filter (where o.month = v_m) org_m
    from bi.organic_store o join loc on loc.location_id = o.location_id left join bi.client c on c.code = o.client_code
      left join rt on rt.month = o.month and rt.location_id = o.location_id and rt.client_code = o.client_code
      left join lr on lr.location_id = o.location_id and lr.client_code = o.client_code
$n5$,
$n6$select 'small base (' || case when v_val = 'revenue' then '₹' || round(coalesce(r.mom_c0, 0))::text else coalesce(r.mom_c0, 0)::text || ' cases' end || ' last month)' w where$n6$,
$n7$'measure', case when v_val = 'revenue' then 'expected_revenue' else 'cases' end, 'month', v_m,$n7$,
$n8$'method', jsonb_build_object(
      'measure', case when v_val = 'revenue' then 'Values are EXPECTED REVENUE from the Zonal Tracker (cases × agreed rate) — the business (operations) side, available to the latest daily report. The organic expectation is the case model valued at each location × client''s tracker rate. Invoiced (billed) revenue and collections are the finance side, shown in the Billed revenue view and Revenue & collections.' else 'Values are cases from the Zonal Tracker.' end,
      'periods',$n8$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_growth fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
