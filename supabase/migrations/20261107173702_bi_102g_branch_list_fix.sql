-- Applied to Supabase project via MCP on 20261107173702
-- wave 102g: api_branch_list result variable renamed (it clashed with the rate column "r")
do $m$
declare d text := pg_get_functiondef('bi.api_branch_list(jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, 'v_off int := greatest(coalesce((p->>''offset'')::int, 0), 0); r jsonb;', 'v_off int := greatest(coalesce((p->>''offset'')::int, 0), 0); v_out jsonb;');
  d := replace(d, E'    into r;\n  return r;', E'    into v_out;\n  return v_out;');
  d := replace(d, 'frate as (select fam, sum(r * 1) / count(*) r from rate group by 1)', 'frate as (select rate.fam, avg(rate.r) r from rate group by 1)');
  if position('v_out' in d) = 0 or position('return v_out' in d) = 0 then raise exception 'anchor not found'; end if;
  execute d;
end $m$;
