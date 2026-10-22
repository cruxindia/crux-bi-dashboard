-- Applied to Supabase project via MCP on 20261022092455
-- organic_si() rounds each month's ratio before averaging, the refresh does not: allow 0.05 % per recomputed pair (totals keep 0.1 %)
do $do$
declare d text; o text := $o$    if abs(round(exp_, 1) - r.organic) > 0.2 then ok_pairs := false; end if;$o$;
        n text := $n$    if abs(round(exp_, 1) - r.organic) > greatest(0.2, 0.0005 * r.organic) then ok_pairs := false; end if;$n$;
begin
  d := pg_get_functiondef('bi.test_organic()'::regprocedure);
  if position(o in d) = 0 then raise exception 'fragment not found'; end if;
  execute replace(d, o, n);
end $do$;
