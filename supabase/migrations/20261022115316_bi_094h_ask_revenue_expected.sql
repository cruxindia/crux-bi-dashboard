-- Applied to Supabase project via MCP on 20261022115316
-- bi_094h (22-Oct-2026): Ask Crux revenue-growth answers follow the business-first rule — "revenue" means expected revenue (Zonal Tracker
-- cases × rate, current month to date by default); billed revenue (invoices, finance) only when billed / invoiced / billing is asked.
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.ask_h_revenue(date,jsonb,text)'::regprocedure);
  o := array[
$o1$conf text := 'high'; ord text; fk text; u text;$o1$,
$o2$  rev := not (q ~ '\mcases?\M' and q !~ '(revenue|billed|invoic|rupee|₹)');$o2$,
$o3$              when q ~ '(\mmtd\M|month to date)' and not rev then 'mtd'
              else 'mom' end;$o3$,
$o4$case when rev then jsonb_build_object('measure', 'revenue') else '{}'::jsonb end);$o4$,
$o5$  else
    fk := 'n';$o5$,
$o6$'measure', case when rev then 'revenue' else 'cases' end$o6$,
$o7$' Expected minimum revenue (tracker) %s; billed per case %s (expected %s).'$o7$];
  n := array[
$n1$conf text := 'high'; ord text; fk text; u text; xp boolean;$n1$,
$n2$  rev := q ~ '(billed|invoic|billing|actual revenue)' and q !~ '\mcases?\M';
  xp := not rev and not (q ~ '\mcases?\M' and q !~ '(revenue|rupee|₹)');$n2$,
$n3$              when q ~ '(\mmtd\M|month to date|this month|so far)' and not rev then 'mtd'
              when not rev and q !~ '(last month|previous month|\mmom\M|month on month)' then 'mtd'
              else 'mom' end;$n3$,
$n4$case when rev then jsonb_build_object('measure', 'revenue') when xp then jsonb_build_object('measure', 'expected') else '{}'::jsonb end);$n4$,
$n5$  elsif xp then
    fk := 'inr';
    ans := ans || format('Expected revenue (business: Zonal Tracker cases × rate) %s: %s vs %s in %s — %s (%s).', lab_c, bi.fmt_inr((c->'current'->>'cases')::numeric),
                         bi.fmt_inr((c->'previous'->>'cases')::numeric), lab_p, bi.fmt_sinr((c->>'cases_change')::numeric), bi.fmt_sp((c->>'cases_pct')::numeric));
    if o->>'organic_current' is not null then
      ans := ans || format(' Organic expectation %s vs %s (organic growth %s); growth beyond organic %s.', bi.fmt_inr((o->>'organic_current')::numeric),
                           bi.fmt_inr((o->>'organic_previous')::numeric), bi.fmt_sinr((o->>'organic_growth')::numeric), bi.fmt_sinr((o->>'beyond_organic')::numeric));
    end if;
    ans := ans || ' Billed revenue and collections are the finance side — ask about billed revenue or collections for those.';
    nums := jsonb_build_array(jsonb_build_object('metric', 'Expected revenue ' || lab_c, 'value', c->'current'->'cases'), jsonb_build_object('metric', 'Expected revenue ' || lab_p, 'value', c->'previous'->'cases'),
                              jsonb_build_object('metric', 'Growth beyond organic', 'value', o->'beyond_organic'));
    lim := lim || 'Expected revenue is tracker cases × agreed rate, not invoiced revenue; organic is an estimate (blend of last month, last quarter with its trend and the same month last year), not proof of cause.';
  else
    fk := 'n';$n5$,
$n6$'measure', case when rev then 'revenue' when xp then 'expected_revenue' else 'cases' end$n6$,
$n7$' Expected revenue (tracker) %s; billed per case %s (expected %s).'$n7$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'ask_h_revenue fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
