-- Applied to Supabase project via MCP on 20261107173713
-- wave 102h: peer medians as numeric (percentile_cont returns double precision)
do $m$
declare d text := pg_get_functiondef('bi.api_branch_list(jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, 'within group (order by n3 / 3.0) med', 'within group (order by n3 / 3.0)::numeric med');
  if d = o then raise exception 'anchor not found'; end if;
  execute d;
end $m$;
