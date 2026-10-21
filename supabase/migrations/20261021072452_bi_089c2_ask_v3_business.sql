-- Applied to Supabase project via MCP on 20261021072452
create or replace function bi.ask_h_overview(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare o jsonb; fo jsonb; lf jsonb; dl jsonb; fr jsonb; ct jsonb; acts jsonb := '[]'; risks jsonb := '[]'; opps jsonb := '[]'; drv jsonb := '[]';
        rem int; req numeric; cur numeric; gap numeric; worst jsonb; best jsonb; ans text;
begin
  o := public.bi_call('overview', jsonb_build_object('month', m, 'filters', f));
  if o is null or o->>'mtd_cases' is null then
    return jsonb_build_object('answer', format('There are no tracker figures for this selection in %s.', to_char(m, 'Mon YYYY')), 'confidence', 'low');
  end if;
  fo := o->'forecast'; fr := o->'force'; ct := o->'case_tat';
  lf := bi.api_lfl(m, f, case when f ? 'location_id' then 'client' else 'location' end);
  rem := greatest(coalesce((fo->>'workdays_in_month')::int, 0) - coalesce((fo->>'workdays_elapsed')::int, 0), 0);
  gap := (o->>'target_cases')::numeric - coalesce((fo->>'curve_projection')::numeric, (fo->>'run_rate_projection')::numeric);
  cur := round((o->>'mtd_cases')::numeric / nullif((fo->>'workdays_elapsed')::numeric, 0));
  req := case when rem > 0 then ceil(((o->>'target_cases')::numeric - (o->>'mtd_cases')::numeric) / rem) end;
  select e into worst from jsonb_array_elements(lf->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 1;
  select e into best from jsonb_array_elements(lf->'rows') e where (e->>'change')::numeric > 0 order by (e->>'change')::numeric desc limit 1;
  ans := format('%s cases month to date (tracker of %s): %s of the %s target. Projected month end %s (%s of target, range %s–%s). Same working day last month (%s): %s, so %s.',
    bi.fmt_n((o->>'mtd_cases')::numeric), to_char((o->>'as_of')::date, 'DD-Mon'), bi.fmt_p((o->>'achievement')::numeric), bi.fmt_n((o->>'target_cases')::numeric),
    bi.fmt_n(coalesce((fo->>'curve_projection')::numeric, (fo->>'run_rate_projection')::numeric)), bi.fmt_p(coalesce((fo->>'curve_achievement')::numeric, (fo->>'run_rate_achievement')::numeric)),
    bi.fmt_n((fo->'curve_range'->>0)::numeric), bi.fmt_n((fo->'curve_range'->>1)::numeric),
    to_char((lf->>'comparison_snapshot')::date, 'DD-Mon'), bi.fmt_n((lf->>'total_previous')::numeric),
    case when (lf->>'total_previous') is null then 'no comparison is available'
         when (lf->>'total_current')::numeric >= (lf->>'total_previous')::numeric then 'up ' || bi.fmt_n((lf->>'total_current')::numeric - (lf->>'total_previous')::numeric)
         else 'down ' || bi.fmt_n((lf->>'total_previous')::numeric - (lf->>'total_current')::numeric) end);
  select coalesce(jsonb_agg(format('%s: %s vs the same point last month (%s → %s)', e->>'group', bi.fmt_s((e->>'change')::numeric), bi.fmt_n((e->>'previous')::numeric), bi.fmt_n((e->>'current')::numeric))), '[]')
    into drv from (select e from jsonb_array_elements(lf->'rows') e where (e->>'change')::numeric <> 0 order by abs((e->>'change')::numeric) desc limit 4) z;
  if gap > 0 then
    risks := risks || to_jsonb(format('Month end is projected about %s cases short of target (%s of target).', bi.fmt_n(gap), bi.fmt_p(coalesce((fo->>'curve_achievement')::numeric, (fo->>'run_rate_achievement')::numeric))));
    if rem > 0 then acts := acts || bi.ask_act('High', format('Lift the pace to %s cases per working day for the remaining %s working days', bi.fmt_n(req), rem),
         format('Current pace is %s cases per working day; the target needs %s more cases', bi.fmt_n(cur), bi.fmt_n((o->>'target_cases')::numeric - (o->>'mtd_cases')::numeric)),
         'Zone heads', format('Closes the projected gap of about %s cases', bi.fmt_n(gap))); end if;
  end if;
  if worst is not null then
    acts := acts || bi.ask_act('High', format('Review the fall in %s with its manager', worst->>'group'),
      format('%s cases now vs %s at the same point last month', bi.fmt_n((worst->>'current')::numeric), bi.fmt_n((worst->>'previous')::numeric)),
      case when f ? 'location_id' then 'Client relationship lead' else 'Location manager' end, format('Recovering last month''s pace adds about %s cases', bi.fmt_n(-(worst->>'change')::numeric)));
  end if;
  if best is not null then opps := opps || to_jsonb(format('%s is %s cases ahead of the same point last month — find out what worked and apply it elsewhere.', best->>'group', bi.fmt_n((best->>'change')::numeric))); end if;
  if coalesce((fr->>'excess_cases')::numeric, 0) > 0 then
    risks := risks || to_jsonb(format('%s Force1 cases sit above the tracker''s business count in %s location-group × client rows (under reconciliation).', bi.fmt_n((fr->>'excess_cases')::numeric), fr->>'units_with_force_gt_tracker'));
    acts := acts || bi.ask_act('Medium', 'Reconcile Force1 rows that exceed the tracker count', format('%s cases above the business count in %s rows', bi.fmt_n((fr->>'excess_cases')::numeric), fr->>'units_with_force_gt_tracker'),
      'Force1 / MIS team', 'Correct Force1 utilisation and business counts');
  end if;
  if (ct->>'sla_met_pct')::numeric < 0.7 then risks := risks || to_jsonb(format('SLA met for only %s of completed cases this month.', bi.fmt_p((ct->>'sla_met_pct')::numeric))); end if;
  dl := public.bi_call('daily', jsonb_build_object('month', m, 'filters', f));
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Measure', 'Value', 'Context'), 'rows', jsonb_build_array(
       jsonb_build_array('Cases month to date', bi.fmt_n((o->>'mtd_cases')::numeric), 'tracker of ' || to_char((o->>'as_of')::date, 'DD-Mon-YYYY')),
       jsonb_build_array('Target', bi.fmt_n((o->>'target_cases')::numeric), bi.fmt_p((o->>'achievement')::numeric) || ' achieved'),
       jsonb_build_array('Projected month end', bi.fmt_n(coalesce((fo->>'curve_projection')::numeric, (fo->>'run_rate_projection')::numeric)),
                         format('range %s–%s; run-rate %s', bi.fmt_n((fo->'curve_range'->>0)::numeric), bi.fmt_n((fo->'curve_range'->>1)::numeric), bi.fmt_n((fo->>'run_rate_projection')::numeric))),
       jsonb_build_array('Same working day last month', bi.fmt_n((lf->>'total_previous')::numeric), 'tracker of ' || coalesce(to_char((lf->>'comparison_snapshot')::date, 'DD-Mon-YYYY'), 'n/a')),
       jsonb_build_array('Revenue month to date', bi.fmt_inr((o->>'revenue_actual')::numeric), bi.fmt_p((o->>'revenue_achievement')::numeric) || ' of ' || bi.fmt_inr((o->>'revenue_target')::numeric)),
       jsonb_build_array('Force1 utilisation (cases)', bi.fmt_p((fr->>'usage_pct')::numeric), format('%s validated of %s business cases', bi.fmt_n((fr->>'matched_cases')::numeric), bi.fmt_n((fr->>'tracker_cases_covered')::numeric))),
       jsonb_build_array('Case TAT median / P90', bi.fmt_h((ct->>'median_hours')::numeric) || ' / ' || bi.fmt_h((ct->>'p90_hours')::numeric), 'SLA met ' || bi.fmt_p((ct->>'sla_met_pct')::numeric)))),
    'drivers', drv, 'risks', risks, 'opportunities', opps, 'actions', acts,
    'chart', jsonb_build_object('type', 'line', 'title', 'Cases month to date vs target pace', 'unit', 'cases',
       'labels', (select jsonb_agg(to_char((d->>'date')::date, 'DD-Mon') order by d->>'date') from jsonb_array_elements(dl) d),
       'series', jsonb_build_array(
          jsonb_build_object('name', 'Cases month to date', 'values', (select jsonb_agg((d->>'mtd')::numeric order by d->>'date') from jsonb_array_elements(dl) d)),
          jsonb_build_object('name', 'Target pace', 'values', (select jsonb_agg(round((o->>'target_cases')::numeric * bi.workdays(m, (d->>'date')::date) / nullif((fo->>'workdays_in_month')::numeric, 0)) order by d->>'date') from jsonb_array_elements(dl) d)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open the business breakdown for this selection', 'f', f)),
    'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'What are the five most important issues?', 'Where is TAT increasing?') ||
            case when worst is not null then jsonb_build_array(format('Why is %s lower than last month?', worst->>'group')) else '[]'::jsonb end,
    'method', 'Tracker location rows (zone sub-totals excluded). Projection = historical month-curve (range from past months); run-rate shown for comparison. Same point last month = previous month''s tracker on the same Mon–Sat working day.',
    'sources', jsonb_build_array('Zonal Tracker (bi.api_overview, bi.api_lfl, bi.api_daily)', 'Force1 Case Wise (validated utilisation)'),
    'confidence', 'high',
    'numbers', jsonb_build_array(jsonb_build_object('metric', 'MTD cases', 'value', o->'mtd_cases'), jsonb_build_object('metric', 'Target', 'value', o->'target_cases'),
                                 jsonb_build_object('metric', 'Projection', 'value', coalesce(fo->'curve_projection', fo->'run_rate_projection'))));
end $function$;

create or replace function bi.ask_h_shortfall(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare grp text := case when f ? 'location_id' then 'client' else 'location' end; P jsonb; tot_gap numeric; tot_t numeric; tot_p numeric; rem int; e int; t int;
        rows jsonb; acts jsonb := '[]'; ans text; lst text; r record; i int := 0;
begin
  P := bi.ask_perf(m, f, grp); e := (P->>'workdays_elapsed')::int; t := (P->>'workdays_total')::int; rem := greatest(t - e, 0);
  select sum((x->>'target')::numeric), sum((x->>'projection')::numeric), sum(greatest((x->>'projected_gap')::numeric, 0)) into tot_t, tot_p, tot_gap from jsonb_array_elements(P->'rows') x;
  if coalesce(tot_t, 0) = 0 then return jsonb_build_object('answer', 'The tracker has no target for this selection, so a shortfall cannot be calculated.', 'confidence', 'low'); end if;
  select string_agg(format('%s %s (%s)', x->>'label', bi.fmt_n((x->>'projected_gap')::numeric), bi.fmt_p((x->>'projected_gap')::numeric / nullif(tot_gap, 0))), '; ')
    into lst from (select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 order by (x->>'projected_gap')::numeric desc limit 5) z;
  ans := case when tot_gap = 0 then format('No %s is projected below its target at the current pace (tracker of %s).', grp, to_char((P->>'as_of')::date, 'DD-Mon'))
         else format('At the current pace, %s of the %s target is projected by month end — a gap of %s cases. Largest contributors (gap, share of the total gap): %s.',
              bi.fmt_n(tot_p), bi.fmt_n(tot_t), bi.fmt_n(tot_t - tot_p), lst) end;
  for r in select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 order by (x->>'projected_gap')::numeric desc limit 3 loop
    i := i + 1;
    acts := acts || bi.ask_act(case when i = 1 then 'High' else 'Medium' end,
      case when rem > 0 then format('Raise %s to %s cases per working day for the remaining %s working days', r.x->>'label',
                                    bi.fmt_n(ceil(((r.x->>'target')::numeric - (r.x->>'mtd')::numeric) / rem)), rem)
           else format('Review why %s closed below target', r.x->>'label') end,
      format('%s of %s target achieved; current pace %s per working day projects %s', bi.fmt_n((r.x->>'mtd')::numeric), bi.fmt_n((r.x->>'target')::numeric),
             bi.fmt_n(round((r.x->>'mtd')::numeric / nullif(e, 0))), bi.fmt_n((r.x->>'projection')::numeric)),
      case when grp = 'client' then 'Client relationship lead' else 'Location manager' end,
      format('Closes up to %s cases (%s of the total projected gap)', bi.fmt_n((r.x->>'projected_gap')::numeric), bi.fmt_p((r.x->>'projected_gap')::numeric / nullif(tot_gap, 0))));
  end loop;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array(case when grp = 'client' then 'Client' else 'Location' end, 'Target', 'Month to date', 'Achieved', 'Projected', 'Projected gap', 'Share of gap', 'vs same point last month'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(x->>'label', bi.fmt_n((x->>'target')::numeric), bi.fmt_n((x->>'mtd')::numeric), bi.fmt_p((x->>'achievement')::numeric),
                 bi.fmt_n((x->>'projection')::numeric), bi.fmt_n((x->>'projected_gap')::numeric), bi.fmt_p(greatest((x->>'projected_gap')::numeric, 0) / nullif(tot_gap, 0)), bi.fmt_s((x->>'change')::numeric))), '[]')
               from (select x from jsonb_array_elements(P->'rows') x order by (x->>'projected_gap')::numeric desc nulls last limit 10) z)),
    'drivers', (select coalesce(jsonb_agg(format('%s is %s cases %s target pace (%s vs %s expected by this working day)', x->>'label', bi.fmt_n(abs((x->>'pace_gap')::numeric)),
                 case when (x->>'pace_gap')::numeric < 0 then 'behind' else 'ahead of' end, bi.fmt_n((x->>'mtd')::numeric), bi.fmt_n((x->>'mtd')::numeric - (x->>'pace_gap')::numeric))), '[]')
                from (select x from jsonb_array_elements(P->'rows') x order by (x->>'pace_gap')::numeric limit 3) z),
    'risks', case when tot_gap > 0 then jsonb_build_array(format('Projected month end is %s of target at the current pace.', bi.fmt_p(tot_p / tot_t))) else '[]'::jsonb end,
    'opportunities', (select coalesce(jsonb_agg(format('%s is projected %s cases above its target', x->>'label', bi.fmt_n(-(x->>'projected_gap')::numeric))), '[]')
                      from (select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric < 0 order by (x->>'projected_gap')::numeric limit 2) z),
    'actions', acts,
    'chart', jsonb_build_object('type', 'hbar', 'title', 'Projected gap to target by ' || case when grp = 'client' then 'client' else 'location' end, 'unit', 'cases',
       'labels', (select jsonb_agg(x->>'label' order by (x->>'projected_gap')::numeric desc) from (select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 order by (x->>'projected_gap')::numeric desc limit 10) z),
       'series', jsonb_build_array(jsonb_build_object('name', 'Projected gap', 'values', (select jsonb_agg((x->>'projected_gap')::numeric order by (x->>'projected_gap')::numeric desc) from (select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 order by (x->>'projected_gap')::numeric desc limit 10) z)))),
    'drill', (select coalesce(jsonb_agg(jsonb_build_object('label', 'Open ' || (x->>'label'), 'f', f || case when grp = 'client' then jsonb_build_object('client_family', x->>'key') else jsonb_build_object('location_id', (x->>'location_id')::int) end)), '[]')
              from (select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 order by (x->>'projected_gap')::numeric desc limit 3) z),
    'next', (select coalesce(jsonb_agg(q), '[]') from (select format('Why is %s lower than last month?', x->>'label') q from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 order by (x->>'projected_gap')::numeric desc limit 2) z)
            || jsonb_build_array('Will we reach the target this month?', 'Where is TAT increasing?'),
    'method', format('Per %s: projection = month-to-date ÷ %s working days elapsed × %s working days in the month (run-rate; Mon–Sat). Gap = target − projection. Shares are of the total positive gap. Tracker of %s.',
                     grp, e, t, to_char((P->>'as_of')::date, 'DD-Mon-YYYY')),
    'sources', jsonb_build_array('Zonal Tracker location rows (bi.ask_perf)'), 'confidence', case when e < 5 then 'medium' else 'high' end,
    'limitations', 'Run-rate projections per ' || grp || ' assume the rest of the month continues at the month-to-date pace; the headline projection on the Overview uses the historical month curve.',
    'numbers', jsonb_build_array(jsonb_build_object('metric', 'Target', 'value', tot_t), jsonb_build_object('metric', 'Projection (run-rate)', 'value', tot_p)));
end $function$;

create or replace function bi.ask_h_growth(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare grp text := case when f ? 'location_id' or q ~ '\mclient' then 'client' when q ~ '\mzone' then 'zone' else 'location' end; L jsonb; cur numeric; prev numeric; chg numeric;
        acts jsonb := '[]'; r record; i int := 0; ans text; down text; up text;
begin
  L := bi.api_lfl(m, f, grp); cur := (L->>'total_current')::numeric; prev := (L->>'total_previous')::numeric; chg := cur - prev;
  if prev is null then return jsonb_build_object('answer', 'There is no tracker in the previous month at the same working day to compare with.', 'confidence', 'low'); end if;
  select string_agg(format('%s %s', case when grp = 'zone' then coalesce((select label from bi.zone_group where code = e->>'group'), e->>'group') else e->>'group' end, bi.fmt_s((e->>'change')::numeric)), '; ') into down
    from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 5) z;
  select string_agg(format('%s %s', case when grp = 'zone' then coalesce((select label from bi.zone_group where code = e->>'group'), e->>'group') else e->>'group' end, bi.fmt_s((e->>'change')::numeric)), '; ') into up
    from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric > 0 order by (e->>'change')::numeric desc limit 3) z;
  ans := format('%s cases month to date (tracker of %s) vs %s on the same working day last month (%s): %s %s (%s). Biggest falls: %s. Biggest rises: %s.',
     bi.fmt_n(cur), to_char((L->>'current_snapshot')::date, 'DD-Mon'), bi.fmt_n(prev), to_char((L->>'comparison_snapshot')::date, 'DD-Mon'),
     case when chg >= 0 then 'up' else 'down' end, bi.fmt_n(abs(chg)), bi.fmt_p(chg / nullif(prev, 0)), coalesce(down, 'none'), coalesce(up, 'none'));
  for r in select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 3 loop
    i := i + 1;
    acts := acts || bi.ask_act(case when i = 1 then 'High' else 'Medium' end, format('Find out why %s is behind last month and recover its pace', r.e->>'group'),
      format('%s cases now vs %s at the same point last month (%s)', bi.fmt_n((r.e->>'current')::numeric), bi.fmt_n((r.e->>'previous')::numeric), bi.fmt_p((r.e->>'change')::numeric / nullif((r.e->>'previous')::numeric, 0))),
      case grp when 'client' then 'Client relationship lead' when 'zone' then 'Zone head' else 'Location manager' end,
      format('Recovering last month''s pace adds about %s cases', bi.fmt_n(-(r.e->>'change')::numeric)));
  end loop;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array(initcap(grp), 'Now', 'Same point last month', 'Change', 'Change %'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(case when grp = 'zone' then coalesce((select label from bi.zone_group where code = e->>'group'), e->>'group') else e->>'group' end,
                 bi.fmt_n((e->>'current')::numeric), bi.fmt_n((e->>'previous')::numeric), bi.fmt_s((e->>'change')::numeric), bi.fmt_p((e->>'change')::numeric / nullif((e->>'previous')::numeric, 0)))), '[]')
               from (select e from jsonb_array_elements(L->'rows') e order by abs((e->>'change')::numeric) desc limit 10) z)),
    'drivers', (select coalesce(jsonb_agg(format('%s: %s (%s → %s)', e->>'group', bi.fmt_s((e->>'change')::numeric), bi.fmt_n((e->>'previous')::numeric), bi.fmt_n((e->>'current')::numeric))), '[]')
                from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 3) z),
    'risks', case when chg < 0 then jsonb_build_array(format('Business is %s cases behind the same point last month.', bi.fmt_n(-chg))) else '[]'::jsonb end,
    'opportunities', (select coalesce(jsonb_agg(format('%s is up %s cases — check what changed and whether it can be repeated', e->>'group', bi.fmt_n((e->>'change')::numeric))), '[]')
                      from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric > 0 order by (e->>'change')::numeric desc limit 2) z),
    'actions', acts,
    'chart', jsonb_build_object('type', 'hbar', 'title', 'Change vs the same working day last month', 'unit', 'cases',
       'labels', (select jsonb_agg(e->>'group' order by (e->>'change')::numeric) from (select e from jsonb_array_elements(L->'rows') e order by abs((e->>'change')::numeric) desc limit 10) z),
       'series', jsonb_build_array(jsonb_build_object('name', 'Change', 'values', (select jsonb_agg((e->>'change')::numeric order by (e->>'change')::numeric) from (select e from jsonb_array_elements(L->'rows') e order by abs((e->>'change')::numeric) desc limit 10) z)))),
    'drill', case when grp = 'location' then (select coalesce(jsonb_agg(jsonb_build_object('label', 'Open ' || (e->>'group'), 'f', f || jsonb_build_object('location_id', l.id))), '[]')
                    from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 3) z join bi.location l on l.label = z.e->>'group' and not l.is_rollup)
                  when grp = 'client' then (select coalesce(jsonb_agg(jsonb_build_object('label', 'Open client ' || (e->>'group'), 'f', f || jsonb_build_object('client_family', e->>'group'))), '[]')
                    from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 3) z)
                  else '[]'::jsonb end,
    'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'Will we reach the target this month?') ||
            coalesce((select jsonb_agg(format('Why is %s lower than last month?', e->>'group')) from (select e from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 1) z), '[]'),
    'method', 'Month-to-date cases on the latest tracker vs the previous month''s tracker on the same Mon–Sat working day (' || coalesce(L->>'working_days', '?') || ' working days). Cumulative values compared, never summed.',
    'sources', jsonb_build_array('Zonal Tracker location rows (bi.api_lfl)'), 'confidence', 'high',
    'limitations', 'Shows where the change happened, not why: causes (client volumes, staffing, pending allocation) are not in the tracker.',
    'numbers', jsonb_build_array(jsonb_build_object('metric', 'MTD cases', 'value', cur), jsonb_build_object('metric', 'Same point last month', 'value', prev)));
end $function$;

create or replace function bi.ask_h_tat(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare grp text := case when f ? 'location_id' or q ~ '\mclient' then 'client' else 'unit' end; om date := (select max(report_month) from bi.zt_snapshot);
        cm date; pm date; S jsonb; cur jsonb; prv jsonb; rows jsonb; acts jsonb := '[]'; ans text; lst text; r record; i int := 0; unrel text; tc jsonb; tp jsonb;
begin
  cm := case when m >= om then (m - interval '1 month')::date else m end;
  pm := (cm - interval '1 month')::date;
  S := bi.ask_tat_stats(array[pm, cm, m]::date[], f, grp);
  select coalesce(jsonb_agg(z order by (z->>'d_p90')::numeric desc nulls last), '[]') into rows from (
    select jsonb_build_object('key', c.key, 'label', c.label, 'n', (c.v->>'case_n')::int,
             'median', (c.v->>'case_median')::numeric, 'p90', (c.v->>'case_p90')::numeric, 'prev_median', (p.v->>'case_median')::numeric, 'prev_p90', (p.v->>'case_p90')::numeric,
             'd_median', (c.v->>'case_median')::numeric - (p.v->>'case_median')::numeric, 'd_p90', (c.v->>'case_p90')::numeric - (p.v->>'case_p90')::numeric,
             'field_median', (c.v->>'field_median')::numeric, 'd_field', (c.v->>'field_median')::numeric - (p.v->>'field_median')::numeric,
             'doc_median', (c.v->>'doc_median')::numeric, 'd_doc', (c.v->>'doc_median')::numeric - (p.v->>'doc_median')::numeric,
             'back_share', round((c.v->>'case_back_entered')::numeric / nullif((c.v->>'case_n')::numeric, 0), 3),
             'now_median', (n.v->>'case_median')::numeric, 'now_n', (n.v->>'case_n')::int) z
    from (select x->>'key' key, x->>'label' label, x v from jsonb_array_elements(S) x where (x->>'month')::date = cm) c
    join (select x->>'key' key, x v from jsonb_array_elements(S) x where (x->>'month')::date = pm) p using (key)
    left join (select x->>'key' key, x v from jsonb_array_elements(S) x where (x->>'month')::date = m and m <> cm) n using (key)
    where c.key is not null and c.key <> '~total' and (c.v->>'case_n')::int >= 30 and (p.v->>'case_n')::int >= 30) s;
  select string_agg(format('%s (P90 %s → %s, %s; median %s → %s)', z->>'label', bi.fmt_h((z->>'prev_p90')::numeric), bi.fmt_h((z->>'p90')::numeric),
           bi.fmt_s(round((z->>'d_p90')::numeric)) || ' h', bi.fmt_h((z->>'prev_median')::numeric), bi.fmt_h((z->>'median')::numeric)), '; ') into lst
    from (select z from jsonb_array_elements(rows) z where (z->>'d_p90')::numeric > 0 and coalesce((z->>'back_share')::numeric, 0) <= 0.5 limit 5) y;
  select string_agg(format('%s (%s of cases closed within 15 minutes of receipt)', z->>'label', bi.fmt_p((z->>'back_share')::numeric)), '; ') into unrel
    from jsonb_array_elements(rows) z where (z->>'back_share')::numeric > 0.5;
  select x into tc from jsonb_array_elements(S) x where x->>'key' = '~total' and (x->>'month')::date = cm;
  select x into tp from jsonb_array_elements(S) x where x->>'key' = '~total' and (x->>'month')::date = pm;
  ans := format('Case TAT %s vs %s (complete months)%s: P90 %s → %s, median %s → %s. Rising most in %s.', to_char(cm, 'Mon YYYY'), to_char(pm, 'Mon YYYY'),
            case when f - 'client_family' = '{}'::jsonb and not f ? 'client_family' then '' else ' for this selection' end,
            bi.fmt_h((tp->>'case_p90')::numeric), bi.fmt_h((tc->>'case_p90')::numeric), bi.fmt_h((tp->>'case_median')::numeric), bi.fmt_h((tc->>'case_median')::numeric),
            coalesce(lst, 'no group — TAT did not rise in any group with enough cases'))
         || case when unrel is not null then ' Not ranked because the times are not reliable: ' || unrel || '.' else '' end
         || case when m <> cm then format(' %s so far is incomplete: only cases completed to date are timed.', to_char(m, 'Mon')) else '' end;
  for r in select z from jsonb_array_elements(rows) z where (z->>'d_p90')::numeric > 0 and coalesce((z->>'back_share')::numeric, 0) <= 0.5 limit 3 loop
    i := i + 1;
    acts := acts || bi.ask_act(case when i = 1 then 'High' else 'Medium' end,
      format('Review the slowest 10%% of cases in %s (open TAT → %s → case records)', r.z->>'label', case when grp = 'client' then 'by client' else 'by location group' end),
      format('Case P90 rose from %s to %s (%s cases in %s)', bi.fmt_h((r.z->>'prev_p90')::numeric), bi.fmt_h((r.z->>'p90')::numeric), bi.fmt_n((r.z->>'n')::numeric), to_char(cm, 'Mon')),
      'Operations head', format('Returning P90 to %s shortens the slowest cases by about %s', bi.fmt_h((r.z->>'prev_p90')::numeric), bi.fmt_h((r.z->>'d_p90')::numeric)));
  end loop;
  if unrel is not null then
    acts := acts || bi.ask_act('Medium', 'Record cases in Force1 when they are received, not after completion', 'Back-entered cases make TAT look near zero: ' || unrel, 'Location manager', 'TAT becomes measurable for these locations');
  end if;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array(case when grp = 'client' then 'Client' else 'Location group' end, 'Cases (' || to_char(cm, 'Mon') || ')',
        'Case median', 'Δ median', 'Case P90', 'Δ P90', 'Field median', 'Document median', 'Back-entered'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(z->>'label', bi.fmt_n((z->>'n')::numeric), bi.fmt_h((z->>'median')::numeric), bi.fmt_s(round((z->>'d_median')::numeric)) || ' h',
                 bi.fmt_h((z->>'p90')::numeric), bi.fmt_s(round((z->>'d_p90')::numeric)) || ' h', bi.fmt_h((z->>'field_median')::numeric), bi.fmt_h((z->>'doc_median')::numeric), bi.fmt_p((z->>'back_share')::numeric))), '[]')
               from (select z from jsonb_array_elements(rows) z limit 12) y)),
    'drivers', (select coalesce(jsonb_agg(format('%s: field TAT %s (%s h), document TAT %s (%s h)', z->>'label', bi.fmt_h((z->>'field_median')::numeric), bi.fmt_s(round((z->>'d_field')::numeric)),
                   bi.fmt_h((z->>'doc_median')::numeric), bi.fmt_s(round((z->>'d_doc')::numeric)))), '[]')
                from (select z from jsonb_array_elements(rows) z where (z->>'d_p90')::numeric > 0 and coalesce((z->>'back_share')::numeric, 0) <= 0.5 limit 3) y),
    'risks', case when unrel is not null then jsonb_build_array('TAT cannot be measured where cases are entered after the work: ' || unrel) else '[]'::jsonb end,
    'opportunities', (select coalesce(jsonb_agg(format('%s improved: P90 %s → %s', z->>'label', bi.fmt_h((z->>'prev_p90')::numeric), bi.fmt_h((z->>'p90')::numeric))), '[]')
                      from (select z from jsonb_array_elements(rows) z where (z->>'d_p90')::numeric < 0 and coalesce((z->>'back_share')::numeric, 0) <= 0.5 order by (z->>'d_p90')::numeric limit 2) y),
    'actions', acts,
    'chart', jsonb_build_object('type', 'hbar', 'title', format('Change in case TAT P90, %s vs %s (hours)', to_char(cm, 'Mon'), to_char(pm, 'Mon')), 'unit', 'hours',
       'labels', (select jsonb_agg(z->>'label') from (select z from jsonb_array_elements(rows) z where coalesce((z->>'back_share')::numeric, 0) <= 0.5 limit 10) y),
       'series', jsonb_build_array(jsonb_build_object('name', 'Δ P90 (h)', 'values', (select jsonb_agg(round((z->>'d_p90')::numeric, 1)) from (select z from jsonb_array_elements(rows) z where coalesce((z->>'back_share')::numeric, 0) <= 0.5 limit 10) y)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open TAT for this selection', 'f', f, 'focus', 'tat')),
    'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'What is Force1 utilisation by location group?', 'What are the five most important issues?'),
    'method', 'Overall case TAT = Completed − Received (completed cases); field TAT = Field review − Assigned; document TAT per the configured rule. Groups with fewer than 30 completed cases in either month are left out; groups where more than half the cases were closed within 15 minutes of receipt are not ranked.',
    'sources', jsonb_build_array('Force1 Case Wise and Point Wise (bi.ask_tat_stats)'), 'confidence', 'high',
    'limitations', 'Compares complete months; the current month is shown separately because open cases are not yet timed.');
end $function$;
