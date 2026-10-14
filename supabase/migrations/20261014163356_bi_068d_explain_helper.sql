-- Applied to Supabase project via MCP on 20261014163356
-- maintenance helper (postgres only): explain a function body for performance work
create or replace function bi._explain_fn(p_fn regprocedure, p_args text)
returns setof text language plpgsql security invoker set search_path = bi, public, extensions as $$
declare b text; r text;
begin
  select prosrc into b from pg_proc where oid = p_fn;
  b := replace(b, 'coalesce(f,', 'coalesce(' || p_args || '::jsonb,');
  b := regexp_replace(b, '\mf\M', p_args || '::jsonb', 'g');
  for r in execute 'explain (analyze, timing on, summary on, costs off) ' || b loop return next r; end loop;
end $$;
