-- Applied to Supabase project via MCP on 20261014115246
do $do$
declare d text := pg_get_functiondef('bi.api_potential(date,jsonb,text,text)'::regprocedure);
begin
  if position('s.wk <= k' in d) > 0 then
    d := replace(d, 'where s.mon < m and s.wk <= k group by 1, 2', 'where s.mon < m and s.wk = k group by 1, 2');
    execute d;
  end if;
end $do$;
insert into bi.audit_log(actor,action,entity,detail) values ('migration','cache_bump','api_cache','{"reason":"bi_062b"}');
