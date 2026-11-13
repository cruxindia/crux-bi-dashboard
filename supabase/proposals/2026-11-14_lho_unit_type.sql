-- Proposal (not applied): LHO (Local Head Office) as a unit type in the one counting function.
-- Why: an Ask Crux answer about LHO units got 👎 on 13-Nov-2026 ("asked for LHO, didn't get it"). LHO rows exist in the
-- client branch master as administrative offices (branch_type 'office'), so bi.unit_type() calls them 'Office' and
-- bi.api_branch_units() leaves them out of every count ("administrative office").
-- Change: (1) bi.unit_type() returns 'LHO' for an office whose name says LHO / Local Head Office (checked only for
-- branch_type 'office', so a processing centre inside an LHO building keeps its own type); (2) bi.api_branch_units()
-- counts LHO rows only when 'LHO' is asked for by name, so every existing count (all types, RACPC, branches …) is unchanged.
-- Dry run (read-only, 14-Nov-2026): only rows that were 'Office' change, all to 'LHO'; no other row changes type.
-- Apply: run this file once in the SQL editor (owner). Undo: re-run the previous definitions (migration bi_109* export).
-- Note: the run_sql view ai.branches keeps its own copy of the type rule and is not changed here (Ask Crux counts units only
-- through bi.api_branch_units).

CREATE OR REPLACE FUNCTION bi.unit_type(p_name text, p_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  select case
    when p_name ~* 'mini\s*-?\s*rac\s*pa?c' then 'Mini RACPC'
    when p_name ~* 'rac\s*pa?c' then 'RACPC'
    when p_name ~* 'rasme\s*c|rasmec' then 'RASMECCC'
    when p_name ~* 'smecc|\msme\s+ccc?\M' then 'SMECCC'
    when p_name ~* '\msarc\M' then 'SARC'
    when p_name ~* '\mrac\M' then 'RAC'
    when p_name ~* '\mracc\M' then 'RACC'
    when p_name ~* 'cpc' then 'Other CPC'
    when coalesce(p_type, 'branch') = 'processing_centre' then 'Other processing centre'
    when coalesce(p_type, 'branch') = 'office' and p_name ~* '\mlhos?\M|local\s+head\s+offices?' then 'LHO'
    when coalesce(p_type, 'branch') = 'office' then 'Office'
    when p_name ~* '\mm?sme\M' then 'SME branch'
    else 'Branch' end $function$;

CREATE OR REPLACE FUNCTION bi.api_branch_units(f jsonb DEFAULT '{}'::jsonb, p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'bi', 'public'
 SET statement_timeout TO '40s'
AS $function$
declare v_m date; v_inact text[]; v_types text[]; v_locs int[]; v_list boolean := coalesce((p->>'list')::boolean, false);
        v_lim int := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); v_out jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  v_locs := array(select l.id from bi.location l where bi.loc_ok(l.id, null, f));   -- wave 109g
  v_types := case jsonb_typeof(p->'unit_type') when 'array' then array(select trim(x) from jsonb_array_elements_text(p->'unit_type') x where trim(x) <> '')
                                                when 'string' then array(select trim(x) from unnest(string_to_array(p->>'unit_type', ',')) x where trim(x) <> '') end;
  if cardinality(v_types) = 0 then v_types := null; end if;
  select x.month, array(select jsonb_array_elements_text(coalesce(x.inputs->'inactive_clients', '[]'::jsonb))) into v_m, v_inact
    from bi.potential_run x order by x.run_id desc limit 1;
  with mst as materialized (
    select b.branch_uid, b.client_family fam, b.code_norm code, b.branch_code, b.branch_name, b.city, b.state, b.status, b.verification_status, b.source_type, b.branch_type,
           coalesce(b.location_id, fr.location_id) loc, b.zone_group bzg, bi.unit_type(b.branch_name, b.branch_type) ut
      from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid
     where b.client_family is not null and (f->>'client_family' is null or b.client_family = f->>'client_family')),
  msel as materialized (
    select m.*, l.label team, coalesce(l.zone_group, l.rollup_zone, m.bzg) zg
      from mst m left join bi.location l on l.id = m.loc
     where (v_types is null or m.ut = any (v_types))
       and case when (f - 'client_family') = '{}'::jsonb then true when m.loc is not null then m.loc = any (v_locs)
                else (f - 'client_family') = '{}'::jsonb or (f->>'zone_group' is not null and f->>'location_id' is null and f->>'stakeholder' is null and m.bzg = f->>'zone_group') end),
  uni as materialized (
    select distinct on (s.fam, s.code) s.*
      from msel s
     where s.status = 'active' and coalesce(s.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')
       and coalesce(s.source_type, '') <> 'official_website'
       and (coalesce(s.branch_type, 'branch') <> 'office' or (s.ut = 'LHO' and v_types is not null))   -- LHO only when asked for by name
       and s.code is not null and s.fam <> all (v_inact)
     order by s.fam, s.code, (s.loc is null), s.branch_uid),
  ua as materialized (
    select u.*, a.last_m, a.first_m, coalesce(a.n, 0) n, coalesce(a.n3, 0) n3,
           case when a.code_norm is null then 'never active' when a.last_m >= (v_m - interval '2 months')::date then 'active' else 'dormant' end st
      from uni u left join bi.branch_activity a on a.fam = u.fam and a.code_norm = u.code),
  outside as (
    select case when s.status is distinct from 'active' then 'closed or inactive in the source list'
                when coalesce(s.verification_status, 'admin_upload') not in ('source_verified', 'admin_upload') then 'status not confirmed'
                when coalesce(s.source_type, '') = 'official_website' then 'bank website list only (no code to match cases)'
                when coalesce(s.branch_type, 'branch') = 'office' then 'administrative office'
                when s.code is null then 'no branch code'
                when s.fam = any (v_inact) then 'client with no business in India in the last three months'
                else 'same branch code listed twice' end reason
      from msel s where not exists (select 1 from uni u where u.branch_uid = s.branch_uid))
  select jsonb_build_object(
    'status_month', v_m, 'unit_types', to_jsonb(v_types), 'filters', f,
    'summary', (select jsonb_build_object('total', count(*), 'active', count(*) filter (where st = 'active'), 'dormant', count(*) filter (where st = 'dormant'),
                       'never_active', count(*) filter (where st = 'never active'), 'no_team', count(*) filter (where loc is null),
                       'force1_cases_last_3_months', coalesce(sum(n3), 0), 'force1_cases_last_3_months_active_units', coalesce(sum(n3) filter (where st = 'active'), 0)) from ua),
    'by_unit_type', (select coalesce(jsonb_agg(jsonb_build_object('unit_type', ut, 'total', t, 'active', a, 'dormant', d, 'never_active', nv, 'no_team', nt, 'force1_cases_last_3_months', c3) order by t desc), '[]'::jsonb)
                       from (select ut, count(*) t, count(*) filter (where st = 'active') a, count(*) filter (where st = 'dormant') d, count(*) filter (where st = 'never active') nv, count(*) filter (where loc is null) nt, coalesce(sum(n3), 0) c3 from ua group by 1) q),
    'by_zone', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', coalesce(zg, 'No zone'), 'total', t, 'active', a, 'dormant', d, 'never_active', nv) order by t desc), '[]'::jsonb)
                  from (select zg, count(*) t, count(*) filter (where st = 'active') a, count(*) filter (where st = 'dormant') d, count(*) filter (where st = 'never active') nv from ua group by 1) q),
    'by_team', (select coalesce(jsonb_agg(jsonb_build_object('team_id', loc, 'team', coalesce(team, 'No team yet'), 'zone_group', zg, 'total', t, 'active', a, 'dormant', d, 'never_active', nv) order by t desc), '[]'::jsonb)
                  from (select loc, team, zg, count(*) t, count(*) filter (where st = 'active') a, count(*) filter (where st = 'dormant') d, count(*) filter (where st = 'never active') nv from ua group by 1, 2, 3) q),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_family', fam, 'total', t, 'active', a, 'dormant', d, 'never_active', nv) order by t desc), '[]'::jsonb)
                    from (select fam, count(*) t, count(*) filter (where st = 'active') a, count(*) filter (where st = 'dormant') d, count(*) filter (where st = 'never active') nv from ua group by 1) q),
    'in_master_not_counted', (select jsonb_build_object('total', count(*), 'by_reason', coalesce(jsonb_object_agg(reason, n), '{}'::jsonb))
                                from (select reason, count(*) n from outside group by 1) q),
    'units', case when v_list then (select coalesce(jsonb_agg(jsonb_build_object('client_family', fam, 'unit', branch_name, 'unit_type', ut, 'branch_code', branch_code, 'city', city, 'state', state,
                        'team', coalesce(team, 'No team yet'), 'zone_group', zg, 'status', st, 'last_case_month', last_m, 'cases_last_3_months', n3, 'cases_since_jan', n) order by o), '[]'::jsonb)
                      from (select ua.*, row_number() over (order by case st when 'active' then 0 when 'dormant' then 1 else 2 end, n3 desc, n desc, branch_name) o from ua) z where o <= v_lim) end,
    'units_total', (select count(*) from ua),
    'method', 'Units = verified client branches and processing centres that can be matched to Force1 cases by branch code (official bank lists; website-only lists and administrative offices left out; one row per branch code). '
      || 'Unit type from the name: Mini RACPC, RACPC (Mini RACPC not included), RASMECCC, SMECCC, SARC, RAC, RACC, other CPC, other processing centre, SME branch, branch; LHO (Local Head Office) only when asked for by name. '
      || 'Status from Force1 cases since Jan-2026, as of ' || to_char(v_m, 'Mon-YY') || ': active = a case in the last three months; dormant = cases earlier, none in the last three months; never active = no case since Jan-2026. '
      || 'Team = the team in the branch list, else the territory rule; "No team yet" when neither applies. in_master_not_counted lists rows of the same type that cannot be counted, with the reason.')
    into v_out;
  return v_out;
end $function$;

-- After applying: clear cached unit answers so the page and Ask Crux pick up the new rule
-- delete from bi.api_cache where fn = 'branch_units';
