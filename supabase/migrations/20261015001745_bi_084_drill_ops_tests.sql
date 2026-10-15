-- Applied to Supabase project via MCP on 20261015001745
-- bi_084: drill-down operational detail must equal the dashboard sections it summarises (read-only tests)
create or replace function bi.run_drill_ops_tests()
returns table(test text, passed boolean, detail jsonb)
language plpgsql security definer set search_path to 'bi', 'public', 'extensions' as $function$
declare m date := date_trunc('month', (select max(snapshot_date) from bi.zt_snapshot))::date; f jsonb := '{"zone_group":"GUJARAT"}';
        a jsonb; b jsonb; c jsonb; ov jsonb; k text; bad jsonb := '[]'::jsonb; s1 text; s2 text; br jsonb;
begin
  ov := bi.api_overview(m, f);
  -- T43 TAT: per location equal to the TAT section (case + point tables); total equal to the Overview tile
  a := bi.tat_summary(m, f, 'location');
  select coalesce(jsonb_agg(jsonb_build_object('location', l.label, 'ops', t.x, 'case_api', c2.x, 'point_api', p2.x)), '[]'::jsonb) into bad
  from jsonb_array_elements(a) t(x) join bi.location l on l.id::text = t.x->>'id'
  left join jsonb_array_elements(bi.api_case_tat(m, f, 'location')) c2(x) on c2.x->>'key' = l.label
  left join jsonb_array_elements(bi.api_point_tat(m, f, 'location')) p2(x) on p2.x->>'key' = l.label
  where (t.x->'case'->>'median') is distinct from (c2.x->>'median_hours') or (t.x->'case'->>'cases') is distinct from coalesce(c2.x->>'cases', '0')
     or (t.x->'field'->>'median') is distinct from (p2.x->>'field_median_hours') or (t.x->'document'->>'median') is distinct from (p2.x->>'doc_median_hours')
     or (t.x->'tele'->>'median') is distinct from (p2.x->>'tele_median_hours') or (t.x->>'points') is distinct from coalesce(p2.x->>'points', '0');
  b := bi.tat_summary(m, f, 'total')->0;
  test := 'T43 drawer TAT (case, document, field, tele) = TAT section per location; total case TAT = Overview tile';
  passed := jsonb_array_length(bad) = 0 and jsonb_array_length(a) > 0
        and (b->'case'->>'median')::numeric = (ov->'case_tat'->>'median_hours')::numeric and (b->'case'->>'completed')::int = (ov->'case_tat'->>'completed_valid')::int
        and (b->'case'->>'open')::int = (ov->'case_tat'->>'open')::int;
  detail := jsonb_build_object('month', m, 'mismatches', bad, 'total_case', b->'case', 'overview_case_tat', ov->'case_tat'); return next;

  -- T44 Force1 utilisation
  a := bi.api_drill_ops(m, f, 'location', 'force1'); b := bi.api_force1(m, f)->'totals'; bad := '[]'::jsonb;
  foreach k in array array['tracker_cases','force1_cases','case_utilisation','field_points','f1_field','manual_field','unverified_field','field_utilisation','field_execs','back_office_staff','f1_field_tat_hours','manual_field_tat_hours'] loop
    if (a->'total'->k) is distinct from (b->k) then bad := bad || jsonb_build_object(k, jsonb_build_array(a->'total'->k, b->k)); end if; end loop;
  test := 'T44 drawer Force1 utilisation = Force1 utilisation section; children add up';
  passed := jsonb_array_length(bad) = 0
        and (select sum((x->>'f1_field')::int) from jsonb_array_elements(a->'children') x) = (a->'total'->>'f1_field')::int
        and (select sum((x->>'manual_field')::int) from jsonb_array_elements(a->'children') x) = (a->'total'->>'manual_field')::int;
  detail := jsonb_build_object('mismatches', bad, 'total', a->'total'); return next;

  -- T45 branch coverage
  a := bi.api_drill_ops(m, f, 'location', 'coverage'); b := bi.api_branch_coverage(f)->'totals';
  test := 'T45 drawer branch coverage = Business tracker coverage; children add up';
  passed := (a->'total'->>'verified_active')::int = (b->>'verified_active')::int and (a->'total'->>'never_activated')::int = (b->>'never_activated')::int
        and (a->'total'->>'active_6m')::int = (b->>'active_with_crux_6m')::int and (a->'total'->>'website_listed')::int = (b->>'website_listed')::int
        and (a->'total'->>'coverage_6m')::numeric = (b->>'coverage_6m')::numeric
        and (select sum((x->>'verified_active')::int) from jsonb_array_elements(a->'children') x) = (a->'total'->>'verified_active')::int
        and (select sum((x->>'gone_quiet_6m')::int) from jsonb_array_elements(a->'children') x) = (a->'total'->>'gone_quiet_6m')::int;
  detail := jsonb_build_object('drawer', a->'total', 'section', b); return next;

  -- T46 branch lifecycle
  a := bi.api_drill_ops(m, f, 'location', 'lifecycle'); b := bi.api_branches(f)->'summary'; bad := '[]'::jsonb;
  foreach k in array array['new','reactivated','growing','stable','losing_traction','dormant','insufficient_data'] loop
    if coalesce((a->'total'->>k)::int, 0) <> coalesce((b->>k)::int, 0) then bad := bad || jsonb_build_object(k, jsonb_build_array(a->'total'->k, b->k)); end if;
    if (select coalesce(sum((x->>k)::int), 0) from jsonb_array_elements(a->'children') x) <> coalesce((a->'total'->>k)::int, 0) then bad := bad || jsonb_build_object(k || ' children', true); end if;
  end loop;
  test := 'T46 drawer branch lifecycle (new, reactivated, growing, stable, losing traction, dormant) = branch priority list; children add up';
  passed := jsonb_array_length(bad) = 0;
  detail := jsonb_build_object('mismatches', bad, 'drawer', a->'total', 'section', b); return next;

  -- T47 revenue, penalties, like-for-like
  a := bi.api_drill_ops(m, f, 'location', 'revenue'); b := bi.api_drill_ops(m, f, 'location', 'penalty'); c := bi.api_drill(m, f, 'location');
  test := 'T47 drawer revenue = Overview revenue; penalties = penalty report; like-for-like current = cases so far';
  passed := (a->'total'->>'mtd')::numeric = (ov->>'revenue_actual')::numeric and (a->'total'->>'target')::numeric = (ov->>'revenue_target')::numeric
        and (b->'total'->>'amount')::numeric = (bi.api_penalty(m, f)->'grand'->>'total')::numeric
        and (c->'lfl'->>'current')::numeric = (c->'selected'->>'mtd')::numeric
        and (select coalesce(sum((x->>'mtd')::numeric), 0) from jsonb_array_elements(a->'children') x) = (a->'total'->>'mtd')::numeric;
  detail := jsonb_build_object('revenue', a->'total'->'mtd', 'overview', ov->'revenue_actual', 'penalty', b->'total', 'lfl', c->'lfl'); return next;

  -- T48 branch detail status = branch list status; branch detail TAT counts the branch's cases of the last 3 months
  br := bi.api_drill(m, jsonb_build_object('location_id', (select id from bi.location where label = 'Pune')), 'branch');
  a := bi.api_drill_ops(m, jsonb_build_object('location_id', (select id from bi.location where label = 'Pune')), 'branch', 'lifecycle');
  b := bi.api_branch_detail(jsonb_build_object('client_family', br->'branches'->0->>'client_family', 'branch_code', br->'branches'->0->>'branch_code'));
  select x->>'status' into s1 from jsonb_array_elements(a->'branches') x
   where x->>'client_family' = br->'branches'->0->>'client_family' and x->>'code_norm' = bi.norm_code(br->'branches'->0->>'branch_code') order by (x->>'last3m')::numeric desc nulls last limit 1;
  s2 := b->'lifecycle'->>'status';
  test := 'T48 branch detail lifecycle status = branch list status; branch TAT counts its last-3-month cases';
  passed := s1 is not null and s1 = s2
        and (b->'tat'->'case'->>'cases')::int = (select count(*) from bi.case_store c2 where c2.client_code in (select code from bi.client where family = br->'branches'->0->>'client_family')
                                                   and bi.norm_code(c2.branch_code) = bi.norm_code(br->'branches'->0->>'branch_code') and c2.received_month >= (b->'tat'->>'since')::date);
  detail := jsonb_build_object('branch', br->'branches'->0, 'list_status', s1, 'detail_status', s2, 'tat_case', b->'tat'->'case'); return next;
end $function$;
