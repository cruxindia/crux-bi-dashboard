-- Applied to Supabase project via MCP on 20261022115353
-- bi_094h2 (22-Oct-2026): Ask revenue findings show the branch manager before the stakeholder; "up to <date>" wording for month-to-date comparisons
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.ask_h_revenue(date,jsonb,text)'::regprocedure);
  o := array[$o1$'Beyond organic', 'Stakeholder (mapped)', 'Branch manager (mapped)'),$o1$,
             $o2$coalesce(p->>'owner', 'not mapped'), coalesce(p->>'branch_manager', 'not mapped')) order by z.rn), '[]')),$o2$,
             $o3$'Expected revenue (business: Zonal Tracker cases × rate) %s: %s vs %s in %s — %s (%s).', lab_c,$o3$];
  n := array[$n1$'Beyond organic', 'Branch manager (mapped)', 'Stakeholder (mapped)'),$n1$,
             $n2$coalesce(p->>'branch_manager', 'not mapped'), coalesce(p->>'owner', 'not mapped')) order by z.rn), '[]')),$n2$,
             $n3$'Expected revenue (business: Zonal Tracker cases × rate) %s: %s vs %s %s — %s (%s).', replace(lab_c, 'to ', 'up to '),$n3$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'ask_h_revenue fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  -- the previous-period label follows the same wording
  d := replace(d, $q$bi.fmt_inr((c->'previous'->>'cases')::numeric), lab_p, bi.fmt_sinr((c->>'cases_change')::numeric)$q$,
                  $q$bi.fmt_inr((c->'previous'->>'cases')::numeric), case when lab_p like 'to %' then 'up ' || lab_p else 'in ' || lab_p end, bi.fmt_sinr((c->>'cases_change')::numeric)$q$);
  execute d;
end $do$;
