-- Applied to Supabase project via MCP on 20261021115651
-- bi_090f (21-Oct-2026): Ask Crux answers collection / outstanding / realisation questions from the finance layer;
-- finance admin operations available through the same token-checked ingest entry point.

create or replace function bi.ask_h_collections(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare a jsonb; k jsonb; rc jsonb; sn jsonb; ans text; focus text; acts jsonb := '[]'; risks jsonb := '[]'; drivers jsonb := '[]'; fnd jsonb; ch jsonb;
        last jsonb; prev jsonb; part jsonb; i int := 0; r record; lim text;
begin
  a := public.bi_call('collections', jsonb_build_object('month', m, 'filters', f));
  if a is null or not coalesce((a->>'available')::boolean, false) then
    return jsonb_build_object('answer', coalesce(a->>'message', 'No collection or outstanding data has been imported yet.'), 'confidence', 'high',
      'next', jsonb_build_array('How are we doing this month?'), 'limitations', 'Finance workbooks are imported by an admin in Admin → Upload.');
  end if;
  k := a->'kpi'; rc := a->'receipts'; sn := a->'snapshot';
  focus := case when q ~ '(ageing|aging|old|older|180|90 days|overdue|long pending|stuck)' then 'ageing'
                when q ~ '(realis|realiz|efficien|how much of .*(billing|invoic)|settled)' then 'realisation'
                when q ~ '(fell|fall|declin|lower|down|less|reduc|trend|month on month|improv)' then 'trend'
                when q ~ '(per case|rate|price|billing gap|unbilled|not billed)' then 'per_case'
                when q ~ '(client|bank|family|sbi|bom|boi|canara)' and not (f ? 'client_family') then 'client'
                when q ~ '(which location|where|worst|highest|biggest|top|by location|zone)' then 'location'
                else 'overview' end;
  last := (select x from jsonb_array_elements(a->'trend') x where (x->>'month')::date = (rc->>'last_complete_month')::date);
  prev := (select x from jsonb_array_elements(a->'trend') x where (x->>'month')::date = ((rc->>'last_complete_month')::date - interval '1 month')::date);
  part := (select x from jsonb_array_elements(a->'trend') x where (x->>'partial')::boolean limit 1);

  ans := format('Outstanding %s as at %s (net of unadjusted receipts %s); %s (%s) is over 180 days. Collected %s in %s%s. Realisation %s of invoices raised %s; cash cover %s over %s.',
    bi.fmt_inr((k->>'outstanding')::numeric), to_char((sn->>'as_of')::date, 'DD-Mon-YYYY'), coalesce(bi.fmt_inr((k->>'net_receivable')::numeric), 'n/a for a client filter'),
    bi.fmt_inr((k->>'over_180')::numeric), bi.fmt_p((k->>'over_180_share')::numeric), bi.fmt_inr((k->>'collected_last_month')::numeric), to_char((rc->>'last_complete_month')::date, 'Mon YYYY'),
    case when prev is not null then format(' vs %s in %s', bi.fmt_inr((prev->>'collected')::numeric), to_char((prev->>'month')::date, 'Mon')) else '' end,
    bi.fmt_p((k->>'realisation')::numeric), lower(replace(k->>'realisation_basis', 'Invoices raised ', '')), bi.fmt_p((k->>'cash_cover_3m')::numeric),
    (select to_char((a->'comparison_months'->>0)::date, 'Mon') || '–' || to_char((a->'comparison_months'->>(jsonb_array_length(a->'comparison_months') - 1))::date, 'Mon YYYY')));

  if focus = 'trend' then
    if q ~ '(fell|fall|declin|lower|down|less|reduc)' and (last->>'collected')::numeric >= coalesce((prev->>'collected')::numeric, 0) then
      ans := format('Not lower: collections in %s were %s, %s %s on %s (%s). ', to_char((last->>'month')::date, 'Mon YYYY'), bi.fmt_inr((last->>'collected')::numeric),
               case when (prev->>'collected')::numeric > 0 then bi.fmt_p(((last->>'collected')::numeric - (prev->>'collected')::numeric) / (prev->>'collected')::numeric) else '' end,
               'up', to_char((prev->>'month')::date, 'Mon'), bi.fmt_inr((prev->>'collected')::numeric))
             || case when part is not null then format('%s is a part month (receipts to %s): %s so far, so it should not be compared with a full month yet. ', to_char((part->>'month')::date, 'Mon'),
                  to_char((rc->>'data_through')::date, 'DD-Mon'), bi.fmt_inr((part->>'collected')::numeric)) else '' end || ans;
    end if;
    fnd := jsonb_build_object('columns', jsonb_build_array('Month', 'Reported revenue', 'Collected', 'Quoting an invoice', 'Unallocated', 'Cash cover'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(to_char((x->>'month')::date, 'Mon YYYY') || case when (x->>'partial')::boolean then ' (part)' else '' end,
                 bi.fmt_inr((x->>'revenue')::numeric), bi.fmt_inr((x->>'collected')::numeric), bi.fmt_inr((x->>'against_invoices')::numeric), bi.fmt_inr((x->>'unallocated')::numeric),
                 bi.fmt_p((x->>'cash_cover')::numeric)) order by (x->>'month')::date), '[]') from jsonb_array_elements(a->'trend') x));
    ch := jsonb_build_object('type', 'bar', 'title', 'Collected vs reported revenue by month', 'unit', '₹ lakh',
      'labels', (select jsonb_agg(to_char((x->>'month')::date, 'Mon') order by (x->>'month')::date) from jsonb_array_elements(a->'trend') x),
      'series', jsonb_build_array(
        jsonb_build_object('name', 'Collected', 'values', (select jsonb_agg(round(coalesce((x->>'collected')::numeric, 0) / 1e5, 1) order by (x->>'month')::date) from jsonb_array_elements(a->'trend') x)),
        jsonb_build_object('name', 'Reported revenue', 'values', (select jsonb_agg(round((x->>'revenue')::numeric / 1e5, 1) order by (x->>'month')::date) from jsonb_array_elements(a->'trend') x))));
  elsif focus = 'realisation' then
    fnd := jsonb_build_object('columns', jsonb_build_array('Invoice month', 'Reported revenue', 'Invoice value identified', 'Settled', 'Still open', 'Realisation', 'Age (days)'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(to_char((x->>'month')::date, 'Mon YYYY'), bi.fmt_inr((x->>'revenue')::numeric), bi.fmt_inr((x->>'identified')::numeric),
                 bi.fmt_inr((x->>'settled')::numeric), bi.fmt_inr((x->>'open')::numeric), bi.fmt_p((x->>'realisation')::numeric), x->>'age_days') order by (x->>'month')::date), '[]') from jsonb_array_elements(a->'flow') x));
    ch := jsonb_build_object('type', 'stacked', 'title', 'Invoice value by invoice month: settled vs still open (ex-GST)', 'unit', '₹ lakh',
      'labels', (select jsonb_agg(to_char((x->>'month')::date, 'Mon') order by (x->>'month')::date) from jsonb_array_elements(a->'flow') x),
      'series', jsonb_build_array(
        jsonb_build_object('name', 'Settled', 'values', (select jsonb_agg(round(coalesce((x->>'settled')::numeric, 0) / 1e5, 1) order by (x->>'month')::date) from jsonb_array_elements(a->'flow') x)),
        jsonb_build_object('name', 'Still open', 'values', (select jsonb_agg(round(coalesce((x->>'open')::numeric, 0) / 1e5, 1) order by (x->>'month')::date) from jsonb_array_elements(a->'flow') x))));
    drivers := drivers || to_jsonb('Older invoice months are more settled simply because they have had longer to be paid; compare months of similar age.'::text);
  elsif focus = 'per_case' then
    fnd := jsonb_build_object('columns', jsonb_build_array('Month', 'Cases', 'Reported revenue per case', 'Tracker rate', 'Invoiced per case', 'Collected per case', 'Billing gap'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(to_char((x->>'month')::date, 'Mon YYYY'), bi.fmt_n((x->>'cases')::numeric), '₹' || coalesce(x->>'revenue_per_case', '–'),
                 '₹' || coalesce(x->>'tracker_rate', '–'), '₹' || coalesce(x->>'invoiced_per_case', '–'), '₹' || coalesce(x->>'collected_per_case', '–'), bi.fmt_p((x->>'billing_gap')::numeric)) order by (x->>'month')::date), '[]')
               from jsonb_array_elements(a->'per_case') x));
    ch := jsonb_build_object('type', 'line', 'title', 'Value per case (ex-GST)', 'unit', '₹ per case',
      'labels', (select jsonb_agg(to_char((x->>'month')::date, 'Mon') order by (x->>'month')::date) from jsonb_array_elements(a->'per_case') x),
      'series', jsonb_build_array(
        jsonb_build_object('name', 'Reported revenue per case', 'values', (select jsonb_agg((x->>'revenue_per_case')::numeric order by (x->>'month')::date) from jsonb_array_elements(a->'per_case') x)),
        jsonb_build_object('name', 'Invoiced per case', 'values', (select jsonb_agg((x->>'invoiced_per_case')::numeric order by (x->>'month')::date) from jsonb_array_elements(a->'per_case') x)),
        jsonb_build_object('name', 'Collected per case', 'values', (select jsonb_agg((x->>'collected_per_case')::numeric order by (x->>'month')::date) from jsonb_array_elements(a->'per_case') x))));
  elsif focus = 'client' then
    fnd := jsonb_build_object('columns', jsonb_build_array('Client', 'Outstanding', 'Over 180 days', 'Collected this financial year', 'Cash cover (3 months)'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(x->>'family', bi.fmt_inr((x->>'outstanding')::numeric), bi.fmt_inr((x->>'over_180')::numeric), bi.fmt_inr((x->>'collected_fytd')::numeric),
                 bi.fmt_p((x->>'cash_cover_3m')::numeric))), '[]') from (select x from jsonb_array_elements(a->'by_client') x limit 12) z));
    ch := jsonb_build_object('type', 'hbar', 'title', 'Outstanding by client', 'unit', '₹ lakh',
      'labels', (select jsonb_agg(x->>'family') from (select x from jsonb_array_elements(a->'by_client') x limit 10) z),
      'series', jsonb_build_array(jsonb_build_object('name', 'Outstanding', 'values', (select jsonb_agg(round((x->>'outstanding')::numeric / 1e5, 1)) from (select x from jsonb_array_elements(a->'by_client') x limit 10) z))));
  else
    fnd := jsonb_build_object('columns', jsonb_build_array('Location', 'Outstanding', 'Over 180 days', 'Share over 180', 'Unadjusted receipts', 'Collected last month', 'Days to collect'),
      'rows', (select coalesce(jsonb_agg(jsonb_build_array(x->>'location', bi.fmt_inr((x->>'outstanding')::numeric), bi.fmt_inr((x->>'over_180')::numeric), bi.fmt_p((x->>'over_180_share')::numeric),
                 bi.fmt_inr((x->>'unadjusted')::numeric), bi.fmt_inr((x->>'collected_last_month')::numeric), coalesce(x->>'avg_days_to_collect', '–'))), '[]')
               from (select x from jsonb_array_elements(a->'by_location') x order by case when focus = 'ageing' then (x->>'over_180')::numeric else (x->>'outstanding')::numeric end desc nulls last limit 10) z));
    ch := jsonb_build_object('type', 'bar', 'title', 'Outstanding by age (days since the end of the invoice month)', 'unit', '₹ lakh',
      'labels', (select jsonb_agg(x->>'bucket') from jsonb_array_elements(a->'ageing') x),
      'series', jsonb_build_array(jsonb_build_object('name', 'Outstanding', 'values', (select jsonb_agg(round((x->>'amount')::numeric / 1e5, 1)) from jsonb_array_elements(a->'ageing') x))));
    if focus = 'ageing' then
      ans := format('%s of %s outstanding is over 180 days and %s is over 90 days. ', bi.fmt_inr((k->>'over_180')::numeric), bi.fmt_inr((k->>'outstanding')::numeric), bi.fmt_inr((k->>'over_90')::numeric))
             || case when (k->>'pre_apr_2024')::numeric > 0 then format('%s is on invoices raised before April 2024. ', bi.fmt_inr((k->>'pre_apr_2024')::numeric)) else '' end || ans;
    end if;
  end if;

  for r in select x from jsonb_array_elements(a->'alerts') x order by case x->>'severity' when 'high' then 1 when 'warn' then 2 else 3 end limit 4 loop
    i := i + 1;
    risks := risks || to_jsonb((r.x->>'title') || '. ' || coalesce(r.x->>'detail', ''));
    if r.x->>'action' is not null then
      acts := acts || bi.ask_act(case r.x->>'severity' when 'high' then 'High' when 'warn' then 'Medium' else 'Low' end, r.x->>'action', r.x->>'title', coalesce(r.x->>'owner', 'Finance'),
                                 case when r.x->>'title' ~ 'over 180' then 'Recovers the oldest receivables first' when r.x->>'title' ~ 'unadjusted' then 'A true picture of what each client owes'
                                      when r.x->>'title' ~ 'not reflected' then 'Ledger and bank records agree' else 'Fewer surprises at month end' end);
    end if;
  end loop;
  lim := (select string_agg(x #>> '{}', ' ') from jsonb_array_elements(a->'limitations') x);

  return jsonb_build_object('answer', ans, 'findings', fnd, 'chart', ch, 'drivers', drivers, 'risks', risks, 'opportunities', '[]'::jsonb, 'actions', acts,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Revenue & collections', 'section', 'collections'),
                               jsonb_build_object('label', 'Finance checks in Data health', 'section', 'health')),
    'next', case focus when 'trend' then jsonb_build_array('Which locations have the oldest outstanding?', 'What is the realisation by invoice month?')
                       when 'realisation' then jsonb_build_array('Which locations have the oldest outstanding?', 'Why did collections fall?')
                       else jsonb_build_array('What is the realisation by invoice month?', 'Why did collections fall?', 'Revenue per case vs rate?') end,
    'method', coalesce(a->'method'->>case focus when 'trend' then 'cash_cover' when 'realisation' then 'realisation' when 'per_case' then 'revenue_per_case' else 'ageing' end, a->'method'->>'outstanding'),
    'sources', jsonb_build_array('Outstanding workbook ' || (sn->>'file') || ' (as at ' || to_char((sn->>'as_of')::date, 'DD-Mon-YYYY') || ')',
                                 'Collection workbook ' || (rc->>'file') || ' (receipts to ' || to_char((rc->>'data_through')::date, 'DD-Mon-YYYY') || ')', 'Zonal Tracker reported revenue'),
    'confidence', 'medium', 'limitations', lim);
end $function$;

do $do$
declare d text := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure); a int; b int; frag text;
begin
  if position('ask_h_collections' in d) > 0 then return; end if;
  a := position($x$when 'collections' then jsonb_build_object('answer', 'Collection, invoice and outstanding figures are not in the database yet$x$ in d);
  if a = 0 then raise exception 'collections placeholder not found'; end if;
  b := position($x$'Collection and outstanding workbooks have not been integrated yet.')$x$ in d);
  if b = 0 or b < a then raise exception 'placeholder end not found'; end if;
  frag := substring(d from a for b - a + length($x$'Collection and outstanding workbooks have not been integrated yet.')$x$));
  d := replace(d, frag, $x$when 'collections' then bi.ask_h_collections(m, f, q)$x$);
  execute d;
end $do$;

do $do$
declare d text := pg_get_functiondef('bi.fin_ingest_as(text,text,jsonb)'::regprocedure); n int;
begin
  if position($x$p_action = 'admin'$x$ in d) > 0 then return; end if;
  n := (length(d) - length(replace(d, $x$  elsif p_action = 'reject' then$x$, ''))) / length($x$  elsif p_action = 'reject' then$x$);
  if n <> 1 then raise exception 'reject branch found % times', n; end if;
  d := replace(d, $x$  elsif p_action = 'reject' then$x$, $x$  elsif p_action = 'admin' then
    return bi.fin_admin(p_actor, p);

  elsif p_action = 'reject' then$x$);
  execute d;
end $do$;
