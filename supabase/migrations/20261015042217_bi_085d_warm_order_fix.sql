-- Applied to Supabase project via MCP on 20261015042217
do $$
declare d text := pg_get_functiondef('bi.warm_drill_cache(int)'::regprocedure);
  a text := $a$for c in select '{}'::jsonb f, 'zone' lvl, 0 o$a$;
  n text := $n$for c in select * from (select '{}'::jsonb f, 'zone' lvl, 0 o$n$;
  a2 text := $a$where exists (select 1 from bi.location l where l.zone_group = z.code)
           order by o, f::text loop$a$;
  n2 text := $n$where exists (select 1 from bi.location l where l.zone_group = z.code)) q
           order by q.o, q.f::text loop$n$;
begin
  if position('from (select ''{}''::jsonb f' in d) > 0 then return; end if;
  if position(a in d) = 0 or position(a2 in d) = 0 then raise exception 'anchors missing'; end if;
  execute replace(replace(d, a, n), a2, n2);
end $$;
