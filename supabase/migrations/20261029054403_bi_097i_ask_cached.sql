-- Applied to Supabase project via MCP on 20261029054403
-- bi_097i (29-Oct-2026): Ask Crux answers for open cases and data health took 30–45 s because the handlers computed the operations
-- and meta figures afresh (8–10 s each when the data is not in memory). They now read the same cached results the dashboard uses
-- (public.bi_call, invalidated by every data change), so the answer always equals the page.
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.ask_h_ops(date,jsonb,text)'::regprocedure);
  o := $o$o := bi.api_ops(m, f);$o$; n := $n$o := public.bi_call('ops', jsonb_build_object('month', m, 'filters', f));$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'ask_h_ops fragment not found exactly once'; end if;
  execute replace(d, o, n);
  d := pg_get_functiondef('bi.ask_h_health(date,jsonb)'::regprocedure);
  o := $o$mt := bi.api_meta()->'freshness';$o$; n := $n$mt := public.bi_call('meta', '{}'::jsonb)->'freshness';$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'ask_h_health fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;
