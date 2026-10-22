-- Applied to Supabase project via MCP on 20261022041957
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth_rev(date,jsonb,jsonb)'::regprocedure);
  o := array[$o0$select array_agg(distinct g::date) into v_ms from generate_series(v_from, v_m, interval '1 month') g;$o0$,
$o1$,
             'organic_expected_current', round(t.oe1c), 'organic_expected_previous', round(t.oe0c)))
      end j$o1$,
$o2$  split as materialized ($o2$,
$o3$    'organic', jsonb_build_object('validation', bi.fin_org_validation(f)),$o3$,
$o4$        'periods', r.per,
        'mom', r.per->'mom', 'qoq', r.per->'qoq', 'qtd', r.per->'qtd', 'yoy', r.per->'yoy',
        'share_of_net',$o4$,
$o5$                       'note', case when t.st = 'partial' then 'Invoices for ' || to_char(t.mon, 'Mon-YYYY') || ' are still being added: the snapshot (' || to_char((b->>'as_of')::date, 'DD-Mon') ||
                                    ') is less than ' || (b->>'complete_days') || ' days after the month end.' else 'Month not yet billed.' end) order by t.mon), '[]')$o5$,
$o6$    'pairs', (select coalesce(jsonb_agg(jsonb_build_object(
        'unit_id', r.unit_id,$o6$];
  n := array[$n0$select array_agg(distinct g::date) into v_ms from generate_series(greatest(v_from, v_fc), v_m, interval '1 month') g;$n0$,
$n1$))
      end j$n1$,
$n2$  val as materialized (
    select o.month mon, sum(x.billed) act, sum(x.billed) filter (where o.org_billed is not null) act_cov, sum(o.org_billed) org,
           sum(abs(coalesce(x.billed, 0) - o.org_billed)) filter (where o.org_billed is not null) err,
           count(*) filter (where o.basis = 'pair') np, count(*) filter (where o.basis = 'family') nf
    from ox o join fx x on x.unit_id = o.unit_id and x.fam = o.fam and x.month = o.month and x.unit_ok
    where o.month between (v_fc + interval '2 months')::date and v_lc group by 1),
  split as materialized ($n2$,
$n3$    'organic', jsonb_build_object('validation', (select jsonb_build_object('months', count(*), 'from', min(mon), 'to', max(mon),
        'pan_mape', round(avg(abs(act_cov - org) / nullif(act_cov, 0)), 4), 'pair_wape', round(sum(err) / nullif(sum(act_cov), 0), 4),
        'bias', round(sum(org - act_cov) / nullif(sum(act_cov), 0), 4), 'coverage', round(sum(act_cov) / nullif(sum(act), 0), 4),
        'by_month', jsonb_agg(jsonb_build_object('month', mon, 'actual', round(act_cov), 'organic', round(org), 'error_pct', round((act_cov - org) / nullif(act_cov, 0), 4),
                                                 'pair_basis', np, 'family_basis', nf) order by mon)) from val where act_cov > 0)),$n3$,
$n4$        'share_of_net',$n4$,
$n5$                       'note', case when (t.mon + interval '1 month' - interval '1 day')::date > (b->>'as_of')::date then to_char(t.mon, 'Mon-YYYY') || ' had not ended at the snapshot date (' || to_char((b->>'as_of')::date, 'DD-Mon-YYYY') || '); its invoices are raised at month end.'
                                    when t.st = 'partial' then 'Invoices for ' || to_char(t.mon, 'Mon-YYYY') || ' are still being added: the snapshot (' || to_char((b->>'as_of')::date, 'DD-Mon') ||
                                    ') is less than ' || (b->>'complete_days') || ' days after the month end.' else 'Month not yet billed.' end) order by t.mon), '[]')$n5$,
$n6$    'pairs', (select coalesce(jsonb_agg(coalesce(r.per, '{}'::jsonb) || jsonb_build_object(
        'unit_id', r.unit_id,$n6$];
  for i in 1 .. array_length(o, 1) loop
    if position(o[i] in d) = 0 then raise exception 'patch fragment % not found', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;

