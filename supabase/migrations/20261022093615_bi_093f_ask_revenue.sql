-- Applied to Supabase project via MCP on 20261022093615
-- bi_093f (22-Oct-2026): Ask Crux answers revenue growth and organic questions (MoM / QTD / QoQ / YoY / YTD) from the same growth endpoints as the dashboard.
-- Fix for: "billed" questions were routed to the outstanding answer and "organic" questions got a cases-vs-last-month answer.
-- Names (stakeholders, branch managers) appear only in the findings table, which is never sent to the AI provider.
create or replace function bi.fmt_sinr(x numeric) returns text language sql immutable as $$
  select case when x is null then 'n/a' when x < 0 then '−' || bi.fmt_inr(-x) when x > 0 then '+' || bi.fmt_inr(x) else '₹0' end $$;
create or replace function bi.fmt_sp(x numeric) returns text language sql immutable as $$
  select case when x is null then 'n/a' when x < 0 then '−' || bi.fmt_p(-x) when x > 0 then '+' || bi.fmt_p(x) else '0.0%' end $$;

create or replace function bi.ask_h_revenue(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $$
declare G jsonb; c jsonb; o jsonb; per text; focus text; rev boolean; ans text := ''; lab_c text; lab_p text; fnd jsonb; drivers jsonb := '[]'; risks jsonb := '[]';
        opps jsonb := '[]'; acts jsonb := '[]'; lim text := ''; ch jsonb; nums jsonb := '[]'; conf text := 'high'; ord text; F text; u text;
begin
  rev := not (q ~ '\mcases?\M' and q !~ '(revenue|billed|invoic|rupee|₹)');
  per := case when q ~ '(\myoy\M|year on year|year-on-year|same month last year|vs last year|than last year)' then 'yoy'
              when q ~ '(\mytd\M|year to date|financial year so far)' then 'ytd'
              when q ~ '(\mqoq\M|quarter on quarter|quarter-on-quarter|last quarter|previous quarter)' then 'qoq'
              when q ~ '(\mqtd\M|quarter to date|this quarter)' then 'qtd'
              when q ~ '(\mmtd\M|month to date)' and not rev then 'mtd'
              else 'mom' end;
  focus := case when q ~ '(below organic|under organic|negative effort|worse than organic|behind organic)' then 'below'
                when q ~ '(organic|beyond|effort|business as usual|expected growth)' then 'organic'
                when q ~ '(declin|fell|fall|lower|worst|down|loss|lost|shrink|weak)' then 'decline'
                else 'gain' end;
  G := public.bi_call('growth', jsonb_build_object('month', m, 'filters', f) || case when rev then jsonb_build_object('measure', 'revenue') else '{}'::jsonb end);
  if G is null or G ? 'error' then return jsonb_build_object('answer', coalesce(G->>'error', 'Growth figures are not available for this selection.'), 'confidence', 'low'); end if;
  if rev and not coalesce((G->>'available')::boolean, true) then
    return jsonb_build_object('answer', coalesce(G->>'message', 'Actual billed revenue is not available: no finance workbooks have been imported.'), 'confidence', 'high',
      'next', jsonb_build_array('How are we doing this month?'), 'limitations', 'Finance workbooks are imported by an admin in Admin → Upload.');
  end if;
  c := G->'cards'->per;
  if c is null or (rev and not coalesce((c->>'available')::boolean, false)) then
    -- the requested period cannot be compared on invoices: say why, show the benchmark, then answer month on month
    if rev and c is not null then
      ans := format('%s on actual billed revenue is not available: %s Expected minimum revenue (tracker benchmark, not invoiced) %s vs %s (%s). ',
        case per when 'yoy' then 'Year on year' when 'ytd' then 'Year to date' when 'qoq' then 'Quarter on quarter' else upper(per) end, c->>'reason',
        bi.fmt_inr((c->'benchmark'->>'expected_current')::numeric), bi.fmt_inr((c->'benchmark'->>'expected_previous')::numeric), bi.fmt_sp((c->'benchmark'->>'expected_pct')::numeric));
      lim := 'Invoices are complete only for ' || to_char((G->'billing'->>'first_complete')::date, 'Mon-YYYY') || ' – ' || to_char((G->'billing'->>'last_complete')::date, 'Mon-YYYY') || '. ';
    end if;
    per := 'mom'; c := G->'cards'->'mom';
  end if;
  if c is null then return jsonb_build_object('answer', ans || 'No comparison is available for this selection.', 'confidence', 'low'); end if;
  lab_c := (select string_agg(x, '+') from jsonb_array_elements_text(c->'current'->'label') x);
  lab_p := (select string_agg(x, '+') from jsonb_array_elements_text(c->'previous'->'label') x);
  o := c->'organic';
  if rev then
    F := 'inr';
    ans := ans || format('Actual billed revenue (invoices, ex-GST) %s: %s vs %s in %s — %s (%s).', lab_c, bi.fmt_inr((c->'current'->>'billed')::numeric), bi.fmt_inr((c->'previous'->>'billed')::numeric),
                         lab_p, bi.fmt_sinr((c->>'billed_change')::numeric), bi.fmt_sp((c->>'billed_pct')::numeric));
    if o->>'organic_current' is not null then
      ans := ans || format(' Organic expectation %s vs %s (organic growth %s); growth beyond organic %s — effort %s then, %s now.',
        bi.fmt_inr((o->>'organic_current')::numeric), bi.fmt_inr((o->>'organic_previous')::numeric), bi.fmt_sinr((o->>'organic_growth')::numeric),
        bi.fmt_sinr((o->>'beyond_organic')::numeric), bi.fmt_sinr((o->>'effort_previous')::numeric), bi.fmt_sinr((o->>'effort_current')::numeric));
      if (o->>'covered_share')::numeric < 0.9 then conf := 'medium'; end if;
    end if;
    ans := ans || format(' Expected minimum revenue (tracker) %s; billed per case %s (expected %s).', bi.fmt_inr((c->'current'->>'expected')::numeric),
                         bi.fmt_inr((c->'current'->>'billed_per_case')::numeric), bi.fmt_inr((c->'current'->>'expected_per_case')::numeric));
    nums := jsonb_build_array(jsonb_build_object('metric', 'Actual billed ' || lab_c, 'value', c->'current'->'billed'), jsonb_build_object('metric', 'Actual billed ' || lab_p, 'value', c->'previous'->'billed'),
                              jsonb_build_object('metric', 'Growth beyond organic', 'value', o->'beyond_organic'));
    lim := lim || 'Invoice month is used as the service month; billing units combine locations where invoices do not name the city; organic is an estimate (pair error ' ||
           coalesce(bi.fmt_p((G->'organic'->'validation'->>'pair_wape')::numeric), 'n/a') || '), not proof of cause.';
    select coalesce(jsonb_agg(x), '[]') into risks from (
      select e->>'note' x from jsonb_array_elements(coalesce(G->'in_progress', '[]')) e
      union all select format('%s unit × client pairs had expected revenue of %s but no identified invoice in %s.', c->'structure'->>'not_billed_pairs', bi.fmt_inr((c->'structure'->>'not_billed_expected')::numeric), lab_c)
        where coalesce((c->'structure'->>'not_billed_pairs')::int, 0) > 0) z;
    ch := jsonb_build_object('type', 'line', 'title', 'Actual billed vs organic expectation (completely billed months)', 'unit', '₹',
      'labels', (select jsonb_agg(to_char((t->>'month')::date, 'Mon-YY') order by t->>'month') from jsonb_array_elements(G->'trend') t where t->>'status' = 'complete'),
      'series', jsonb_build_array(
        jsonb_build_object('name', 'Actual billed', 'values', (select jsonb_agg(round((t->>'billed')::numeric) order by t->>'month') from jsonb_array_elements(G->'trend') t where t->>'status' = 'complete')),
        jsonb_build_object('name', 'Organic', 'values', (select jsonb_agg(round((t->>'organic_billed')::numeric) order by t->>'month') from jsonb_array_elements(G->'trend') t where t->>'status' = 'complete'))));
  else
    F := 'n';
    ans := ans || format('Cases %s: %s vs %s in %s — %s (%s).', lab_c, bi.fmt_n((c->'current'->>'cases')::numeric), bi.fmt_n((c->'previous'->>'cases')::numeric), lab_p,
                         bi.fmt_s((c->>'cases_change')::numeric), bi.fmt_sp((c->>'cases_pct')::numeric));
    if o->>'organic_current' is not null then
      ans := ans || format(' Organic expectation %s vs %s (organic growth %s); growth beyond organic %s cases.', bi.fmt_n((o->>'organic_current')::numeric), bi.fmt_n((o->>'organic_previous')::numeric),
                           bi.fmt_s((o->>'organic_growth')::numeric), bi.fmt_s((o->>'beyond_organic')::numeric));
    end if;
    nums := jsonb_build_array(jsonb_build_object('metric', 'Cases ' || lab_c, 'value', c->'current'->'cases'), jsonb_build_object('metric', 'Cases ' || lab_p, 'value', c->'previous'->'cases'));
    lim := lim || 'Organic is an estimate (blend of last month, last quarter with its trend and the same month last year), not proof of cause.';
  end if;
  ord := case focus when 'decline' then 'chg_asc' when 'below' then 'beyond_asc' when 'organic' then 'beyond_desc' else 'chg_desc' end;
  -- findings: unit/location × client rows for the chosen period, ranked as asked; names only here
  with pr as (select p, coalesce((p->per->>'cur')::numeric, (p->per->>'prev')::numeric + (p->per->>'chg')::numeric, case when per = 'mom' then (p->>case when rev then 'billed' else 'cases' end)::numeric end) cur,
                     (p->per->>'prev')::numeric prev, (p->per->>'chg')::numeric chg, (p->per->>'pct')::numeric pct, (p->per->>'beyond')::numeric beyond
              from jsonb_array_elements(coalesce(G->'pairs', '[]')) p where p ? per),
       rk as (select pr.*, row_number() over (order by case ord when 'chg_asc' then chg when 'beyond_asc' then beyond end asc nulls last,
                                                        case ord when 'chg_desc' then chg when 'beyond_desc' then beyond end desc nulls last) rn
              from pr where case ord when 'beyond_asc' then beyond is not null when 'beyond_desc' then beyond is not null else chg is not null end)
  select jsonb_build_object('columns', jsonb_build_array(case when rev then 'Billing unit' else 'Location' end, 'Client', lab_c, lab_p, 'Change', 'Change %', 'Beyond organic', 'Stakeholder (mapped)', 'Branch manager (mapped)'),
           'rows', coalesce(jsonb_agg(jsonb_build_array(p->>'location', coalesce(p->>'client_label', p->>'client'),
              case when F = 'inr' then bi.fmt_inr(cur) else bi.fmt_n(cur) end, case when F = 'inr' then bi.fmt_inr(prev) else bi.fmt_n(prev) end,
              case when F = 'inr' then bi.fmt_sinr(chg) else bi.fmt_s(chg) end, case when pct is null then 'small base' else bi.fmt_sp(pct) end,
              case when beyond is null then 'n/a' when F = 'inr' then bi.fmt_sinr(beyond) else bi.fmt_s(beyond) end,
              coalesce(p->>'owner', 'not mapped'), coalesce(p->>'branch_manager', 'not mapped')) order by z.rn), '[]')),
         coalesce(jsonb_agg(format('%s · %s: %s%s', p->>'location', coalesce(p->>'client_label', p->>'client'), case when F = 'inr' then bi.fmt_sinr(chg) else bi.fmt_s(chg) end,
              case when beyond is not null then ', beyond organic ' || case when F = 'inr' then bi.fmt_sinr(beyond) else bi.fmt_s(beyond) end else '' end) order by z.rn) filter (where z.rn <= 3), '[]')
    into fnd, drivers from rk z where z.rn <= 8;
  if jsonb_array_length(coalesce(fnd->'rows', '[]')) > 0 then
    u := fnd->'rows'->0->>0;
    acts := jsonb_build_array(bi.ask_act('High', format('Review %s · %s with its branch manager', fnd->'rows'->0->>0, fnd->'rows'->0->>1),
              case focus when 'decline' then 'largest fall in the period' when 'below' then 'furthest below its organic expectation' when 'organic' then 'largest growth beyond organic' else 'largest gain — check whether it can be repeated' end,
              'Zonal stakeholder', null));
  end if;
  return jsonb_build_object('answer', ans, 'findings', fnd, 'drivers', drivers, 'risks', risks, 'opportunities', opps, 'actions', acts, 'chart', ch,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Growth & trends', 'section', 'growth'), jsonb_build_object('label', 'Open Revenue & collections', 'section', 'collections')),
    'next', jsonb_build_array('Which pairs are furthest below organic?', 'What is the quarter-to-date billed revenue growth?', 'Which client and location grew most in billed revenue?', 'How much of the billed revenue has been collected?'),
    'method', coalesce(G->'method'->>'comparison', 'Actual growth − organic growth = growth beyond organic.') || ' ' || coalesce(G->'method'->>'actual', ''),
    'limitations', nullif(trim(lim), ''), 'sources', jsonb_build_array(case when rev then 'Finance workbooks (invoices) and Zonal Tracker cases (bi.api_growth_rev)' else 'Zonal Tracker cases (bi.api_growth)' end),
    'confidence', conf, 'numbers', nums, 'period_compared', lab_c || ' vs ' || lab_p, 'measure', case when rev then 'revenue' else 'cases' end);
end $$;

-- route revenue-growth and organic questions to the new handler; keep outstanding / cash / realisation questions on collections
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  o := array[
$o0$    when q ~ '(collect|outstanding|receivable|invoice|realis|realiz|payment|overdue|debtor|billing|billed|cash|per case|billing gap|unbilled|\mowes?\M|\mowed\M|\mdues\M|pending payment|receivable)' then 'collections'$o0$,
$o1$    when 'collections' then bi.ask_h_collections(m, f, q)$o1$];
  n := array[
$n0$    when q ~ '(organic|beyond organic|business as usual|\meffort\M)' then 'revenue_growth'
    when q ~ '(billed revenue|invoiced revenue|actual revenue|actual billed|billing growth|revenue growth|grew|grow|growth|increase|decreas|declin|fell|improv|top|best|worst|gain|movers|change|compare|\mvs\M|versus|\mmom\M|\mqoq\M|\myoy\M|\mqtd\M|\mytd\M|month on month|quarter on quarter|year on year)'
         and q ~ '(revenue|billed|billing|invoic|\mmom\M|\mqoq\M|\myoy\M|\mqtd\M|\mytd\M|month on month|quarter on quarter|year on year)'
         and q !~ '(collect|outstanding|receivable|realis|realiz|overdue|\mcash\M|payment)' then 'revenue_growth'
    when q ~ '(collect|outstanding|receivable|invoice|realis|realiz|payment|overdue|debtor|billing|billed|cash|per case|billing gap|unbilled|\mowes?\M|\mowed\M|\mdues\M|pending payment|receivable)' then 'collections'$n0$,
$n1$    when 'collections' then bi.ask_h_collections(m, f, q)
    when 'revenue_growth' then bi.ask_h_revenue(m, f, q)$n1$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'bi_ask3 fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;

-- collections answer: tracker revenue is the expected minimum, not reported revenue
do $do$
declare d text; o text := $o$cash received was %s of reported revenue over %s.$o$; n text := $n$cash received (incl. GST) was %s of expected minimum revenue (tracker, ex-GST) over %s.$n$;
begin
  d := pg_get_functiondef('bi.ask_h_collections(date,jsonb,text)'::regprocedure);
  if position(o in d) = 0 then raise exception 'collections wording not found'; end if;
  execute replace(d, o, n);
end $do$;
