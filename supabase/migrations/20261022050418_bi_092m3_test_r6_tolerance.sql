-- Applied to Supabase project via MCP on 20261022050418
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.test_growth_rev(date)'::regprocedure);
  o := $o$  passed := abs(round(x) - (c->'organic'->>'organic_current')::numeric) <= 1 and abs(round(y) - (c->'organic'->>'organic_previous')::numeric) <= 1;
  detail := format('organic %s vs %s', round(x), round(y)); return next;$o$;
  -- the earlier side is rebuilt from fin_org_rev's published per-case columns, which are rounded to 2 decimals: allow 0.01 %
  n := $n$  passed := abs(round(x) - (c->'organic'->>'organic_current')::numeric) <= 1 and abs(round(y) - (c->'organic'->>'organic_previous')::numeric) <= 0.0001 * y;
  detail := format('current %s vs card %s; earlier %s vs card %s (per-case basis rounded to 2 decimals in the check)', round(x), c->'organic'->>'organic_current', round(y), c->'organic'->>'organic_previous'); return next;$n$;
  if position(o in d) = 0 then raise exception 'R6 pass fragment not found'; end if;
  execute replace(d, o, n);
end $do$;
