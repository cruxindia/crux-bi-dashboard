-- Applied to Supabase project via MCP on 20261113160652
-- wave 109f (13-Nov-2026): unit counts took 9 s for all India. bi.unit_type is now inlinable (no SET clause: it only uses built-in regex operators),
-- and the location check is skipped when no location filter is set.
create or replace function bi.unit_type(p_name text, p_type text) returns text language sql immutable parallel safe as $f$
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
    when coalesce(p_type, 'branch') = 'office' then 'Office'
    when p_name ~* '\mm?sme\M' then 'SME branch'
    else 'Branch' end $f$;

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
select pg_temp.patch('bi.api_branch_units(jsonb,jsonb)'::regprocedure, array[
  E'       and case when m.loc is not null then bi.loc_ok(m.loc, null, f)',
  E'       and case when (f - ''client_family'') = ''{}''::jsonb then true when m.loc is not null then bi.loc_ok(m.loc, null, f)'], array[1]);
