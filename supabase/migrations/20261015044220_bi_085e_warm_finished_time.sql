-- Applied to Supabase project via MCP on 20261015044220
do $$
declare d text := pg_get_functiondef('bi.warm_drill_cache(int)'::regprocedure);
  a text := 'values (1, v_ver, t0, case when ok then now() end,';
  n text := 'values (1, v_ver, t0, case when ok then clock_timestamp() end,';
begin
  if position(a in d) = 0 then return; end if;
  execute replace(d, a, n);
end $$;
