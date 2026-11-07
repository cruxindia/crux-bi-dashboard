-- Applied to Supabase project via MCP on 20261107160923
-- wave 101l (7-Nov-2026): Ask Crux ranks potential by branch manager / zone / team / client; BAU wording in revenue answers and the billed-growth method text
create or replace function bi.ask_h_potential(m date, f jsonb, q text, p_bm text default null) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare p jsonb; t jsonb; sc text := bi.ask_scope(f); lvl text; rows jsonb; ans text; acts jsonb := '[]'; grp text; tops jsonb; dim text; met text; up boolean; n int; unm numeric;
begin
  p := public.bi_call('market_potential', jsonb_build_object('month', m, 'filters', f));
  t := p->'total';
  if p_bm is not null then
    select x into t from jsonb_array_elements(p->'by_bm') x where lower(x->>'manager') = lower(p_bm) limit 1;
    if t is null then return jsonb_build_object('answer', format('No potential is mapped to %s (teams are mapped to managers through the branch-manager list).', p_bm), 'confidence', 'low'); end if;
    sc := p_bm || ' (branch manager)';
  end if;
  if coalesce((t->>'potential')::numeric, 0) = 0 then return jsonb_build_object('answer', format('No branch potential is available for %s.', sc), 'confidence', 'low'); end if;
  -- wave 101l: "which manager / zone / team / client has the biggest potential (opportunity, lowest share captured)?" -> a ranking
  if p_bm is null and q ~* '\m(which|who|top|rank|ranking|ranked|biggest|largest|highest|most|lowest|least|best|worst|smallest)\M' then
    dim := case when q ~* 'manager|\mbms?\M' then 'bm' when q ~* '\m(team|teams|location|locations)\M' then 'location' when q ~* '\m(client|clients|bank|banks)\M' then 'client' when q ~* '\mzones?\M' then 'zone' end;
    if dim is not null then
      met := case when q ~* 'captur|penetrat|share' then 'penetration' when q ~* 'opportunit|headroom|gap|untapped' then 'headroom' else 'potential' end;
      up := case when met = 'penetration' then not (q ~* '\m(highest|most|best|biggest|largest)\M') else q ~* '\m(lowest|least|worst|smallest)\M' end;
      rows := case dim when 'bm' then p->'by_bm' when 'location' then p->'by_location' when 'client' then p->'by_client' else p->'by_zone' end;
      select coalesce(jsonb_agg(jsonb_build_array(g, bi.fmt_inr((x->>'current')::numeric), bi.fmt_inr((x->>'potential')::numeric), bi.fmt_p((x->>'penetration')::numeric), bi.fmt_inr((x->>'headroom')::numeric)) order by rn) filter (where rn <= 12), '[]'::jsonb),
             string_agg(format('%s. %s — potential %s, %s captured, opportunity %s', rn, g, bi.fmt_inr((x->>'potential')::numeric), bi.fmt_p((x->>'penetration')::numeric), bi.fmt_inr((x->>'headroom')::numeric)), '; ' order by rn) filter (where rn <= 5),
             count(*)
        into tops, grp, n
        from (select x, g, row_number() over (order by case when up then (x->>met)::numeric end asc nulls last, case when not up then (x->>met)::numeric end desc nulls last, g) rn
                from (select x, coalesce(x->>'manager', x->>'client_family', x->>'location', (select z.label from bi.zone_group z where z.code = x->>'zone_group'), x->>'zone_group', '–') g
                        from jsonb_array_elements(rows) x) y0
               where g not like '(no team%' and coalesce((x->>'potential')::numeric, 0) > 0) y;
      select coalesce(sum((x->>'potential')::numeric), 0) into unm from jsonb_array_elements(rows) x where coalesce(x->>'manager', '') like '(no team%';
      ans := format('%s ranked by %s (%s basis, %s): %s. All together: potential %s a month, current %s (%s captured).%s',
        case dim when 'bm' then 'Branch managers' when 'location' then 'Teams' when 'client' then 'Clients' else 'Zones' end,
        case met when 'penetration' then 'share of potential captured' || case when up then ', lowest first' else ', highest first' end when 'headroom' then 'opportunity (potential − current)' || case when up then ', smallest first' else '' end else 'potential' || case when up then ', smallest first' else '' end end,
        to_char((p->>'month')::date, 'Mon-YY'), sc, coalesce(grp, 'none'), bi.fmt_inr((t->>'potential')::numeric), bi.fmt_inr((t->>'current')::numeric), bi.fmt_p((t->>'penetration')::numeric),
        case when dim = 'bm' and unm > 0 then format(' %s of potential sits with teams or areas that have no mapped branch manager.', bi.fmt_inr(unm)) else '' end);
      return jsonb_build_object('answer', ans,
        'findings', jsonb_build_object('columns', jsonb_build_array(case dim when 'bm' then 'Branch manager' when 'location' then 'Team' when 'client' then 'Client' else 'Zone' end, 'Current', 'Potential', 'Captured', 'Opportunity'), 'rows', tops),
        'drivers', '[]'::jsonb, 'risks', '[]'::jsonb, 'opportunities', '[]'::jsonb, 'actions', '[]'::jsonb,
        'drill', jsonb_build_array(jsonb_build_object('label', 'Open Potential (Growth)', 'section', 'growth', 'f', f)),
        'next', jsonb_build_array('What is the potential of the first one?', 'What targets follow for the next 3, 6 and 12 months?', 'Which teams carry their zone?'),
        'method', p->>'method' || case when dim = 'bm' then ' Managers: each team × client is counted under the branch manager mapped for it on the potential run''s date (bi.branch_manager_code_at); a client-family-level approximation where one team serves a client through several managers.' else '' end,
        'sources', jsonb_build_array('bi.potential_cell / bi.potential_run (nightly)', 'bi.branch_manager (effective dates)', 'bi.client_branch_master'),
        'confidence', 'medium', 'limitations', 'Never-active branches are valued at a typical active branch of the same client: headroom, not a forecast.');
    end if;
  end if;
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

do $m$
declare d text; o text;
begin
  d := pg_get_functiondef('bi.ask_h_revenue(date, jsonb, text)'::regprocedure); o := d;
  d := replace(d, '(organic growth ', '(BAU change ');
  d := replace(d, 'Growth beyond organic', 'Growth beyond BAU');
  d := replace(d, 'growth beyond organic', 'growth beyond BAU');
  d := replace(d, ', beyond organic ', ', beyond BAU ');
  d := replace(d, 'furthest below its organic expectation', 'furthest below its BAU expectation');
  if d = o then raise exception 'ask_h_revenue: no wording found'; end if;
  execute d;
  d := pg_get_functiondef('bi.api_growth_rev(date, jsonb, jsonb)'::regprocedure); o := d;
  d := replace(d, 'Expected organic growth = organic (current) − organic (comparison)', 'Expected BAU change = BAU (current) − BAU (comparison)');
  d := replace(d, 'actual growth − expected organic growth', 'actual growth − expected BAU change');
  d := replace(d, 'so expected organic growth comes from organic case growth', 'so the expected BAU change comes from BAU case growth');
  if d = o then raise exception 'api_growth_rev: no wording found'; end if;
  execute d;
end $m$;
