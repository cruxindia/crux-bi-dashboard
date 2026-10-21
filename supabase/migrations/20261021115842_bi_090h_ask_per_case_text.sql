-- Applied to Supabase project via MCP on 20261021115842
-- bi_090h (21-Oct-2026): per-case collections answer states the per-case figures directly
do $do$
declare d text := pg_get_functiondef('bi.ask_h_collections(date,jsonb,text)'::regprocedure); o text := $x$  elsif focus = 'per_case' then
$x$;
begin
  if position('was invoiced (' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'per_case branch not found once'; end if;
  execute replace(d, o, o || $x$    ans := coalesce((select format('Reported revenue per case was ₹%s in %s (case-weighted tracker rate ₹%s). ', x->>'revenue_per_case', to_char((x->>'month')::date, 'Mon YYYY'), coalesce(x->>'tracker_rate', 'n/a'))
                     from jsonb_array_elements(a->'per_case') x order by (x->>'month')::date desc limit 1), '')
        || coalesce((select format('For %s invoices, ₹%s per case was invoiced (%s against the rate) and ₹%s per case has been collected so far. ', to_char((x->>'month')::date, 'Mon YYYY'),
                       x->>'invoiced_per_case', bi.fmt_p((x->>'billing_gap')::numeric), x->>'collected_per_case')
                     from jsonb_array_elements(a->'per_case') x where (x->>'month')::date = (date_trunc('month', (sn->>'as_of')::date) - interval '2 month')::date), '')
        || 'Reported revenue is computed from the tracker rate, so the useful check is the invoiced value per case against the rate.';
$x$);
end $do$;
