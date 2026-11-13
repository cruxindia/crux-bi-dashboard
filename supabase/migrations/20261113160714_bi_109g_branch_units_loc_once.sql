-- Applied to Supabase project via MCP on 20261113160714
-- wave 109g: the location filter is resolved once (38 locations) instead of once per branch row
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
  E'declare v_m date; v_inact text[]; v_types text[];',
  E'declare v_m date; v_inact text[]; v_types text[]; v_locs int[];',
  E'  f := coalesce(f, ''{}''::jsonb);',
  E'  f := coalesce(f, ''{}''::jsonb);\n  v_locs := array(select l.id from bi.location l where bi.loc_ok(l.id, null, f));   -- wave 109g',
  E'when m.loc is not null then bi.loc_ok(m.loc, null, f)',
  E'when m.loc is not null then m.loc = any (v_locs)'], array[1, 1, 1]);
