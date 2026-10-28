-- Applied to Supabase project via MCP on 20261028124859
-- bi_095g: a request no longer waits for the background warm-up transaction that is writing the same cache key (it timed out with HTTP 500 right after
-- every data change). The answer is returned uncached instead; the warm-up stores it.
do $do$
declare d text; a int; b int; o text;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  o := 'insert into bi.api_cache(k, v, version) values (v_key, r, v_ver)';
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_call cache insert not found exactly once'; end if;
  a := position(o in d); b := a + position(';' in substr(d, a));
  execute substr(d, 1, a - 1) || 'begin perform set_config(''lock_timeout'', ''1500ms'', true); ' || substr(d, a, b - a) ||
          ' exception when lock_not_available then null; end; perform set_config(''lock_timeout'', ''0'', true);' || substr(d, b);
end $do$;
