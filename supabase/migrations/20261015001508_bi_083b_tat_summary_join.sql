-- Applied to Supabase project via MCP on 20261015001508
do $$
declare d text := pg_get_functiondef('bi.tat_summary(date,jsonb,text)'::regprocedure);
  a text := 'from ca full join pa on pa.id is not distinct from ca.id';
  n text := $n$from ca full join pa on coalesce(pa.id, '~none') = coalesce(ca.id, '~none')$n$;
begin
  if position(a in d) = 0 then return; end if;
  execute replace(d, a, n);
end $$;
