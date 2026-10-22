-- Applied to Supabase project via MCP on 20261022050524
-- bi_092n (22-Oct-2026): a pair whose comparison month was invoiced far above or below its expected minimum gets a confidence note
-- (found in review: a pair's large MoM fall came mostly from an unusually high comparison month — invoice timing).
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.api_growth_rev(date,jsonb,jsonb)'::regprocedure);
  o := $o$            union all select 'small base (₹' || to_char(round(r.m_a0), 'FM99,99,99,999') || ' last month)' where coalesce(r.m_a0, 0) > 0 and r.m_a0 < v_minr$o$;
  n := $n$            union all select to_char((v_bm - interval '1 month')::date, 'Mon-YY') || ' was invoiced at ' || round(100 * r.m_a0 / r.m_e0) || '% of expected — part of the change may be invoice timing'
              where r.m_e0 > 0 and r.m_a0 > 0 and (r.m_a0 / r.m_e0 < 0.5 or r.m_a0 / r.m_e0 > 2)
            union all select 'small base (₹' || to_char(round(r.m_a0), 'FM99,99,99,999') || ' last month)' where coalesce(r.m_a0, 0) > 0 and r.m_a0 < v_minr$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'confidence fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;
insert into bi.audit_log (actor, action, entity, entity_key, detail)
values ('claude-migration', 'api_change', 'api_growth_rev', 'bi_092m_092n', jsonb_build_object('change', 'one billed-per-case basis for both sides of a revenue comparison; comparison-month invoicing note'));
