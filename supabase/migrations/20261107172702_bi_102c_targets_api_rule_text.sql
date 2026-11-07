-- Applied to Supabase project via MCP on 20261107172702
-- wave 102c: api_targets shows the never-below-previous rule, the strong-signal months and the previous (reference) target
do $m$
declare d text := pg_get_functiondef('bi.api_targets(date, jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, 'bi.plan_cells() x', 'bi.plan_cells2() x');
  d := replace(d, $a$'opportunity', round(sum(greatest(x.organic - x.pace0, 0))))$a$, $a$'opportunity', round(sum(greatest(x.organic - x.pace0, 0))), 'previous_target', round(sum(x.t0)))$a$);
  d := replace(d, $a$'source', v_src, $a$, $a$'source', v_src, 'signals', (select coalesce(jsonb_agg(jsonb_build_object('month', s.month, 'allowed_drop', s.allowed_drop, 'falls', s.falls) order by s.month), '[]'::jsonb)
                    from bi.plan_signals((v_ref + interval '1 month')::date, (v_ref + interval '24 months')::date) s where s.strong), $a$);
  d := replace(d, $a$'stretch', round(target / nullif(pace, 0) - 1, 4))$a$, $a$'stretch', round(target / nullif(pace, 0) - 1, 4), 'strong_signal', coalesce((select s.strong from bi.plan_signals(month, month) s), false))$a$);
  d := replace(d, $a$case when coalesce(v_params->>'basis', 'seasonal') = 'nominal' then 'in rupees.' else 'after seasonality and working days (rupee targets follow the business''s usual monthly rhythm).' end$a$,
                  $a$'on the seasonally adjusted level.'$a$);
  d := replace(d, $a$' Each team x client gets its pace plus its share of the captured opportunity$a$,
                  $a$' No month''s target is below the previous month''s target + ' || round(coalesce((v_params->>'gmin')::numeric, 0.02) * 100, 1) || '% for the same team x client (the first month starts from the ' || to_char(v_ref, 'Mon-YY') || ' tracker target, or the current business when higher), except a month that fell 5% or more against the month before in every year on record (strong seasonal signal: ' || coalesce((select string_agg(to_char(s.month, 'Mon-YY'), ', ' order by s.month) from bi.plan_signals((v_ref + interval '1 month')::date, (v_ref + interval '12 months')::date) s where s.strong), 'none') || '), which may fall by at most the smallest fall on record. Clients with no tracker cases anywhere in India in the last three months are excluded. Each team x client gets its pace plus its share of the captured opportunity$a$);
  if position('previous_target' in d) = 0 or position('strong_signal' in d) = 0 or position('''signals''' in d) = 0 or position('never' in d) = 0 and position('No month' in d) = 0 or position('plan_cells()' in d) > 0 then
    raise exception 'api_targets: an anchor was not found';
  end if;
  execute d;
end $m$;
