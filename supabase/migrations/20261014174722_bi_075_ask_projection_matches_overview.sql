-- Applied to Supabase project via MCP on 20261014174722
-- bi_075: Ask Crux overview answer quotes the same month-end projection as the Overview tile (historical curve),
-- with the run-rate shown alongside; previously it quoted only the run-rate, which differed from the dashboard.
do $$
declare d text := pg_get_functiondef('public.bi_ask(text,jsonb,uuid)'::regprocedure);
        o text := $o$txt := txt || format(' Target %s, achievement %s%%, projected month-end %s.', x->>'target_cases', round((x->>'achievement')::numeric*100,1), coalesce(x->'forecast'->>'run_rate_projection','n/a'));$o$;
        n text := $n$txt := txt || format(' Target %s, achievement %s%%, projected month-end %s (historical curve, as on the Overview; run-rate %s).', x->>'target_cases', round((x->>'achievement')::numeric*100,1), coalesce(x->'forecast'->>'curve_projection', x->'forecast'->>'run_rate_projection', 'n/a'), coalesce(x->'forecast'->>'run_rate_projection','n/a'));$n$;
begin
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'expected exactly one occurrence'; end if;
  execute replace(d, o, n);
end $$;
insert into bi.audit_log(actor, action, entity, detail) values ('migration bi_075', 'definition_change', 'bi_ask', '{"note":"overview answer uses the Overview projection"}');
