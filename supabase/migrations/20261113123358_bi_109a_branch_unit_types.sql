-- Applied to Supabase project via MCP on 20261113123358
-- wave 109a (13-Nov-2026, owner 17:52 IST: "counts of branches, RACPC, RAC, Mini RACPC etc are wrong and have gaps"; Ask Crux "asking for count, giving revenue")
-- One deterministic unit type for every client branch row, and one counting function used by the page and Ask Crux, so every count of RACPCs etc. agrees.

create or replace function bi.unit_type(p_name text, p_type text) returns text
language sql immutable parallel safe set search_path = pg_catalog as $f$
  select case
    when p_name ~* 'mini\s*-?\s*racpc' then 'Mini RACPC'
    when p_name ~* 'racpc' then 'RACPC'
    when p_name ~* 'rasme\s*c|rasmec' then 'RASMECCC'
    when p_name ~* 'smeccc|sme\s*ccc' then 'SMECCC'
    when p_name ~* '\msarc\M' then 'SARC'
    when p_name ~* '\mrac\M' then 'RAC'
    when p_name ~* '\mracc\M' then 'RACC'
    when p_name ~* 'cpc' then 'Other CPC'
    when coalesce(p_type, 'branch') = 'processing_centre' then 'Other processing centre'
    when coalesce(p_type, 'branch') = 'office' then 'Office'
    when p_name ~* '\mm?sme\M' then 'SME branch'
    else 'Branch' end $f$;
comment on function bi.unit_type(text, text) is 'Unit type of a client branch row from its name and branch_type: Mini RACPC, RACPC, RASMECCC, SMECCC, SARC, RAC, RACC, Other CPC, Other processing centre, Office, SME branch, Branch. The same rule is written out in view ai.branches (wave 109a).';

create or replace function bi.api_branch_units(f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' set statement_timeout to '40s' as $function$
declare v_m date; v_inact text[]; v_types text[]; v_list boolean := coalesce((p->>'list')::boolean, false);
        v_lim int := least(greatest(coalesce((p->>'limit')::int, 100), 1), 500); v_out jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
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
       and case when m.loc is not null then bi.loc_ok(m.loc, null, f)
                else (f - 'client_family') = '{}'::jsonb or (f->>'zone_group' is not null and f->>'location_id' is null and f->>'stakeholder' is null and m.bzg = f->>'zone_group') end),
  uni as materialized (
    select distinct on (s.fam, s.code) s.*
      from msel s
     where s.status = 'active' and coalesce(s.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')
       and coalesce(s.source_type, '') <> 'official_website' and coalesce(s.branch_type, 'branch') <> 'office'
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
                       'never_active', count(*) filter (where st = 'never active'), 'no_team', count(*) filter (where loc is null)) from ua),
    'by_unit_type', (select coalesce(jsonb_agg(jsonb_build_object('unit_type', ut, 'total', t, 'active', a, 'dormant', d, 'never_active', nv, 'no_team', nt) order by t desc), '[]'::jsonb)
                       from (select ut, count(*) t, count(*) filter (where st = 'active') a, count(*) filter (where st = 'dormant') d, count(*) filter (where st = 'never active') nv, count(*) filter (where loc is null) nt from ua group by 1) q),
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
      || 'Unit type from the name: Mini RACPC, RACPC (Mini RACPC not included), RASMECCC, SMECCC, SARC, RAC, RACC, other CPC, other processing centre, SME branch, branch. '
      || 'Status from Force1 cases since Jan-2026, as of ' || to_char(v_m, 'Mon-YY') || ': active = a case in the last three months; dormant = cases earlier, none in the last three months; never active = no case since Jan-2026. '
      || 'Team = the team in the branch list, else the territory rule; "No team yet" when neither applies. in_master_not_counted lists rows of the same type that cannot be counted, with the reason.')
    into v_out;
  return v_out;
end $function$;
comment on function bi.api_branch_units(jsonb, jsonb) is 'Counts of client units (RACPC, Mini RACPC, RASMECCC, RAC, ... , branches) by type, zone, team and client with active / dormant / never active, the rows not counted with their reason, and optionally the unit list. Same universe and status rules as api_branch_list. Wave 109a.';

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $f$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $f$;
select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  E'      when ''market_potential'' then bi.api_market_potential(m, f)\n',
  E'      when ''market_potential'' then bi.api_market_potential(m, f)\n      when ''branch_units'' then bi.api_branch_units(f, coalesce(p_args->''p'', ''{}''::jsonb))\n'], array[1]);

-- Ask Crux's branch view gets the same unit type (rule written out: the ai reader cannot call bi functions)
do $do$ declare d text := pg_get_viewdef('ai.branches'::regclass); n int;
begin
  n := (length(d) - length(replace(d, E'    pr.month AS status_month\n   FROM', ''))) / length(E'    pr.month AS status_month\n   FROM');
  if n <> 1 then raise exception 'ai.branches: anchor found % times', n; end if;
  d := replace(d, E'    pr.month AS status_month\n   FROM', E'    pr.month AS status_month,\n    CASE WHEN u.branch_name ~* ''mini\\s*-?\\s*racpc'' THEN ''Mini RACPC'' WHEN u.branch_name ~* ''racpc'' THEN ''RACPC'' WHEN u.branch_name ~* ''rasme\\s*c|rasmec'' THEN ''RASMECCC'''
    || E' WHEN u.branch_name ~* ''smeccc|sme\\s*ccc'' THEN ''SMECCC'' WHEN u.branch_name ~* ''\\msarc\\M'' THEN ''SARC'' WHEN u.branch_name ~* ''\\mrac\\M'' THEN ''RAC'' WHEN u.branch_name ~* ''\\mracc\\M'' THEN ''RACC'''
    || E' WHEN u.branch_name ~* ''cpc'' THEN ''Other CPC'' WHEN COALESCE(u.branch_type, ''branch'') = ''processing_centre'' THEN ''Other processing centre'' WHEN COALESCE(u.branch_type, ''branch'') = ''office'' THEN ''Office'''
    || E' WHEN u.branch_name ~* ''\\mm?sme\\M'' THEN ''SME branch'' ELSE ''Branch'' END AS unit_type\n   FROM');
  execute 'create or replace view ai.branches as ' || d;
end $do$;
