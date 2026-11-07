-- Applied to Supabase project via MCP on 20261107154140
-- Wave 101b: Ask Crux answers potential / opportunity / current pace, targets and the quarter plan, and the split inside groups.
-- Every number comes from the same APIs as the pages (market_potential, targets, plan, split) through bi_call (cached).
create or replace function bi.ask_scope(f jsonb) returns text language sql stable security definer set search_path to 'bi', 'public' as $f$
  select coalesce((select l.label from bi.location l where l.id = nullif(f->>'location_id', '')::int),
                  (select z.label from bi.zone_group z where z.code = f->>'zone_group'), 'PAN India')
         || case when f->>'client_family' is not null then ' · ' || (f->>'client_family') else '' end $f$;

create or replace function bi.ask_h_potential(m date, f jsonb, q text, p_bm text default null) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare p jsonb; t jsonb; sc text := bi.ask_scope(f); lvl text; rows jsonb; ans text; acts jsonb := '[]'; grp text; tops jsonb;
begin
  p := public.bi_call('market_potential', jsonb_build_object('month', m, 'filters', f));
  t := p->'total';
  if p_bm is not null then
    select x into t from jsonb_array_elements(p->'by_bm') x where lower(x->>'manager') = lower(p_bm) limit 1;
    if t is null then return jsonb_build_object('answer', format('No potential is mapped to %s (teams are mapped to managers through the branch-manager list).', p_bm), 'confidence', 'low'); end if;
    sc := p_bm || ' (branch manager)';
  end if;
  if coalesce((t->>'potential')::numeric, 0) = 0 then return jsonb_build_object('answer', format('No branch potential is available for %s.', sc), 'confidence', 'low'); end if;
  lvl := case when f ? 'location_id' then 'client' when f ? 'zone_group' or p_bm is not null then 'location' when f ? 'client_family' then 'location' else 'zone' end;
  rows := case lvl when 'client' then p->'by_client' when 'location' then p->'by_location' else p->'by_zone' end;
  select coalesce(jsonb_agg(jsonb_build_array(g, bi.fmt_inr((x->>'current')::numeric), bi.fmt_inr((x->>'potential')::numeric), bi.fmt_p((x->>'penetration')::numeric), bi.fmt_inr((x->>'headroom')::numeric)) order by (x->>'headroom')::numeric desc), '[]'::jsonb),
         string_agg(format('%s %s', g, bi.fmt_inr((x->>'headroom')::numeric)), '; ' order by (x->>'headroom')::numeric desc) filter (where rn <= 3)
    into tops, grp
    from (select x, row_number() over (order by (x->>'headroom')::numeric desc) rn,
                 coalesce(x->>'client_family', x->>'location', (select z.label from bi.zone_group z where z.code = x->>'zone_group'), x->>'zone_group', '–') g
            from jsonb_array_elements(rows) x) y where rn <= 12;
  ans := format('Potential for %s is %s a month (%s basis), against current business of %s — %s captured. The opportunity of %s is: back to each team''s own best %s; dormant branches %s (%s branches); never-active branches of clients the team already serves %s; clients Crux has but the team does not serve yet %s; areas without a Crux team %s; banks with no Crux business yet %s.%s',
    sc, bi.fmt_inr((t->>'potential')::numeric), to_char((p->>'month')::date, 'Mon-YY'), bi.fmt_inr((t->>'current')::numeric), bi.fmt_p((t->>'penetration')::numeric),
    bi.fmt_inr((t->>'headroom')::numeric), bi.fmt_inr((t->>'recover')::numeric), bi.fmt_inr((t->>'dormant')::numeric), bi.fmt_n((t->>'dormant_branches')::numeric),
    bi.fmt_inr((t->>'never_served')::numeric), bi.fmt_inr((t->>'extend_team')::numeric), bi.fmt_inr((t->>'extend_no_team')::numeric), bi.fmt_inr((t->>'new_client')::numeric),
    case when p_bm is null and grp is not null then ' Largest opportunity: ' || grp || '.' else '' end);
  if (t->>'never_served')::numeric > 0 then
    acts := acts || bi.ask_act('High', 'Activate never-active branches of clients the team already serves', format('%s a month at a typical active branch''s level', bi.fmt_inr((t->>'never_served')::numeric)), 'Team heads', bi.fmt_inr((t->>'never_served')::numeric) || ' a month'); end if;
  if (t->>'dormant')::numeric > 0 then
    acts := acts || bi.ask_act('High', 'Win back dormant branches (list: Growth → Potential → Top branches to win)', format('%s branches sent cases earlier this year and none in the last three months', bi.fmt_n((t->>'dormant_branches')::numeric)), 'Branch managers', bi.fmt_inr((t->>'dormant')::numeric) || ' a month'); end if;
  if (t->>'extend_team')::numeric + (t->>'extend_no_team')::numeric > 0 then
    acts := acts || bi.ask_act('Medium', 'Take clients we already have to more teams and areas', 'Empanelment exists; the team or area does not serve the client yet', 'Zone heads / management', bi.fmt_inr((t->>'extend_team')::numeric + (t->>'extend_no_team')::numeric) || ' a month'); end if;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array(case lvl when 'client' then 'Client' when 'location' then 'Team' else 'Zone' end, 'Current', 'Potential', 'Captured', 'Opportunity'), 'rows', case when p_bm is null then tops else '[]'::jsonb end),
    'drivers', '[]'::jsonb, 'risks', '[]'::jsonb,
    'opportunities', jsonb_build_array(format('%s never-active and %s dormant branches in %s', bi.fmt_n((t->>'never_branches')::numeric), bi.fmt_n((t->>'dormant_branches')::numeric), sc)),
    'actions', acts,
    'chart', jsonb_build_object('type', 'bar', 'title', 'Potential by source — ' || sc, 'unit', '₹',
       'labels', jsonb_build_array('Current', 'Back to own best', 'Dormant', 'Never-active (served)', 'Extend to teams', 'Areas without team', 'New banks'),
       'series', jsonb_build_array(jsonb_build_object('name', '₹ a month', 'values', jsonb_build_array((t->>'current')::numeric, (t->>'recover')::numeric, (t->>'dormant')::numeric,
          (t->>'never_served')::numeric, (t->>'extend_team')::numeric, (t->>'extend_no_team')::numeric, (t->>'new_client')::numeric)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Potential (Growth)', 'section', 'growth', 'f', f)),
    'next', jsonb_build_array('What targets follow for the next 3, 6 and 12 months?', 'Are we on track for this quarter?', 'Which teams carry their zone?'),
    'method', p->>'method', 'sources', jsonb_build_array('bi.potential_cell / bi.potential_run (nightly)', 'bi.client_branch_master', 'bi.case_store', 'bi.v_month_business'),
    'confidence', 'medium', 'limitations', 'Never-active branches are valued at a typical active branch of the same client: headroom, not a forecast.');
end $f$;

create or replace function bi.ask_h_plan(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare pl jsonb; tg jsonb; sc text := bi.ask_scope(f); ans text; qn jsonb; qx jsonb; acts jsonb := '[]'; rows jsonb; mo int; mx jsonb; saved boolean;
        want_targets boolean := q ~ '(next \d+|\d+ months?|three|six|twelve|xyz|year|milestone|motivat|target(s)? for (next|the next|coming|each)|monthly targets?)';
        short_txt text;
begin
  saved := exists (select 1 from bi.plan_version);
  pl := public.bi_call('plan', jsonb_build_object('month', m, 'filters', f));
  tg := public.bi_call('targets', jsonb_build_object('month', m, 'filters', f, 'p', case when saved then jsonb_build_object('source', 'plan') else '{}'::jsonb end));
  qn := pl->'quarters'->0; qx := pl->'quarters'->1;
  select i into mo from unnest(array['\m(january|jan)\M','\m(february|feb)\M','\m(march|mar)\M','\m(april|apr)\M','\mmay\M','\m(june|jun)\M','\m(july|jul)\M','\m(august|aug)\M','\m(september|sept?)\M','\m(october|oct)\M','\m(november|nov)\M','\m(december|dec)\M']) with ordinality u(re, i) where q ~ re limit 1;
  if mo is not null then
    select x into mx from jsonb_array_elements(pl->'months') x where extract(month from (x->>'month')::date) = mo limit 1;
    if mx is null then select x into mx from jsonb_array_elements(tg->'months') x where extract(month from (x->>'month')::date) = mo limit 1; end if;
  end if;
  select string_agg(format('%s %s', x->>'location', bi.fmt_inr(abs((x->>'delta_this')::numeric))), '; ' order by (x->>'delta_this')::numeric) into short_txt
    from (select x from jsonb_array_elements(pl->'by_location') x where (x->>'delta_this')::numeric < 0 order by (x->>'delta_this')::numeric limit 3) z;
  if want_targets and mo is null then
    ans := format('Targets for %s (%s): %s. Basis: current pace %s a month (%s), potential %s, opportunity %s; target = pace + a rising share of the opportunity, growing every month within the set limits.',
      sc, case when saved then 'saved plan' else 'suggested — not saved yet; an admin can adjust and save it in Admin → Plan & targets' end,
      (select string_agg(format('%s months (%s) %s a month, %s vs current pace, %s in total over the period', x->>'months', to_char((x->>'month')::date, 'Mon-YY'),
              bi.fmt_inr((x->>'monthly_target')::numeric), bi.fmt_sp((x->>'growth_vs_reference')::numeric), bi.fmt_inr((x->>'cumulative_target')::numeric)), '; ' order by (x->>'months')::int)
         from jsonb_array_elements(tg->'milestones') x),
      bi.fmt_inr((tg->'reference'->>'pace')::numeric), to_char((tg->>'reference_month')::date, 'Mon-YY'), bi.fmt_inr((tg->'reference'->>'organic')::numeric), bi.fmt_inr((tg->'reference'->>'opportunity')::numeric));
    select coalesce(jsonb_agg(jsonb_build_array(to_char((x->>'month')::date, 'Mon-YY'), bi.fmt_inr((x->>'pace')::numeric), bi.fmt_inr((x->>'target')::numeric), bi.fmt_sp((x->>'stretch')::numeric)) order by (x->>'k')::int), '[]'::jsonb) into rows from jsonb_array_elements(tg->'months') x;
    return jsonb_build_object('answer', ans, 'findings', jsonb_build_object('columns', jsonb_build_array('Month', 'Current pace', 'Target', 'Above pace'), 'rows', rows),
      'chart', jsonb_build_object('type', 'line', 'title', 'Targets vs current pace — ' || sc, 'unit', '₹',
         'labels', (select jsonb_agg(to_char((x->>'month')::date, 'Mon-YY') order by (x->>'k')::int) from jsonb_array_elements(tg->'months') x),
         'series', jsonb_build_array(jsonb_build_object('name', 'Target', 'values', (select jsonb_agg((x->>'target')::numeric order by (x->>'k')::int) from jsonb_array_elements(tg->'months') x)),
                                     jsonb_build_object('name', 'Current pace', 'values', (select jsonb_agg((x->>'pace')::numeric order by (x->>'k')::int) from jsonb_array_elements(tg->'months') x)))),
      'actions', '[]'::jsonb, 'drill', jsonb_build_array(jsonb_build_object('label', 'Open Plan vs actual (Growth)', 'section', 'growth', 'f', f)),
      'next', jsonb_build_array('Are we on track for this quarter?', 'What is the shortfall for next quarter?', 'Where is the biggest opportunity?'),
      'method', tg->>'method', 'sources', jsonb_build_array('bi.plan_compute / bi.api_targets', 'bi.potential_cell', 'bi.organic_si', 'bi.workdays'), 'confidence', 'medium',
      'limitations', 'Targets are a plan, not a forecast; current pace assumes this month''s daily level continues with the usual seasonality.');
  end if;
  if mx is not null then
    ans := format('%s for %s: plan %s (%s), %s %s, %s %s.', to_char((mx->>'month')::date, 'Mon-YY'), sc, bi.fmt_inr(coalesce((mx->>'plan')::numeric, (mx->>'target')::numeric)),
      coalesce(mx->>'plan_source', 'suggested target'), coalesce(mx->>'basis', 'current pace'), bi.fmt_inr(coalesce((mx->>'outlook')::numeric, (mx->>'pace')::numeric)),
      case when coalesce((mx->>'delta')::numeric, 0) < 0 then 'shortfall' else 'ahead by' end, bi.fmt_inr(abs(coalesce((mx->>'delta')::numeric, (mx->>'pace')::numeric - (mx->>'target')::numeric))));
  else
    ans := format('%s (%s–%s) for %s: plan %s, outlook %s (%s actual so far + forecast at current pace) → %s %s. %sNext quarter %s: plan %s, outlook at current pace %s → %s %s, needing %s per working day vs %s now.',
      qn->>'label', to_char((qn->>'from')::date, 'Mon'), to_char((qn->>'to')::date, 'Mon-YY'), sc, bi.fmt_inr((qn->>'plan')::numeric), bi.fmt_inr((qn->>'outlook')::numeric),
      bi.fmt_inr((qn->>'actual_to_date')::numeric), case when (qn->>'delta')::numeric < 0 then 'shortfall' else 'ahead by' end, bi.fmt_inr(abs((qn->>'delta')::numeric)),
      case when (qn->>'remaining_workdays')::int > 0 then format('Closing it needs %s per working day for the %s working days left, against %s per working day now (%s). ',
           bi.fmt_inr((qn->>'needed_per_workday')::numeric), qn->>'remaining_workdays', bi.fmt_inr((qn->>'pace_per_workday')::numeric), bi.fmt_sp((qn->>'needed_vs_pace')::numeric)) else '' end,
      qx->>'label', bi.fmt_inr((qx->>'plan')::numeric), bi.fmt_inr((qx->>'outlook')::numeric), case when (qx->>'delta')::numeric < 0 then 'shortfall' else 'ahead by' end, bi.fmt_inr(abs((qx->>'delta')::numeric)),
      bi.fmt_inr((qx->>'needed_per_workday')::numeric), bi.fmt_inr((qx->>'pace_per_workday')::numeric))
      || case when short_txt is not null then ' Largest gaps this quarter: ' || short_txt || '.' else '' end
      || case when not saved then ' Months without a saved plan use the tracker target, else the suggested target.' else '' end;
  end if;
  if (qn->>'shortfall')::numeric > 0 and (qn->>'remaining_workdays')::int > 0 then
    acts := acts || bi.ask_act('High', format('Lift revenue to %s per working day for the rest of %s', bi.fmt_inr((qn->>'needed_per_workday')::numeric), qn->>'label'),
      format('Outlook %s vs plan %s', bi.fmt_inr((qn->>'outlook')::numeric), bi.fmt_inr((qn->>'plan')::numeric)), 'Zone heads', 'Closes ' || bi.fmt_inr((qn->>'shortfall')::numeric)); end if;
  select coalesce(jsonb_agg(jsonb_build_array(to_char((x->>'month')::date, 'Mon-YY'), bi.fmt_inr((x->>'plan')::numeric), coalesce(x->>'plan_source', '–'), bi.fmt_inr((x->>'outlook')::numeric), x->>'basis', bi.fmt_sinr((x->>'delta')::numeric)) order by x->>'month'), '[]'::jsonb)
    into rows from jsonb_array_elements(pl->'months') x;
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('Month', 'Plan', 'Plan source', 'Outlook', 'Basis', 'Delta'), 'rows', rows),
    'risks', case when (qn->>'needed_vs_pace')::numeric > 0.25 then jsonb_build_array('The rest of the quarter needs more than 25% above the current daily pace.') else '[]'::jsonb end,
    'actions', acts,
    'chart', jsonb_build_object('type', 'bar', 'title', 'Plan vs outlook — ' || sc, 'unit', '₹',
       'labels', (select jsonb_agg(to_char((x->>'month')::date, 'Mon-YY') order by x->>'month') from jsonb_array_elements(pl->'months') x),
       'series', jsonb_build_array(jsonb_build_object('name', 'Plan', 'values', (select jsonb_agg((x->>'plan')::numeric order by x->>'month') from jsonb_array_elements(pl->'months') x)),
                                   jsonb_build_object('name', 'Outlook', 'values', (select jsonb_agg((x->>'outlook')::numeric order by x->>'month') from jsonb_array_elements(pl->'months') x)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Plan vs actual (Growth)', 'section', 'growth', 'f', f)),
    'next', jsonb_build_array('What targets follow for the next 3, 6 and 12 months?', 'Which teams are furthest behind plan?', 'Where is the biggest opportunity?'),
    'method', pl->>'method', 'sources', jsonb_build_array('bi.api_plan', 'bi.plan_version / bi.plan_target', 'bi.v_month_business', 'bi.potential_cell'), 'confidence', 'medium',
    'limitations', 'Forecast months assume the current daily level continues with the usual seasonality; they are replaced by actuals as trackers arrive.');
end $f$;

create or replace function bi.ask_h_split(m date, f jsonb, q text, p_bm text default null) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare lvl text; s jsonb; g jsonb; sc text := bi.ask_scope(f); ans text; rows jsonb; fl text; nflag int; ngr int; weak text; topm text; gl text;
begin
  lvl := case when q ~ '(people|staff|employee|person|executive|back office|field)' then 'people'
              when p_bm is not null or q ~ '(manager|\mbms?\M)' then 'bm'
              when f ? 'location_id' then 'location' else 'zone' end;
  s := public.bi_call('split', jsonb_build_object('month', m, 'filters', f, 'p', jsonb_build_object('level', lvl, 'measure', 'revenue')));
  ngr := jsonb_array_length(coalesce(s->'groups', '[]'::jsonb));
  if ngr = 0 then return jsonb_build_object('answer', 'No groups to split for this selection.', 'confidence', 'low'); end if;
  if p_bm is not null then select x into g from jsonb_array_elements(s->'groups') x where lower(x->>'group') = lower(p_bm) limit 1;
  elsif lvl <> 'people' and (ngr = 1 or f ? 'zone_group' or f ? 'location_id') then select x into g from jsonb_array_elements(s->'groups') x order by (x->>'actual')::numeric desc limit 1; end if;
  if lvl = 'people' then
    select count(*) filter (where (x->>'carried')::boolean), count(*) filter (where (x->>'members')::int >= 3) into nflag, ngr from jsonb_array_elements(s->'groups') x;
    ans := format('Force1 work in %s (%s): in %s of %s teams × roles with three or more people, half of the actions come from one person or from 20%% of the people or fewer. Ask Crux does not name people; the Overview card "Inside each group" shows each team (names for admins).',
      sc, to_char((s->>'month')::date, 'Mon-YY'), nflag, ngr);
    select coalesce(jsonb_agg(jsonb_build_array(x->>'group', x->>'members', bi.fmt_n((x->>'total')::numeric), bi.fmt_p((x->>'top1_share')::numeric), (x->>'n50') || ' of ' || (x->>'members'), x->>'low') order by (x->>'total')::numeric desc), '[]'::jsonb)
      into rows from (select x from jsonb_array_elements(s->'groups') x where (x->>'members')::int >= 3 order by (x->>'total')::numeric desc limit 15) z;
    return jsonb_build_object('answer', ans, 'findings', jsonb_build_object('columns', jsonb_build_array('Team — role', 'People', 'Actions', 'Top person''s share', 'Half from', 'Well below median'), 'rows', rows),
      'drill', jsonb_build_array(jsonb_build_object('label', 'Open Inside each group (Overview)', 'section', 'overview', 'f', f)), 'method', s->>'method', 'sources', jsonb_build_array('bi.api_split', 'bi.person_month'), 'confidence', 'medium',
      'next', jsonb_build_array('Which zones look fine but have most teams behind?', 'Who carries the Rest of Maharashtra zone?'));
  end if;
  if g is not null then
    gl := case when lvl = 'zone' then coalesce((select z.label from bi.zone_group z where z.code = g->>'group'), g->>'group') else g->>'group' end;
    select string_agg(format('%s %s (%s of the group, %s of its target to date)', x->>'member', bi.fmt_inr((x->>'value')::numeric), bi.fmt_p((x->>'share')::numeric), bi.fmt_p((x->>'achievement')::numeric)), '; ' order by (x->>'rank')::int)
      into topm from jsonb_array_elements(s->'members') x where x->>'group' = g->>'group' and (x->>'rank')::int <= greatest((g->>'n50')::int, 1);
    select string_agg(format('%s %s', x->>'member', bi.fmt_p((x->>'achievement')::numeric)), '; ' order by (x->>'achievement')::numeric) into weak
      from (select x from jsonb_array_elements(s->'members') x where x->>'group' = g->>'group' and x->>'status' in ('behind', 'far behind') order by (x->>'achievement')::numeric limit 4) z;
    ans := format('%s (%s to %s): %s of its target to date as a group — %s on track, %s behind, %s far behind%s. Half of its revenue comes from %s of %s: %s.%s%s',
      gl, to_char((s->>'month')::date, 'Mon-YY'), to_char((s->>'as_of')::date, 'DD-Mon'), bi.fmt_p((g->>'achievement')::numeric), g->>'on_track', g->>'behind', g->>'far_behind',
      case when (g->>'no_target')::int > 0 then format(', %s without a target', g->>'no_target') else '' end, g->>'n50', g->>'members', coalesce(topm, '–'),
      case when weak is not null then ' Furthest behind: ' || weak || '.' else '' end,
      case when (g->>'masked')::boolean then ' The group total hides that most members are behind.' else '' end);
    select coalesce(jsonb_agg(jsonb_build_array(x->>'member', bi.fmt_inr((x->>'value')::numeric), bi.fmt_inr((x->>'target_to_date')::numeric), bi.fmt_p((x->>'achievement')::numeric), bi.fmt_p((x->>'share')::numeric), x->>'status') order by (x->>'rank')::int), '[]'::jsonb)
      into rows from jsonb_array_elements(s->'members') x where x->>'group' = g->>'group';
    return jsonb_build_object('answer', ans,
      'findings', jsonb_build_object('columns', jsonb_build_array(case lvl when 'zone' then 'Team' when 'bm' then 'Account' else 'Client' end, 'Revenue', 'Target to date', 'Achieved', 'Share', 'Status'), 'rows', rows),
      'risks', case when (g->>'carried')::boolean then jsonb_build_array(format('%s depends on %s of %s members for half its business.', gl, g->>'n50', g->>'members')) else '[]'::jsonb end,
      'actions', case when weak is not null then jsonb_build_array(bi.ask_act('High', 'Review the members furthest behind with their managers', weak, 'Zone / branch managers', 'Spreads the load beyond ' || (g->>'n50') || ' member(s)')) else '[]'::jsonb end,
      'chart', jsonb_build_object('type', 'bar', 'title', 'Achieved to date — ' || gl, 'unit', '%',
         'labels', (select jsonb_agg(x->>'member' order by (x->>'rank')::int) from jsonb_array_elements(s->'members') x where x->>'group' = g->>'group'),
         'series', jsonb_build_array(jsonb_build_object('name', 'Achieved to date', 'values', (select jsonb_agg(round((x->>'achievement')::numeric * 100, 1) order by (x->>'rank')::int) from jsonb_array_elements(s->'members') x where x->>'group' = g->>'group')))),
      'drill', jsonb_build_array(jsonb_build_object('label', 'Open Inside each group (Overview)', 'section', 'overview', 'f', f)),
      'next', jsonb_build_array('Where is the biggest opportunity in this zone?', 'Are we on track for this quarter?', 'Which zones look fine but have most teams behind?'),
      'method', s->>'method', 'sources', jsonb_build_array('bi.api_split', 'bi.v_month_business', 'bi.branch_manager'), 'confidence', 'high');
  end if;
  select count(*) filter (where x->>'flag' <> ''), string_agg(format('%s — %s', case when lvl = 'zone' then coalesce((select z.label from bi.zone_group z where z.code = x->>'group'), x->>'group') else x->>'group' end, x->>'flag'), '; ') filter (where x->>'flag' <> '')
    into nflag, fl from jsonb_array_elements(s->'groups') x;
  ans := format('%s of %s %s are flagged (%s): %s.', nflag, ngr, case lvl when 'zone' then 'zones' when 'bm' then 'branch managers' else 'teams' end, to_char((s->>'month')::date, 'Mon-YY'), coalesce(fl, 'none'));
  select coalesce(jsonb_agg(jsonb_build_array(case when lvl = 'zone' then coalesce((select z.label from bi.zone_group z where z.code = x->>'group'), x->>'group') else x->>'group' end,
           bi.fmt_p((x->>'achievement')::numeric), (x->>'on_track') || ' / ' || ((x->>'behind')::int + (x->>'far_behind')::int), (x->>'n50') || ' of ' || (x->>'members'), coalesce(nullif(x->>'flag', ''), '–')) order by (x->>'actual')::numeric desc), '[]'::jsonb)
    into rows from jsonb_array_elements(s->'groups') x;
  return jsonb_build_object('answer', ans, 'findings', jsonb_build_object('columns', jsonb_build_array('Group', 'Achieved to date', 'On track / behind', 'Half from', 'Flag'), 'rows', rows),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Inside each group (Overview)', 'section', 'overview', 'f', f)), 'method', s->>'method', 'sources', jsonb_build_array('bi.api_split', 'bi.v_month_business'), 'confidence', 'high',
    'next', jsonb_build_array('Who carries the Rest of Maharashtra zone?', 'Which branch managers look fine but have most accounts behind?', 'Where is the biggest opportunity?'));
end $f$;

revoke all on function bi.ask_scope(jsonb), bi.ask_h_potential(date, jsonb, text, text), bi.ask_h_plan(date, jsonb, text), bi.ask_h_split(date, jsonb, text, text) from public, anon, authenticated;

-- routing in bi_ask3: new intents before the branch-manager and revenue rules; follow-ups ("what about ...") keep them
do $m$
declare d text := pg_get_functiondef('public.bi_ask3(text, jsonb, uuid)'::regprocedure); o text;
begin
  if position('''potential''' in d) > 0 then return; end if;
  o := d;
  d := replace(d, $a$'revenue_growth', 'bm', 'revenue_now', 'ops', 'cases')$a$, $a$'revenue_growth', 'bm', 'revenue_now', 'ops', 'cases', 'potential', 'plan', 'split')$a$);
  if d = o then raise exception 'routing edit 1'; end if; o := d;
  d := replace(d, $a$    when q ~ '\mwho\M' and q ~ '(handles?|handling|manag|looks? after|in charge|responsib|owns?|takes? care)' then 'bm'$a$,
$a$    when q ~ '(carr(y|ies|ying|ied)|burden|concentrat|dependen|depends on|inside (the |each |a )?(zone|team|group)|\msplit\M|how many (teams|locations|members|accounts|clients) (are )?(behind|on track|performing)|only (one|1|a few|few|two|three) (team|location|person|people|member)|looks? (good|fine|green) but)' then 'split'
    when q ~ '(\mplan\M|planned|plan vs|vs plan|this quarter|next quarter|quarter (plan|target|forecast|outlook)|\mq[1-4]\M|run.?rate needed|needed per (day|working day)|\mxyz\M|next \d+ months|next (three|six|twelve) months|\d+.?months? target|motivat|target(s)? for (next|the next|coming|each)|monthly targets?|targets? for (january|february|march|april|may|june|july|august|september|october|november|december))' then 'plan'
    when q ~ '(potential|opportunit|headroom|penetration|untapped|white ?space|captured|current pace|never.?active|market size)' and q !~ '(remaining|rest of (the )?month|month.end)' then 'potential'
    when q ~ '\mwho\M' and q ~ '(handles?|handling|manag|looks? after|in charge|responsib|owns?|takes? care)' then 'bm'$a$);
  if d = o then raise exception 'routing edit 2'; end if; o := d;
  d := replace(d, $a$    when 'cases' then bi.ask_h_cases(m, f)$a$, $a$    when 'cases' then bi.ask_h_cases(m, f)
    when 'potential' then bi.ask_h_potential(m, f, q, bmn)
    when 'plan' then bi.ask_h_plan(m, f, q)
    when 'split' then bi.ask_h_split(m, f, q, bmn)$a$);
  if d = o then raise exception 'routing edit 3'; end if;
  execute d;
end $m$;
