-- Applied to Supabase project via MCP on 20261022114410
-- bi_094b6 (22-Oct-2026): effort % in the branch-manager panel is measured in expected revenue (same basis as the ₹ effort beside it), over rows with an organic value
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  o := array[$o1$sum(b.r1) filter (where b.otd is not null) r1c$o1$,
             $o2$'effort_pct', round((sum(c1c) - sum(otd)) / nullif(sum(otd), 0), 4),$o2$,
             $o3$'effort_pct', round((g.c1c - g.otd) / nullif(g.otd, 0), 4),$o3$,
             $o4$'effort_pct', round((sum(b.c1) filter (where b.otd is not null) - sum(b.otd)) / nullif(sum(b.otd), 0), 4),$o4$];
  n := array[$n1$sum(b.r1) filter (where b.ortd is not null) r1c$n1$,
             $n2$'effort_pct', round((sum(r1c) - sum(ortd)) / nullif(sum(ortd), 0), 4), 'effort_cases_pct', round((sum(c1c) - sum(otd)) / nullif(sum(otd), 0), 4),$n2$,
             $n3$'effort_pct', round((g.r1c - g.ortd) / nullif(g.ortd, 0), 4), 'effort_cases_pct', round((g.c1c - g.otd) / nullif(g.otd, 0), 4),$n3$,
             $n4$'effort_pct', round((sum(b.r1) filter (where b.ortd is not null) - sum(b.ortd)) / nullif(sum(b.ortd), 0), 4),$n4$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_bm fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
