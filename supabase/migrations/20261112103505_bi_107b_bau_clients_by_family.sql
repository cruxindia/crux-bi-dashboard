-- Applied to Supabase project via MCP on 20261112103505
-- wave 107b: business-as-usual "clients" counted by client family, the same unit as the potential (BOM MSME PRE is part of BOM) — D317.
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
select pg_temp.patch('bi.api_organic(date,jsonb,text,text)'::regprocedure, array[
  'coalesce(c.summary_under, o.client_code) client_grp,', 'coalesce(c.summary_under, o.client_code) client_grp, coalesce(c.family, c.summary_under, o.client_code) client_fam,',
  'count(distinct client_grp) filter (where org > 0 or actual > 0) n_cl', 'count(distinct client_fam) filter (where org > 0 or actual > 0) n_cl'], array[1, 2]);

