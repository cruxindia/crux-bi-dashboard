-- Applied to Supabase project via MCP on 20261022092556
-- bi_093b (22-Oct-2026): api_organic returns the MoM / QoQ / YoY bases behind every organic figure and the new method text
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_organic(date,jsonb,text,text)'::regprocedure);
  o := array[
$o0$  with op as (select o.*, l.recon_unit, l.region, l.label loc_label,$o0$,
$o1$              from bi.organic_get(m) o join bi.location l on l.id = o.location_id left join bi.client c on c.code = o.client_code left join bi.client pc on pc.code = c.summary_under$o1$,
$o2$                sum(v1) v1, sum(v2) v2, sum(v3) v3, sum(organic) org_cases,$o2$,
$o3$  tot as (select sum(actual) actual, sum(org) org, sum(org) * share org_td, sum(v1) v1, sum(v2) v2, sum(v3) v3,$o3$,
$o4$'si2', si2, 'si3', si3, 'rows', n)) from tot),$o4$,
$o5$'si2', si2, 'si3', si3, 'rows', n, 'organic_cases', round(org_cases)))$o5$,
$o6$      'formula', 'Organic = (0.7 × last month + 0.2 × the month before + 0.1 × three months back), each as cases per working day with the usual seasonal effect removed, × this month''s usual seasonal effect × this month''s working days.',$o6$,
$o7$      'why', 'Chosen by testing six methods on Dec-2025 → Sep-2026: this one missed actual monthly business by 6.7% on average at Pan India level (location × client 21.5%). The previous rule — the higher of last-year growth × 3-month average and 3-month running growth × last month — overstated organic business by 25% on average, so it labelled normal months as under-performance.',$o7$];
  n := array[
$n0$  with op as (select o.*, os2.b_mom, os2.b_qoq, os2.b_yoy, os2.q_trend, os2.y_shape, l.recon_unit, l.region, l.label loc_label,$n0$,
$n1$              from bi.organic_get(m) o join bi.location l on l.id = o.location_id left join bi.client c on c.code = o.client_code left join bi.client pc on pc.code = c.summary_under
              left join bi.organic_store os2 on os2.month = m and os2.location_id = o.location_id and os2.client_code = o.client_code$n1$,
$n2$                sum(v1) v1, sum(v2) v2, sum(v3) v3, sum(organic) org_cases,
                sum(b_mom) b_mom, sum(b_qoq) b_qoq, sum(b_yoy) b_yoy, count(b_yoy) n_y, sum(organic) filter (where b_yoy is not null) org_y, max(q_trend) q_trend, max(y_shape) y_shape,$n2$,
$n3$  tot as (select sum(actual) actual, sum(org) org, sum(org) * share org_td, sum(v1) v1, sum(v2) v2, sum(v3) v3,
                 sum(organic) org_cases, sum(b_mom) b_mom, sum(b_qoq) b_qoq, sum(b_yoy) b_yoy, count(b_yoy) n_y, sum(organic) filter (where b_yoy is not null) org_y,
                 max(q_trend) q_trend, max(y_shape) y_shape,$n3$,
$n4$'si2', si2, 'si3', si3, 'rows', n, 'organic_cases', round(org_cases, 1), 'b_mom', round(b_mom, 1), 'b_qoq', round(b_qoq, 1), 'b_yoy', round(b_yoy, 1),
               'rows_with_yoy', n_y, 'organic_with_yoy', round(org_y, 1), 'q_trend', case when n = 1 then q_trend end, 'y_shape', case when n = 1 then y_shape end)) from tot),$n4$,
$n5$'si2', si2, 'si3', si3, 'rows', n, 'organic_cases', round(org_cases, 1), 'b_mom', round(b_mom, 1), 'b_qoq', round(b_qoq, 1), 'b_yoy', round(b_yoy, 1),
               'rows_with_yoy', n_y, 'organic_with_yoy', round(org_y, 1), 'q_trend', case when n = 1 then q_trend end, 'y_shape', case when n = 1 then y_shape end))$n5$,
$n6$      'formula', 'Organic = 50% MoM basis + 40% QoQ basis + 10% YoY basis (5/9 MoM + 4/9 QoQ where the location × client has no usable month last year). MoM basis = last month''s cases per working day with the usual seasonal effect removed × this month''s seasonal effect × working days. QoQ basis = the same for the last three months together × the QoQ trend (last quarter vs the quarter before, limited to 0.5–2×). YoY basis = last three months'' cases per working day × working days × this location × client''s own pattern for this calendar month last year (limited to 0.67–1.5×).',$n6$,
$n7$      'why', 'Weights chosen by back-test on Dec-2025 → Sep-2026, each month predicted from earlier months only: Pan India error 5.8% on average (previous 70/20/10 three-month method 6.7%), location × client 21.3% (21.5%). A larger YoY share was less accurate (20%: 5.8% / 21.5%; 30%: 6.1% / 21.9%), mainly because many locations started or changed since last year; 76% of business has a usable month last year.',$n7$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_organic fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
