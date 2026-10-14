-- Applied to Supabase project via MCP on 20261014115509
do $do$
declare d text := pg_get_functiondef('bi.test_organic()'::regprocedure);
begin
  d := replace(d, 'w2 := bi.workdays((m - interval ''2 months'')::date, (m - interval ''1 month - 1 day'')::date)', 'w2 := bi.workdays((m - interval ''2 months'')::date, (m - interval ''1 month'' - interval ''1 day'')::date)');
  d := replace(d, 'w3 := bi.workdays((m - interval ''3 months'')::date, (m - interval ''2 months - 1 day'')::date)', 'w3 := bi.workdays((m - interval ''3 months'')::date, (m - interval ''2 months'' - interval ''1 day'')::date)');
  if position('interval ''1 month'' - interval ''1 day''' in d) = 0 then raise exception 'patch failed'; end if;
  execute d;
end $do$;
