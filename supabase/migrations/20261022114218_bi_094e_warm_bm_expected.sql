-- Applied to Supabase project via MCP on 20261022114218
-- bi_094e (22-Oct-2026): the warm-up job also pre-computes the Pan India branch-manager panel and the expected-revenue growth view (the new defaults)
do $do$
declare d text;
        o text := $o$      perform public.bi_call('growth', jsonb_build_object('month', m, 'filters', '{}'::jsonb, 'measure', 'revenue')); n := n + 1;$o$;
        n text := $n$      perform public.bi_call('growth', jsonb_build_object('month', m, 'filters', '{}'::jsonb, 'measure', 'revenue')); n := n + 1;
      perform public.bi_call('growth', jsonb_build_object('month', m, 'filters', '{}'::jsonb, 'measure', 'expected')); n := n + 1;
      perform public.bi_call('bm', jsonb_build_object('month', m, 'filters', '{}'::jsonb)); n := n + 1;$n$;
begin
  d := pg_get_functiondef('bi.warm_drill_cache(integer)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'warm_drill_cache fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;
