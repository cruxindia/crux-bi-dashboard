-- Applied to Supabase project via MCP on 20261021073248
-- bi_089d (21-Oct-2026): Ask Crux v3 fixes from the 24-question evaluation
create or replace function bi.ask_h_force1(m date, f jsonb, q text default '') returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare F1 jsonb; R jsonb; t jsonb; acts jsonb := '[]'; ans text; rr record; i int := 0; tot_t numeric; unit text; nloc int; f2 jsonb := f; tr jsonb; trtxt text; scope_note text := ''; zgrp text;
begin
  if f ? 'location_id' then
    select l.recon_unit, (select count(*) from bi.location l2 where l2.recon_unit = l.recon_unit and not l2.is_rollup), l.zone_group into unit, nloc, zgrp
      from bi.location l where l.id = (f->>'location_id')::int;
    if unit is null then
      return jsonb_build_object('answer', 'This location has no Force1 location group, so Force1 utilisation cannot be measured for it.', 'confidence', 'high',
        'next', jsonb_build_array('What is Force1 utilisation by location group?'));
    end if;
    f2 := (f - 'location_id') || jsonb_build_object('zone_group', zgrp);
  end if;
  F1 := public.bi_call('force1', jsonb_build_object('month', m, 'filters', f2));
  R := public.bi_call('force1_recon', jsonb_build_object('month', m, 'filters', f2));
  if unit is not null then
    select u into t from jsonb_array_elements(F1->'by_unit') u where u->>'recon_unit' = unit;
    scope_note := format(' Force1 is measured per location group: %s (%s location%s).', unit, nloc, case when nloc = 1 then '' else 's' end);
    select coalesce(jsonb_agg(jsonb_build_object('month', mo, 'u', round(mt / nullif(tc, 0), 4)) order by mo), '[]') into tr
      from (select month mo, sum(matched_cases) mt, sum(tracker_cases) filter (where case_data_available) tc from bi.v_force_usage
             where recon_unit = unit and case_data_available and month > (m - interval '6 months')::date and month <= m
               and (f->>'client_family' is null or client_family = f->>'client_family') group by month) z;
  else
    t := F1->'totals';
    select coalesce(jsonb_agg(jsonb_build_object('month', x->>'month', 'u', (x->>'case_utilisation')::numeric) order by x->>'month'), '[]') into tr
      from jsonb_array_elements(F1->'trend') x where (x->>'month')::date > (m - interval '6 months')::date and (x->>'month')::date <= m and x->>'case_utilisation' is not null;
  end if;
  tot_t := (t->>'tracker_cases')::numeric;
  if coalesce(tot_t, 0) = 0 then
    return jsonb_build_object('answer', format('Force1 case utilisation is not available for this selection in %s: no location group in it sent a Force1 Case Wise file.', to_char(m, 'Mon YYYY')), 'confidence', 'low',
      'next', jsonb_build_array('What is Force1 utilisation by location group?', 'What are the five most important issues?'));
  end if;
  select string_agg(to_char((x->>'month')::date, 'Mon') || ' ' || bi.fmt_p((x->>'u')::numeric), ', ' order by x->>'month') into trtxt from jsonb_array_elements(tr) x;
  ans := format('Force1 handled %s validated cases of %s business cases (%s)%s%s. %s Last months: %s.%s',
    bi.fmt_n((t->>'matched_cases')::numeric), bi.fmt_n(tot_t), bi.fmt_p((t->>'case_utilisation')::numeric),
    case when unit is not null then ' in ' || unit else ' in location groups that send Force1 files' end,
    case when R->>'period_note' is not null then format(' (both sides to %s, the last date with Force1 case data)', to_char((R->>'tracker_as_of')::date, 'DD-Mon')) else '' end,
    case when coalesce((t->>'excess_cases')::numeric, 0) > 0 then format('%s more Force1 cases than the tracker shows are under reconciliation and not counted.', bi.fmt_n((t->>'excess_cases')::numeric))
         else 'No row exceeds the tracker.' end,
    coalesce(trtxt, 'no earlier months with Force1 case data'), scope_note);
  if unit is null then
    for rr in select u from jsonb_array_elements(F1->'by_unit') u where (u->>'tracker_cases')::numeric >= 200 and (u->>'case_utilisation')::numeric < 0.6
             order by (u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0) desc limit 3 loop
      i := i + 1;
      acts := acts || bi.ask_act(case when i = 1 then 'High' else 'Medium' end, format('Move more of %s''s work into Force1', rr.u->>'recon_unit'),
        format('%s of %s business cases were found in Force1 (%s)', bi.fmt_n((rr.u->>'matched_cases')::numeric), bi.fmt_n((rr.u->>'tracker_cases')::numeric), bi.fmt_p((rr.u->>'case_utilisation')::numeric)),
        'Operations head', format('Each 10 points of utilisation here moves about %s cases into Force1 (+%s points overall)',
          bi.fmt_n(round((rr.u->>'tracker_cases')::numeric * 0.1)), to_char(round(100 * (rr.u->>'tracker_cases')::numeric * 0.1 / tot_t, 1), 'FM990.0')));
    end loop;
  elsif (t->>'case_utilisation')::numeric < 0.8 then
    acts := acts || bi.ask_act('High', format('Move more of %s''s work into Force1', unit),
      format('%s of %s business cases were found in Force1', bi.fmt_n((t->>'matched_cases')::numeric), bi.fmt_n(tot_t)), 'Operations head',
      format('Each 10 points of utilisation moves about %s cases into Force1', bi.fmt_n(round(tot_t * 0.1))));
  end if;
  for rr in select x from jsonb_array_elements(R->'rows') x where x->>'status' in ('over', 'no_business_row') and (unit is null or x->>'recon_unit' = unit)
           order by (x->>'excess_cases')::numeric desc nulls last limit 2 loop
    acts := acts || bi.ask_act('Medium', format('Reconcile %s / %s: Force1 shows more cases than the tracker', rr.x->>'recon_unit', rr.x->>'client_family'),
      format('%s Force1 cases vs %s in the tracker (%s above)', bi.fmt_n((rr.x->>'force1_cases')::numeric), bi.fmt_n((rr.x->>'tracker_cases')::numeric), bi.fmt_n((rr.x->>'excess_cases')::numeric)),
      'Force1 / MIS team', 'Corrects the business count or the branch-to-location mapping');
  end loop;
  return jsonb_build_object('answer', ans,
    'findings', case when unit is null then
        jsonb_build_object('columns', jsonb_build_array('Location group', 'Business cases', 'Validated Force1', 'Utilisation', 'Above tracker', 'Field visits by field executives'),
          'rows', (select coalesce(jsonb_agg(jsonb_build_array(u->>'recon_unit', bi.fmt_n((u->>'tracker_cases')::numeric), bi.fmt_n((u->>'matched_cases')::numeric), bi.fmt_p((u->>'case_utilisation')::numeric),
                     case when coalesce((u->>'excess_cases')::numeric, 0) > 0 then bi.fmt_n((u->>'excess_cases')::numeric) else '–' end, bi.fmt_p((u->>'field_utilisation')::numeric))), '[]')
                   from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 15) z))
      else jsonb_build_object('columns', jsonb_build_array('Client', 'Business cases', 'Force1 cases', 'Validated', 'Utilisation', 'Status'),
          'rows', (select coalesce(jsonb_agg(jsonb_build_array(x->>'client_family', bi.fmt_n((x->>'tracker_cases')::numeric), bi.fmt_n((x->>'force1_cases')::numeric), bi.fmt_n((x->>'matched_cases')::numeric),
                     bi.fmt_p((x->>'utilisation')::numeric), case x->>'status' when 'ok' then 'Reconciled' when 'not_covered' then 'No Force1 file' else 'Under reconciliation' end)), '[]')
                   from (select x from jsonb_array_elements(R->'rows') x where x->>'recon_unit' = unit order by (x->>'tracker_cases')::numeric desc nulls last limit 15) z)) end,
    'drivers', jsonb_build_array(format('%s Force1 cases were placed at the location of their bank branch rather than the team that processed them.', bi.fmt_n((R->>'force1_moved_to_branch_location')::numeric))),
    'risks', case when coalesce((t->>'excess_cases')::numeric, 0) > 0 then jsonb_build_array(format('%s cases above the tracker are under reconciliation.', bi.fmt_n((t->>'excess_cases')::numeric))) else '[]'::jsonb end,
    'opportunities', case when unit is null then (select coalesce(jsonb_agg(format('%s: %s business cases not yet in Force1', u->>'recon_unit', bi.fmt_n((u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0)))), '[]')
                      from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0) desc limit 3) z)
                      else jsonb_build_array(format('%s business cases not yet in Force1', bi.fmt_n(tot_t - coalesce((t->>'matched_cases')::numeric, 0)))) end,
    'actions', acts,
    'chart', case when q ~ '(improv|trend|over time|month on month|monthly|getting better|worse)' or unit is not null then
        jsonb_build_object('type', 'line', 'title', 'Force1 case utilisation by month', 'unit', '%',
          'labels', (select jsonb_agg(to_char((x->>'month')::date, 'Mon YY') order by x->>'month') from jsonb_array_elements(tr) x),
          'series', jsonb_build_array(jsonb_build_object('name', 'Utilisation %', 'values', (select jsonb_agg(round((x->>'u')::numeric * 100, 1) order by x->>'month') from jsonb_array_elements(tr) x))))
      else jsonb_build_object('type', 'stacked', 'title', 'Business cases: validated in Force1 vs not in Force1', 'unit', 'cases',
          'labels', (select jsonb_agg(u->>'recon_unit') from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 12) z),
          'series', jsonb_build_array(
             jsonb_build_object('name', 'Validated in Force1', 'values', (select jsonb_agg(coalesce((u->>'matched_cases')::numeric, 0)) from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 12) z)),
             jsonb_build_object('name', 'Not in Force1', 'values', (select jsonb_agg((u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0)) from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 12) z)))) end,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Force1 for this selection', 'f', f, 'focus', 'force1')),
    'next', jsonb_build_array('Why is Force1 above the tracker for some locations?', 'Where is TAT increasing?', 'Which locations contribute most to the shortfall?'),
    'method', F1->'definitions'->>'case_utilisation', 'sources', jsonb_build_array('Force1 Case Wise + Point Wise', 'Zonal Tracker', 'Client branch master (branch → location)'),
    'confidence', 'high', 'limitations', coalesce(R->>'period_note', '') || ' Locations without a Force1 location group are not in the denominator.',
    'numbers', jsonb_build_array(jsonb_build_object('metric', 'Validated Force1 cases', 'value', t->'matched_cases'), jsonb_build_object('metric', 'Business cases (covered)', 'value', t->'tracker_cases')));
end $function$;

do $do$
declare d text := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure); r record; n int;
begin
  for r in select * from (values
    (1, $a$    when q ~ '(\mtat\M|turnaround|turn around|slow|delay|time taken|how long|sla|ageing|aging)' then 'tat'
    when q ~ '(who is|which employee|which person|best performer|worst performer|staff|people|attrition|employee)' then 'people'$a$,
        $b$    when q ~ '(who is|which employee|which person|best performer|worst performer|staff|people|attrition|employee|executive named)' then 'people'
    when q ~ '(\mtat\M|turnaround|turn around|slow|delay|time taken|how long|sla|ageing|aging)' then 'tat'$b$),
    (2, $a$when q ~ '(shortfall|short of|gap|behind target|below target|miss(ing|ed)? (the )?target|contribut|underperform|lagging|weakest|worst|behind plan)' then 'shortfall'$a$,
        $b$when q ~ '(shortfall|short of|gap|behind target|below target|miss(ing|ed)? (the )?target|contribut|underperform|lagging|weakest|worst|behind plan|(against|vs|versus) (the )?target|close[ds]? (against|vs|versus|below|above))' then 'shortfall'$b$),
    (3, $a$when 'force1' then bi.ask_h_force1(m, f)$a$, $b$when 'force1' then bi.ask_h_force1(m, f, q)$b$)
  ) v(ord, a, b) order by ord loop
    n := (length(d) - length(replace(d, r.a, ''))) / length(r.a);
    if n <> 1 then raise exception 'bi_ask3 patch %: found % times', r.ord, n; end if;
    d := replace(d, r.a, r.b);
  end loop;
  execute d;
end $do$;

do $do$
declare d text := pg_get_functiondef('bi.warm_drill_cache(integer)'::regprocedure); a text; b text;
begin
  if position('force1_recon' in d) > 0 then return; end if;
  a := $a$  perform public.bi_call('tat_summary', jsonb_build_object('month', m, 'filters', '{}'::jsonb, 'group', 'total')); n := n + 1;$a$;
  b := a || $b$
  perform public.bi_call('overview', jsonb_build_object('month', m, 'filters', '{}'::jsonb)); perform public.bi_call('force1', jsonb_build_object('month', m, 'filters', '{}'::jsonb));
  perform public.bi_call('force1_recon', jsonb_build_object('month', m, 'filters', '{}'::jsonb)); perform public.bi_call('force', jsonb_build_object('month', m, 'filters', '{}'::jsonb));
  perform public.bi_call('force_trend', jsonb_build_object('filters', '{}'::jsonb)); perform public.bi_call('tat_trend', jsonb_build_object('filters', '{}'::jsonb, 'months', 12)); n := n + 6;$b$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'warm anchor'; end if;
  d := replace(d, a, b);
  a := $a$    perform public.bi_call('insights', jsonb_build_object('month', m, 'filters', c.f));$a$;
  b := $b$    perform public.bi_call('overview', jsonb_build_object('month', m, 'filters', c.f)); n := n + 1;
$b$ || a;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'warm anchor 2'; end if;
  execute replace(d, a, b);
end $do$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'ask_crux', 'bi_089d', jsonb_build_object('fixes', jsonb_build_array('force1 single location', 'intent order', 'cache warm-up')));
