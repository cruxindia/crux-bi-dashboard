-- Applied to Supabase project via MCP on 20261112104729
-- wave 107c: potential per team × client family (compact rows [location_id, client_family, potential, current, active branches, branches])
-- so the Business tracker can show potential next to each row (owner 12-Nov-2026: potential "everywhere", D317).
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
select pg_temp.patch('bi.api_market_potential(date,jsonb)'::regprocedure, array[
  '''top'', (select coalesce(jsonb_agg(jsonb_build_object(''group'', grp,',
  '''by_pair'', (select coalesce(jsonb_agg(jsonb_build_array(location_id, client_family, round(pot), round(cur), act, br) order by location_id, client_family), ''[]''::jsonb)'
  || ' from (select location_id, client_family, coalesce(sum(revenue), 0) pot, coalesce(sum(revenue) filter (where grp = ''current''), 0) cur,'
  || ' coalesce(sum(branches) filter (where grp = ''current''), 0) act, coalesce(sum(branches) filter (where grp <> ''recover''), 0) br'
  || ' from c where location_id is not null group by 1, 2 having sum(revenue) > 0) q),'
  || E'\n  ' || '''top'', (select coalesce(jsonb_agg(jsonb_build_object(''group'', grp,'], array[1]);

