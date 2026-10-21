-- Applied to Supabase project via MCP on 20261021072632
create or replace function bi.ask_h_force1(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare F1 jsonb; R jsonb; t jsonb; acts jsonb := '[]'; ans text; rr record; i int := 0; tot_t numeric;
begin
  F1 := public.bi_call('force1', jsonb_build_object('month', m, 'filters', f)); t := F1->'totals';
  R := public.bi_call('force1_recon', jsonb_build_object('month', m, 'filters', f));
  tot_t := (t->>'tracker_cases')::numeric;
  if coalesce(tot_t, 0) = 0 then
    return jsonb_build_object('answer', format('Force1 case utilisation is not available for this selection in %s: no location group in it sent a Force1 Case Wise file.', to_char(m, 'Mon YYYY')), 'confidence', 'low',
      'next', jsonb_build_array('Which location groups send Force1 files?', 'What are the five most important issues?'));
  end if;
  ans := format('Force1 handled %s validated cases of %s business cases (%s) in location groups that send Force1 files%s. %s Field visits submitted by field executives: %s.',
    bi.fmt_n((t->>'matched_cases')::numeric), bi.fmt_n(tot_t), bi.fmt_p((t->>'case_utilisation')::numeric),
    case when R->>'period_note' is not null then format(' (both sides to %s, the last date with Force1 case data)', to_char((R->>'tracker_as_of')::date, 'DD-Mon')) else '' end,
    case when coalesce((t->>'excess_cases')::numeric, 0) > 0 then format('%s more Force1 cases than the tracker shows sit in %s rows under reconciliation and are not counted.',
           bi.fmt_n((t->>'excess_cases')::numeric), t->>'rows_under_reconciliation') else 'No row exceeds the tracker.' end,
    coalesce(bi.fmt_p((t->>'field_utilisation')::numeric), 'not available'));
  for rr in select u from jsonb_array_elements(F1->'by_unit') u where (u->>'tracker_cases')::numeric >= 200 and (u->>'case_utilisation')::numeric < 0.6
           order by (u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0) desc limit 3 loop
    i := i + 1;
    acts := acts || bi.ask_act(case when i = 1 then 'High' else 'Medium' end, format('Move more of %s''s work into Force1', rr.u->>'recon_unit'),
      format('%s of %s business cases were found in Force1 (%s)', bi.fmt_n((rr.u->>'matched_cases')::numeric), bi.fmt_n((rr.u->>'tracker_cases')::numeric), bi.fmt_p((rr.u->>'case_utilisation')::numeric)),
      'Operations head', format('Each 10 points of utilisation here moves about %s cases into Force1 (+%s points overall)',
        bi.fmt_n(round((rr.u->>'tracker_cases')::numeric * 0.1)), to_char(round(100 * (rr.u->>'tracker_cases')::numeric * 0.1 / tot_t, 1), 'FM990.0')));
  end loop;
  for rr in select x from jsonb_array_elements(R->'rows') x where x->>'status' in ('over', 'no_business_row') order by (x->>'excess_cases')::numeric desc nulls last limit 2 loop
    acts := acts || bi.ask_act('Medium', format('Reconcile %s / %s: Force1 shows more cases than the tracker', rr.x->>'recon_unit', rr.x->>'client_family'),
      format('%s Force1 cases vs %s in the tracker (%s above)', bi.fmt_n((rr.x->>'force1_cases')::numeric), bi.fmt_n((rr.x->>'tracker_cases')::numeric), bi.fmt_n((rr.x->>'excess_cases')::numeric)),
      'Force1 / MIS team', 'Corrects the business count or the branch-to-location mapping');
  end loop;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Location group', 'Business cases', 'Validated Force1', 'Utilisation', 'Above tracker', 'Field visits by field executives'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(u->>'recon_unit', bi.fmt_n((u->>'tracker_cases')::numeric), bi.fmt_n((u->>'matched_cases')::numeric), bi.fmt_p((u->>'case_utilisation')::numeric),
                 case when coalesce((u->>'excess_cases')::numeric, 0) > 0 then bi.fmt_n((u->>'excess_cases')::numeric) else '–' end, bi.fmt_p((u->>'field_utilisation')::numeric))), '[]')
               from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 15) z)),
    'drivers', jsonb_build_array(format('%s Force1 cases were placed at the location of their bank branch rather than the team that processed them.', bi.fmt_n((R->>'force1_moved_to_branch_location')::numeric)),
                                 format('%s business cases are in locations not yet on Force1 reports (not in the denominator).', bi.fmt_n((R->>'not_covered_tracker_cases')::numeric))),
    'risks', case when coalesce((t->>'excess_cases')::numeric, 0) > 0 then jsonb_build_array(format('%s rows under reconciliation (%s cases above the tracker).', t->>'rows_under_reconciliation', bi.fmt_n((t->>'excess_cases')::numeric))) else '[]'::jsonb end,
    'opportunities', (select coalesce(jsonb_agg(format('%s: %s business cases not yet in Force1', u->>'recon_unit', bi.fmt_n((u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0)))), '[]')
                      from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0) desc limit 3) z),
    'actions', acts,
    'chart', jsonb_build_object('type', 'stacked', 'title', 'Business cases: validated in Force1 vs not in Force1', 'unit', 'cases',
       'labels', (select jsonb_agg(u->>'recon_unit') from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 12) z),
       'series', jsonb_build_array(
          jsonb_build_object('name', 'Validated in Force1', 'values', (select jsonb_agg(coalesce((u->>'matched_cases')::numeric, 0)) from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 12) z)),
          jsonb_build_object('name', 'Not in Force1', 'values', (select jsonb_agg((u->>'tracker_cases')::numeric - coalesce((u->>'matched_cases')::numeric, 0)) from (select u from jsonb_array_elements(F1->'by_unit') u where u->>'tracker_cases' is not null order by (u->>'tracker_cases')::numeric desc limit 12) z)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Force1 for this selection', 'f', f, 'focus', 'force1')),
    'next', jsonb_build_array('Why is Force1 above the tracker for some locations?', 'Where is TAT increasing?', 'Which locations contribute most to the shortfall?'),
    'method', F1->'definitions'->>'case_utilisation', 'sources', jsonb_build_array('Force1 Case Wise + Point Wise', 'Zonal Tracker', 'Client branch master (branch → location)'),
    'confidence', 'high', 'limitations', coalesce(R->>'period_note', '') || ' Locations without a Force1 location group are not in the denominator.',
    'numbers', jsonb_build_array(jsonb_build_object('metric', 'Validated Force1 cases', 'value', t->'matched_cases'), jsonb_build_object('metric', 'Business cases (covered)', 'value', t->'tracker_cases')));
end $function$;

create or replace function bi.ask_h_forecast(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare o jsonb; fo jsonb; rem int; req numeric; cur numeric; ans text; acts jsonb := '[]'; dl jsonb;
begin
  o := public.bi_call('overview', jsonb_build_object('month', m, 'filters', f)); fo := o->'forecast';
  if fo is null or not coalesce((fo->>'available')::boolean, false) then return jsonb_build_object('answer', 'A month-end projection is not available for this selection.', 'confidence', 'low'); end if;
  rem := greatest((fo->>'workdays_in_month')::int - (fo->>'workdays_elapsed')::int, 0);
  cur := round((fo->>'mtd')::numeric / nullif((fo->>'workdays_elapsed')::numeric, 0));
  req := case when rem > 0 then ceil(((fo->>'target')::numeric - (fo->>'mtd')::numeric) / rem) end;
  ans := format('%s month end is projected at %s cases (%s of the %s target; likely range %s–%s), from %s month to date after %s of %s working days. %s',
    to_char(m, 'Mon YYYY'), bi.fmt_n(coalesce((fo->>'curve_projection')::numeric, (fo->>'run_rate_projection')::numeric)),
    bi.fmt_p(coalesce((fo->>'curve_achievement')::numeric, (fo->>'run_rate_achievement')::numeric)), bi.fmt_n((fo->>'target')::numeric),
    bi.fmt_n((fo->'curve_range'->>0)::numeric), bi.fmt_n((fo->'curve_range'->>1)::numeric), bi.fmt_n((fo->>'mtd')::numeric), fo->>'workdays_elapsed', fo->>'workdays_in_month',
    case when rem = 0 then 'The month is complete.'
         when (fo->'curve_range'->>1)::numeric < (fo->>'target')::numeric then format('Reaching target needs %s cases per working day for the remaining %s working days, against %s per day so far — not reachable at the current pace.', bi.fmt_n(req), rem, bi.fmt_n(cur))
         else format('Reaching target needs %s cases per working day for the remaining %s working days (%s per day so far).', bi.fmt_n(req), rem, bi.fmt_n(cur)) end);
  if rem > 0 and req > cur then
    acts := acts || bi.ask_act('High', format('Agree a daily plan of %s cases per working day across zones', bi.fmt_n(req)),
      format('Current pace %s per day; %s cases still needed in %s working days', bi.fmt_n(cur), bi.fmt_n((fo->>'target')::numeric - (fo->>'mtd')::numeric), rem),
      'Zone heads', format('Closes the gap of about %s cases to target', bi.fmt_n((fo->>'target')::numeric - coalesce((fo->>'curve_projection')::numeric, (fo->>'run_rate_projection')::numeric))));
  end if;
  dl := public.bi_call('daily', jsonb_build_object('month', m, 'filters', f));
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Measure', 'Value'), 'rows', jsonb_build_array(
       jsonb_build_array('Month to date', bi.fmt_n((fo->>'mtd')::numeric)), jsonb_build_array('Target', bi.fmt_n((fo->>'target')::numeric)),
       jsonb_build_array('Projection (historical curve)', bi.fmt_n((fo->>'curve_projection')::numeric)),
       jsonb_build_array('Range', bi.fmt_n((fo->'curve_range'->>0)::numeric) || '–' || bi.fmt_n((fo->'curve_range'->>1)::numeric)),
       jsonb_build_array('Projection (run-rate)', bi.fmt_n((fo->>'run_rate_projection')::numeric)),
       jsonb_build_array('Working days elapsed / in month', (fo->>'workdays_elapsed') || ' / ' || (fo->>'workdays_in_month')),
       jsonb_build_array('Needed per remaining working day', bi.fmt_n(req)), jsonb_build_array('Pace so far per working day', bi.fmt_n(cur)))),
    'drivers', '[]'::jsonb, 'risks', case when (fo->'curve_range'->>1)::numeric < (fo->>'target')::numeric then jsonb_build_array('Even the top of the projected range is below target.') else '[]'::jsonb end,
    'opportunities', '[]'::jsonb, 'actions', acts,
    'chart', jsonb_build_object('type', 'line', 'title', 'Month to date vs target pace', 'unit', 'cases',
       'labels', (select jsonb_agg(to_char((d->>'date')::date, 'DD-Mon') order by d->>'date') from jsonb_array_elements(dl) d),
       'series', jsonb_build_array(
          jsonb_build_object('name', 'Cases month to date', 'values', (select jsonb_agg((d->>'mtd')::numeric order by d->>'date') from jsonb_array_elements(dl) d)),
          jsonb_build_object('name', 'Target pace', 'values', (select jsonb_agg(round((fo->>'target')::numeric * bi.workdays(m, (d->>'date')::date) / nullif((fo->>'workdays_in_month')::numeric, 0)) order by d->>'date') from jsonb_array_elements(dl) d)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open the business breakdown', 'f', f)),
    'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'What are the five most important issues?'),
    'method', fo->>'method_note', 'sources', jsonb_build_array('Zonal Tracker daily snapshots (bi.api_forecast)'), 'confidence', 'medium',
    'limitations', 'A projection, not a guarantee. Working days are Monday to Saturday; holidays are not excluded.');
end $function$;

create or replace function bi.ask_h_health(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare items jsonb := '[]'; R jsonb; mt jsonb; ctl record; dq jsonb; ans text; acts jsonb := '[]'; oc record; back text;
begin
  R := public.bi_call('force1_recon', jsonb_build_object('month', m, 'filters', f));
  mt := bi.api_meta()->'freshness';
  select * into oc from bi.force_open_cut();
  items := items || jsonb_build_object('severity', case when oc.case_cut < oc.latest_snap then 'Medium' else 'Low' end, 'issue', 'Source dates',
    'detail', format('Tracker to %s; Force1 cases to %s; Force1 points to %s.', to_char(oc.latest_snap, 'DD-Mon'), to_char(oc.case_cut, 'DD-Mon'),
              to_char(((mt->>'point_latest_created_ist')::timestamp)::date, 'DD-Mon')));
  for ctl in select s.snapshot_date, s.pan_india_mtd, (select sum(mtd_cases) from bi.v_zt_leaf l where l.snapshot_date = s.snapshot_date) leaf
             from bi.zt_snapshot s where s.report_month in (m, (m - interval '1 month')::date) order by 1 desc loop
    if abs(coalesce(ctl.leaf, 0) - coalesce(ctl.pan_india_mtd, 0)) > 0.5 then
      items := items || jsonb_build_object('severity', 'High', 'issue', 'Tracker control total mismatch',
        'detail', format('Tracker of %s: location rows add up to %s but the sheet''s Pan India row says %s.', to_char(ctl.snapshot_date, 'DD-Mon'), bi.fmt_n(ctl.leaf), bi.fmt_n(ctl.pan_india_mtd)));
    end if;
  end loop;
  if coalesce((R->>'rows_under_reconciliation')::int, 0) > 0 then
    items := items || jsonb_build_object('severity', 'High', 'issue', 'Force1 above the tracker',
      'detail', format('%s location-group × client rows: %s Force1 cases more than the tracker (largest: %s).', R->>'rows_under_reconciliation', bi.fmt_n((R->>'excess_cases')::numeric),
        (select string_agg(format('%s %s +%s', x->>'recon_unit', x->>'client_family', bi.fmt_n((x->>'excess_cases')::numeric)), '; ') from (select x from jsonb_array_elements(R->'rows') x where x->>'status' in ('over', 'no_business_row') order by (x->>'excess_cases')::numeric desc limit 3) z)));
    acts := acts || bi.ask_act('High', 'Reconcile the Force1 rows that exceed the tracker', format('%s cases above the business count', bi.fmt_n((R->>'excess_cases')::numeric)), 'Force1 / MIS team', 'Correct utilisation and business counts');
  end if;
  if coalesce((R->>'not_covered_tracker_cases')::numeric, 0) > 0 then
    items := items || jsonb_build_object('severity', 'Medium', 'issue', 'Locations without Force1 case files',
      'detail', format('%s business cases are in location groups that sent no Case Wise file for %s.', bi.fmt_n((R->>'not_covered_tracker_cases')::numeric), to_char(m, 'Mon YYYY')));
  end if;
  select string_agg(format('%s %s', x->>'key', bi.fmt_p((x->>'case_back_entered')::numeric / nullif((x->>'case_n')::numeric, 0))), '; ') into back
    from jsonb_array_elements(bi.ask_tat_stats(array[m]::date[], f, 'unit')) x
   where x->>'key' <> '~total' and (x->>'case_n')::int >= 30 and (x->>'case_back_entered')::numeric / nullif((x->>'case_n')::numeric, 0) > 0.5;
  if back is not null then
    items := items || jsonb_build_object('severity', 'Medium', 'issue', 'Case TAT not measurable', 'detail', 'More than half the cases closed within 15 minutes of receipt (entered after the work): ' || back || '.');
    acts := acts || bi.ask_act('Medium', 'Record cases in Force1 when received', 'Back-entered cases in: ' || back, 'Location manager', 'TAT becomes measurable');
  end if;
  select jsonb_agg(jsonb_build_object('rule', rule, 'severity', severity, 'n', n) order by n desc) into dq
    from (select rule, severity, count(*) n from bi.dq_exception where coalesce(status, 'open') = 'open' and severity in ('error', 'warning') group by 1, 2 order by 3 desc limit 5) x;
  if dq is not null then
    items := items || jsonb_build_object('severity', 'Low', 'issue', 'Open data-quality exceptions', 'detail', (select string_agg(format('%s (%s): %s', d->>'rule', d->>'severity', d->>'n'), '; ') from jsonb_array_elements(dq) d));
  end if;
  ans := format('%s data issues found for %s, highest severity first: %s.', jsonb_array_length(items), to_char(m, 'Mon YYYY'),
           (select string_agg(i->>'issue', '; ' order by case i->>'severity' when 'High' then 1 when 'Medium' then 2 else 3 end) from jsonb_array_elements(items) i));
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Severity', 'Issue', 'Detail'),
      'rows', (select jsonb_agg(jsonb_build_array(i->>'severity', i->>'issue', i->>'detail') order by case i->>'severity' when 'High' then 1 when 'Medium' then 2 else 3 end) from jsonb_array_elements(items) i)),
    'drivers', '[]'::jsonb, 'risks', '[]'::jsonb, 'opportunities', '[]'::jsonb, 'actions', acts,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Data Health', 'section', 'quality')),
    'next', jsonb_build_array('Why is Force1 above the tracker for some locations?', 'What are the five most important issues?'),
    'method', 'Checks run on the database: tracker control totals, Force1 reconciliation, source dates, back-entered cases and open data-quality exceptions.',
    'sources', jsonb_build_array('bi.zt_snapshot', 'bi.api_force1_recon', 'bi.dq_exception', 'Force1 Case Wise'), 'confidence', 'high');
end $function$;

create or replace function bi.ask_h_branches(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare a jsonb; ans text; acts jsonb := '[]'; r record; i int := 0;
begin
  a := public.bi_call('branches', jsonb_build_object('filters', f));
  ans := format('Branches seen in Force1 cases: %s — growing %s, stable %s, losing traction %s, dormant %s, reactivated %s, new %s.',
    bi.fmt_n((select sum(v::numeric) from jsonb_each_text(a->'summary') t(k, v))), coalesce(a->'summary'->>'growing', '0'), coalesce(a->'summary'->>'stable', '0'),
    coalesce(a->'summary'->>'losing_traction', '0'), coalesce(a->'summary'->>'dormant', '0'), coalesce(a->'summary'->>'reactivated', '0'), coalesce(a->'summary'->>'new', '0'));
  for r in select e from jsonb_array_elements(a->'priority') e limit 3 loop
    i := i + 1;
    acts := acts || bi.ask_act(case when i = 1 then 'High' else 'Medium' end, format('Contact %s %s (%s)', r.e->>'client', r.e->>'branch', replace(r.e->>'status', '_', ' ')),
      format('%s cases in the last 3 months vs %s in the 3 months before', r.e->>'last3m', r.e->>'prior3m'), 'Location manager',
      format('Back to its earlier level: about %s cases a quarter', r.e->>'prior3m'));
  end loop;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Client', 'Branch', 'Status', 'Last 3 months', 'Previous 3 months'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(e->>'client', e->>'branch', replace(e->>'status', '_', ' '), e->>'last3m', e->>'prior3m')), '[]') from (select e from jsonb_array_elements(a->'priority') e limit 10) z)),
    'drivers', '[]'::jsonb, 'risks', jsonb_build_array(format('%s branches are losing traction and %s are dormant.', coalesce(a->'summary'->>'losing_traction', '0'), coalesce(a->'summary'->>'dormant', '0'))),
    'opportunities', '[]'::jsonb, 'actions', acts, 'drill', jsonb_build_array(jsonb_build_object('label', 'Open the branch breakdown', 'f', f, 'level', 'branch')),
    'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'What are the five most important issues?'),
    'method', a->'method'->>'rules', 'sources', jsonb_build_array('Force1 Case Wise (bi.api_branches)'), 'confidence', 'medium',
    'limitations', 'Branch activity is measured from Force1 cases only; branches whose work is not in Force1 look inactive.');
end $function$;

create or replace function bi.ask_h_force1_recon(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare R jsonb; ans text; acts jsonb := '[]'; rr record;
begin
  R := public.bi_call('force1_recon', jsonb_build_object('month', m, 'filters', f));
  ans := format('Force1 utilisation is never shown above 100 %%: a Force1 case counts at the location of its bank branch, and per location group × client only cases up to the tracker''s business count are validated. For %s, %s rows have more Force1 cases than the tracker (%s cases above it), so they are marked "under reconciliation". Largest: %s. Typical causes: the tracker undercounts the location, or the branch is mapped to the wrong location.',
    to_char(m, 'Mon YYYY'), coalesce(R->>'rows_under_reconciliation', '0'), bi.fmt_n((R->>'excess_cases')::numeric),
    coalesce((select string_agg(format('%s %s: %s Force1 vs %s tracker', x->>'recon_unit', x->>'client_family', bi.fmt_n((x->>'force1_cases')::numeric), bi.fmt_n((x->>'tracker_cases')::numeric)), '; ')
              from (select x from jsonb_array_elements(R->'rows') x where x->>'status' in ('over', 'no_business_row') order by (x->>'excess_cases')::numeric desc limit 3) z), 'none'));
  for rr in select x from jsonb_array_elements(R->'rows') x where x->>'status' in ('over', 'no_business_row') order by (x->>'excess_cases')::numeric desc limit 3 loop
    acts := acts || bi.ask_act('High', format('Check the %s business count in the tracker for %s and the branch mapping of its Force1 cases', rr.x->>'client_family', rr.x->>'recon_unit'),
      format('%s Force1 cases vs %s in the tracker', bi.fmt_n((rr.x->>'force1_cases')::numeric), bi.fmt_n((rr.x->>'tracker_cases')::numeric)), 'Force1 / MIS team',
      format('Resolves %s cases of reconciliation difference', bi.fmt_n((rr.x->>'excess_cases')::numeric)));
  end loop;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Location group', 'Client', 'Tracker cases', 'Force1 cases', 'Above tracker', 'Processed here', 'Placed here from other teams'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(x->>'recon_unit', x->>'client_family', bi.fmt_n((x->>'tracker_cases')::numeric), bi.fmt_n((x->>'force1_cases')::numeric),
                 bi.fmt_n((x->>'excess_cases')::numeric), bi.fmt_n((x->>'processed_here')::numeric), bi.fmt_n((x->>'attributed_in')::numeric))), '[]')
               from (select x from jsonb_array_elements(R->'rows') x where x->>'status' in ('over', 'no_business_row') order by (x->>'excess_cases')::numeric desc limit 12) z)),
    'drivers', jsonb_build_array(format('Totals: %s Force1 cases = %s validated + %s above the tracker + %s outside Force1 location groups + %s in groups without a case file.',
       bi.fmt_n((R->>'force1_cases_total')::numeric), bi.fmt_n((R->>'matched_cases')::numeric), bi.fmt_n((R->>'excess_cases')::numeric), bi.fmt_n((R->>'force1_outside_scope')::numeric),
       bi.fmt_n((R->>'force1_to_groups_without_case_file')::numeric))),
    'risks', '[]'::jsonb, 'opportunities', '[]'::jsonb, 'actions', acts,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Force1 reconciliation', 'section', 'force')),
    'next', jsonb_build_array('What is Force1 utilisation by location group?', 'What data issues need attention?'),
    'method', R->'definitions'->>'excess_cases', 'sources', jsonb_build_array('bi.api_force1_recon'), 'confidence', 'high', 'limitations', R->>'period_note');
end $function$;
