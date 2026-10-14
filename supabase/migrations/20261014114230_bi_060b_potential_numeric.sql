-- Applied to Supabase project via MCP on 20261014114230
do $do$
declare d text := pg_get_functiondef('bi.api_potential(date,jsonb,text,text)'::regprocedure);
begin
  if position('percentile_cont(0.5) within group (order by mlt)::numeric' in d) = 0 then
    d := replace(d, 'percentile_cont(0.5) within group (order by mlt) med', 'percentile_cont(0.5) within group (order by mlt)::numeric med');
    execute d;
  end if;
end $do$;
