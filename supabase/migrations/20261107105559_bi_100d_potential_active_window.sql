-- Applied to Supabase project via MCP on 20261107105559
-- Wave 100: an "active" Force1 branch = at least one case in the last three months (incl. the current month); dormant = cases
-- since Jan-2026 but none in the last three months. Peer medians use the same active set (more conservative than "case in the
-- last two months", which picked only the busier branches: SBI median 3.3 vs 2.3 cases a month).
do $m$
declare d text := pg_get_functiondef('bi.potential_refresh()'::regprocedure); n int;
begin
  n := (length(d) - length(replace(d, 'last_m >= (v_m - interval ''1 month'')::date', ''))) / length('last_m >= (v_m - interval ''1 month'')::date');
  if n <> 4 then raise exception 'expected 4 active filters, found %', n; end if;
  d := replace(d, 'last_m >= (v_m - interval ''1 month'')::date', 'last_m >= (v_m - interval ''2 months'')::date');
  if position('a.last_m < (v_m - interval ''1 month'')::date' in d) = 0 then raise exception 'dormant filter not found'; end if;
  d := replace(d, 'a.last_m < (v_m - interval ''1 month'')::date', 'a.last_m < (v_m - interval ''2 months'')::date');
  execute d;
end $m$;
