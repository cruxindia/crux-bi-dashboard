-- Applied to Supabase project via MCP on 20261022094017
-- bi_093g (22-Oct-2026): cases growth method text describes the MoM / QoQ / YoY organic blend (and the branch manager next to the owner)
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth(date,jsonb,jsonb)'::regprocedure);
  o := array[$o0$weighted recent three months per working day, seasonally adjusted.$o0$,
             $o1$'owner', 'Owner = the stakeholder mapped to the location for the period (effective-dated). It is mapped responsibility, not proof of who caused a change.',$o1$];
  n := array[$n0$50% last month (MoM), 40% last quarter with its trend (QoQ) and 10% the location × client''s own pattern for the same month last year (YoY), per working day and seasonally adjusted.$n0$,
             $n1$'owner', 'Owner = the stakeholder mapped to the location for the period (effective-dated). Branch manager = the manager assigned to the location, or to this client at the location, for the period (Admin → Master data & mapping). Both are mapped responsibility, not proof of who caused a change.',$n1$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_growth fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
