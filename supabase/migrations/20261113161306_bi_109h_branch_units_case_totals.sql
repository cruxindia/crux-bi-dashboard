-- Applied to Supabase project via MCP on 20261113161306
-- wave 109h: unit counts also carry the Force1 cases of those units in the last 3 months (the only business that exists per unit; the tracker is per team × client)
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
  E'''never_active'', count(*) filter (where st = ''never active''), ''no_team'', count(*) filter (where loc is null)) from ua),',
  E'''never_active'', count(*) filter (where st = ''never active''), ''no_team'', count(*) filter (where loc is null),\n                       ''force1_cases_last_3_months'', coalesce(sum(n3), 0), ''force1_cases_last_3_months_active_units'', coalesce(sum(n3) filter (where st = ''active''), 0)) from ua),',
  E'''no_team'', nt) order by t desc)',
  E'''no_team'', nt, ''force1_cases_last_3_months'', c3) order by t desc)',
  E'count(*) filter (where loc is null) nt from ua group by 1) q),',
  E'count(*) filter (where loc is null) nt, coalesce(sum(n3), 0) c3 from ua group by 1) q),'], array[1, 1, 1]);
