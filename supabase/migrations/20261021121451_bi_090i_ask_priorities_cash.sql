-- Applied to Supabase project via MCP on 20261021121451
-- bi_090i (21-Oct-2026): "most important issues" also states the cash position (listed separately: rupees are not ranked against cases)
do $do$
declare d text := pg_get_functiondef('bi.ask_h_priorities(date,jsonb,integer)'::regprocedure); i int;
  fr text[] := array[
    $x$cm date; pm date; items jsonb; ans text; mt jsonb; oc record;$x$,
    $x$limit greatest(least(n, 8), 1)) z;$x$,
    $x$(select string_agg(format('(%s) %s', o2, x->>'issue'), '; ' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2)));$x$,
    $x$'rows', (select jsonb_agg(jsonb_build_array(o2::text, x->>'issue', x->>'finding') order by o2) from jsonb_array_elements(items) with ordinality t(x, o2))),$x$,
    $x$'actions', (select jsonb_agg(x->'action' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2)),$x$,
    $x$Collections are not included until the collection files are integrated.$x$,
    $x$'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'Where is TAT increasing?', 'What data issues need attention?'),$x$];
  tob text[] := array[
    $x$cm date; pm date; items jsonb; ans text; mt jsonb; oc record; ca jsonb; cash text;$x$,
    $x$limit greatest(least(n, 8), 1)) z;
  ca := public.bi_call('collections', jsonb_build_object('month', m, 'filters', f));
  if coalesce((ca->>'available')::boolean, false) and coalesce((ca->'kpi'->>'over_180')::numeric, 0) > 0 then
    cash := format('Cash: %s of %s outstanding is over 180 days (%s) as at %s.', bi.fmt_inr((ca->'kpi'->>'over_180')::numeric), bi.fmt_inr((ca->'kpi'->>'outstanding')::numeric),
                   bi.fmt_p((ca->'kpi'->>'over_180_share')::numeric), to_char((ca->'snapshot'->>'as_of')::date, 'DD-Mon-YYYY'));
  end if;$x$,
    $x$(select string_agg(format('(%s) %s', o2, x->>'issue'), '; ' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2)));
  ans := ans || coalesce(' ' || cash, '');$x$,
    $x$'rows', (select jsonb_agg(jsonb_build_array(o2::text, x->>'issue', x->>'finding') order by o2) from jsonb_array_elements(items) with ordinality t(x, o2))
             || case when cash is not null then jsonb_build_array(jsonb_build_array('Cash', 'Old receivables', cash)) else '[]'::jsonb end),$x$,
    $x$'actions', (select jsonb_agg(x->'action' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2))
                || case when cash is not null then jsonb_build_array(bi.ask_act('High', 'Review invoices older than 180 days with the locations that hold most of them', cash, 'Finance + location heads', 'Recovers the oldest receivables first')) else '[]'::jsonb end,$x$,
    $x$The cash position is listed separately because it is measured in rupees, not cases.$x$,
    $x$'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'Where is TAT increasing?', 'Which locations have the oldest outstanding?', 'What data issues need attention?'),$x$];
begin
  if position('ca jsonb; cash text' in d) > 0 then return; end if;
  for i in 1 .. array_length(fr, 1) loop
    if (length(d) - length(replace(d, fr[i], ''))) / length(fr[i]) <> 1 then raise exception 'fragment % not found once', i; end if;
    d := replace(d, fr[i], tob[i]);
  end loop;
  execute d;
end $do$;
