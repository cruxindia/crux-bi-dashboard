-- Applied to Supabase project via MCP on 20261014234605
-- bi_082b: evaluate the organic comparison once (OFFSET 0 stops the planner from repeating the call for each field used)
do $$
declare d text := pg_get_functiondef('bi.api_drill(date,jsonb,text,jsonb)'::regprocedure);
  old1 text := $o$(select bi.api_organic(m, f, 'total') o) x)$o$;
  new1 text := $n$(select bi.api_organic(m, f, 'total') o offset 0) x)$n$;
begin
  if position('offset 0' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, old1, ''))) / length(old1) <> 1 then raise exception 'anchor not unique'; end if;
  execute replace(d, old1, new1);
end $$;
