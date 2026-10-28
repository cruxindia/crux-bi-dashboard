-- Applied to Supabase project via MCP on 20261022115106
-- bi_094g (22-Oct-2026): Ask Crux answers about branch managers and about revenue "now".
-- A question naming a branch manager (full name, or a distinctive part of it) or mentioning branch managers / hand-overs goes to bi.ask_h_bm,
-- before location matching can mistake a name for a location (a location label can contain a manager's name). General revenue questions
-- without billed / collection / growth words get the current-month Expected → Billed → Collected summary with managers ranked.
create or replace function bi.ask_h_bm(m date, f jsonb, q text, p_mgr text default null)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare B jsonb; T jsonb; Fi jsonb; r jsonb; ans text; fnd jsonb; drivers jsonb := '[]'; risks jsonb := '[]'; acts jsonb := '[]'; ch jsonb; ord text; lab text; part boolean; nm int; ho jsonb;
begin
  B := public.bi_call('bm', jsonb_build_object('month', m, 'filters', f) || case when p_mgr is not null then jsonb_build_object('p', jsonb_build_object('manager', p_mgr)) else '{}'::jsonb end);
  if B is null or B ? 'error' or B->'total' is null then
    return jsonb_build_object('answer', coalesce(B->>'error', 'Branch-manager figures are not available for this selection.'), 'confidence', 'low'); end if;
  T := B->'total'; Fi := B->'finance'; part := coalesce((B->>'partial')::boolean, false);
  lab := to_char(m, 'Mon YYYY') || case when part then ' to ' || to_char((B->>'as_of')::date, 'DD-Mon') else '' end;
  select coalesce(jsonb_agg(format('Hand-over %s: %s → %s (%s): expected revenue per working day %s → %s (%s; rest of business %s)%s',
           to_char((h->>'date')::date, 'Mon YYYY'), h->>'from', h->>'to', (select string_agg(v, ', ') from jsonb_array_elements_text(h->'locations') v),
           bi.fmt_inr((h->>'revenue_per_workday_before')::numeric), bi.fmt_inr((h->>'revenue_per_workday_after')::numeric), bi.fmt_sp((h->>'revenue_shift_pct')::numeric),
           bi.fmt_sp((h->>'rest_of_business_shift_pct')::numeric), coalesce(' — ' || (h->>'status'), ''))), '[]')
    into ho from jsonb_array_elements(coalesce(B->'handovers', '[]')) h;
  if p_mgr is not null then
    select x into r from jsonb_array_elements(B->'managers') x where x->>'manager' = p_mgr;
    if r is null then return jsonb_build_object('answer', format('%s has no business mapped in %s for this selection.', p_mgr, to_char(m, 'Mon YYYY')), 'confidence', 'medium',
        'drill', jsonb_build_array(jsonb_build_object('label', 'Open People → Branch managers', 'section', 'people'))); end if;
    ans := format('%s (branch manager as mapped), %s: expected revenue %s — %s of the %s target%s; %s vs the same working day last month. Effort vs organic %s. Billed %s: %s (%s of expected). Collected %s to %s: %s. Outstanding %s. Locations: %s.',
      p_mgr, lab, bi.fmt_inr((r->>'expected_revenue')::numeric), bi.fmt_p((r->>'revenue_attainment')::numeric), bi.fmt_inr((r->>'revenue_target')::numeric),
      case when part and r->>'projected_attainment' is not null then ', on course for ' || bi.fmt_p((r->>'projected_attainment')::numeric) || ' by month end' else '' end,
      bi.fmt_sinr((r->>'revenue_change')::numeric) || coalesce(' (' || bi.fmt_sp((r->>'revenue_change_pct')::numeric) || ')', ''),
      bi.fmt_sp((r->>'effort_pct')::numeric),
      to_char((Fi->>'last_complete_billing_month')::date, 'Mon YYYY'), bi.fmt_inr((r->>'billed_complete')::numeric), bi.fmt_p((r->>'billing_ratio')::numeric),
      to_char((Fi->>'receipt_month')::date, 'Mon YYYY'), to_char((Fi->>'receipts_through')::date, 'DD-Mon'), bi.fmt_inr((r->>'collected_current')::numeric),
      bi.fmt_inr((r->>'outstanding')::numeric), coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(r->'locations') x), 'none'));
    select jsonb_build_object('columns', jsonb_build_array('Location', 'Client', 'Expected revenue', 'Target', 'Achieved', 'vs same day last month', 'Effort vs organic'),
             'rows', coalesce(jsonb_agg(jsonb_build_array(x->>'location', x->>'client_label', bi.fmt_inr((x->>'expected_revenue')::numeric), bi.fmt_inr((x->>'revenue_target')::numeric),
                bi.fmt_p((x->>'revenue_attainment')::numeric), bi.fmt_sp((x->>'revenue_change_pct')::numeric), bi.fmt_sp((x->>'effort_pct')::numeric))), '[]'))
      into fnd from (select x from jsonb_array_elements(coalesce(B->'portfolio', '[]')) x limit 10) z;
    drivers := ho;
    ch := jsonb_build_object('type', 'bar', 'title', 'Expected revenue by month (portfolio as assigned in each month)', 'unit', '₹',
      'labels', (select jsonb_agg(to_char((t->>'month')::date, 'Mon-YY') order by t->>'month') from jsonb_array_elements(coalesce(B->'trend', '[]')) t),
      'series', jsonb_build_array(
        jsonb_build_object('name', 'Expected revenue', 'values', (select jsonb_agg(round((t->>'expected_revenue')::numeric) order by t->>'month') from jsonb_array_elements(coalesce(B->'trend', '[]')) t)),
        jsonb_build_object('name', 'Target', 'values', (select jsonb_agg(round((t->>'revenue_target')::numeric) order by t->>'month') from jsonb_array_elements(coalesce(B->'trend', '[]')) t))));
    if part and (r->>'projected_attainment')::numeric < 0.9 then
      acts := jsonb_build_array(bi.ask_act('High', format('Review the gap to the pace needed today (%s) with %s', bi.fmt_sinr((r->>'pace_gap')::numeric), p_mgr),
                format('on course for %s of target', bi.fmt_p((r->>'projected_attainment')::numeric)), 'Zonal stakeholder', null));
    end if;
  else
    ord := case when q ~ '(behind|below|weak|worst|lagging|shortfall|risk|miss|furthest)' then 'asc' else 'desc' end;
    nm := (select count(*) from jsonb_array_elements(B->'managers') x where coalesce((x->>'current')::boolean, true) and x->>'manager' <> '(not mapped)');
    ans := format('%s: expected revenue (business) %s — %s of the %s target%s, %s vs the same working day last month. Billed (finance) %s: %s = %s of expected%s. Collected %s to %s: %s; outstanding %s. %s branch managers; %s.',
      lab, bi.fmt_inr((T->>'expected_revenue')::numeric), bi.fmt_p((T->>'revenue_attainment')::numeric), bi.fmt_inr((T->>'revenue_target')::numeric),
      case when part and T->>'projected_revenue' is not null then format(', projected %s by month end', bi.fmt_inr((T->>'projected_revenue')::numeric)) else '' end,
      bi.fmt_sp((T->>'expected_revenue_change_pct')::numeric),
      to_char((Fi->>'last_complete_billing_month')::date, 'Mon YYYY'), bi.fmt_inr((T->>'billed_complete')::numeric),
      bi.fmt_p((T->>'billed_complete')::numeric / nullif((T->>'expected_complete')::numeric, 0)),
      case when Fi->>'billing_in_progress_month' is not null then format(' (%s still being billed: %s so far, %s of expected)', to_char((Fi->>'billing_in_progress_month')::date, 'Mon YYYY'),
           bi.fmt_inr((T->>'billed_in_progress')::numeric), bi.fmt_p((T->>'billed_in_progress')::numeric / nullif((T->>'expected_in_progress')::numeric, 0))) else '' end,
      to_char((Fi->>'receipt_month')::date, 'Mon YYYY'), to_char((Fi->>'receipts_through')::date, 'DD-Mon'), bi.fmt_inr((T->>'collected_current')::numeric), bi.fmt_inr((T->>'outstanding')::numeric),
      nm, case when q ~ 'hand.?over' then 'hand-overs listed below' when ord = 'asc' then 'furthest from target pace first' else 'largest expected revenue first' end);
    if q ~ 'hand.?over|changed manager|new manager|manager change' then
      select jsonb_build_object('columns', jsonb_build_array('Hand-over', 'From', 'To', 'Locations', 'Revenue / working day before', 'after', 'Change', 'Rest of business', 'Read with care'),
               'rows', coalesce(jsonb_agg(jsonb_build_array(to_char((h->>'date')::date, 'Mon YYYY'), h->>'from', h->>'to', (select string_agg(v, ', ') from jsonb_array_elements_text(h->'locations') v),
                  bi.fmt_inr((h->>'revenue_per_workday_before')::numeric), bi.fmt_inr((h->>'revenue_per_workday_after')::numeric), bi.fmt_sp((h->>'revenue_shift_pct')::numeric),
                  bi.fmt_sp((h->>'rest_of_business_shift_pct')::numeric), coalesce(h->>'status', '–'))), '[]'))
        into fnd from jsonb_array_elements(coalesce(B->'handovers', '[]')) h;
      drivers := ho;
    else
      select jsonb_build_object('columns', jsonb_build_array('Branch manager', 'Expected revenue', 'Target', 'Achieved', case when part then 'On course for' else 'Achieved' end, 'vs same day last month', 'Effort vs organic', 'Billed ÷ expected'),
               'rows', coalesce(jsonb_agg(jsonb_build_array(x->>'manager', bi.fmt_inr((x->>'expected_revenue')::numeric), bi.fmt_inr((x->>'revenue_target')::numeric), bi.fmt_p((x->>'revenue_attainment')::numeric),
                  bi.fmt_p((x->>'projected_attainment')::numeric), bi.fmt_sp((x->>'revenue_change_pct')::numeric), bi.fmt_sp((x->>'effort_pct')::numeric), bi.fmt_p((x->>'billing_ratio')::numeric)) order by rn), '[]')),
             coalesce(jsonb_agg(format('%s: on course for %s of target (%s so far)', x->>'manager', bi.fmt_p((x->>'projected_attainment')::numeric), bi.fmt_inr((x->>'expected_revenue')::numeric))) filter (where rn <= 3), '[]')
        into fnd, drivers
        from (select x, row_number() over (order by case when ord = 'asc' then (x->>'projected_attainment')::numeric end asc nulls last,
                                                      case when ord = 'desc' then (x->>'expected_revenue')::numeric end desc nulls last) rn
                from jsonb_array_elements(B->'managers') x
               where coalesce((x->>'current')::boolean, true) and x->>'manager' <> '(not mapped)' and coalesce((x->>'revenue_target')::numeric, 0) > 0) z where rn <= 10;
    end if;
    select coalesce(jsonb_agg(format('%s: on course for %s of target', x->>'manager', bi.fmt_p((x->>'projected_attainment')::numeric))), '[]') into risks
      from jsonb_array_elements(B->'managers') x where part and (x->>'projected_attainment')::numeric < 0.6 and x->>'manager' <> '(not mapped)';
  end if;
  return jsonb_build_object('answer', ans, 'findings', fnd, 'drivers', drivers, 'risks', risks, 'actions', acts, 'chart', ch,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open People → Branch managers', 'section', 'people'), jsonb_build_object('label', 'Open the Overview', 'section', 'overview')),
    'next', jsonb_build_array('Which branch managers are furthest from target?', 'What changed after the branch-manager hand-overs?', 'How much has been collected this month?'),
    'method', coalesce(B->'method'->>'business', '') || ' ' || coalesce(B->'method'->>'finance', ''),
    'limitations', 'Branch managers are mapped responsibility, not proof of who caused a result. Zone-level invoices and receipts are allocated by expected revenue (estimates).',
    'sources', jsonb_build_array('Zonal Tracker (business), finance workbooks (billing, collections) and branch-manager assignments (bi.api_bm)'),
    'confidence', 'high', 'measure', 'expected_revenue');
end $function$;

do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  o := array[
$o1$mid bigint; mm int; yy int; mx date; nn int; entity boolean := false; notes text := ''; amb text;$o1$,
$o2$  select l.id, l.label, count(*) over () n into loc from bi.location l,$o2$,
$o3$  select family into fam from bi.client c where$o3$,
$o4$    when q ~ '(organic|beyond organic|business as usual|$o4$,
$o5$    when 'revenue_growth' then bi.ask_h_revenue(m, f, q)$o5$];
  n := array[
$n1$mid bigint; mm int; yy int; mx date; nn int; entity boolean := false; notes text := ''; amb text; bmn text;$n1$,
$n2$  -- a branch manager named in the question (full name, else a distinctive part of it)
  select b.manager into bmn from (select distinct manager from bi.branch_manager where active) b
   where position(lower(b.manager) in q) > 0
      or exists (select 1 from regexp_split_to_table(lower(regexp_replace(b.manager, '[^A-Za-z ]', ' ', 'g')), '\s+') w
                  where length(w) >= 4 and w not in ('more', 'kumar', 'zone', 'rest', 'bank', 'shah', 'than') and q ~ ('\m' || w || '\M'))
   order by (position(lower(b.manager) in q) > 0) desc, length(b.manager) desc limit 1;
  select l.id, l.label, count(*) over () n into loc from bi.location l,$n2$,
$n3$  if bmn is not null and loc.id is not null and exists (select 1 from regexp_split_to_table(lower(regexp_replace(loc.label, '[^A-Za-z ]', ' ', 'g')), '\s+') w
        where length(w) >= 4 and lower(bmn) ~ ('\m' || w || '\M')) then
    f := f - 'location_id'; entity := false; notes := '';   -- the "location" matched only the manager's name
  end if;
  select family into fam from bi.client c where$n3$,
$n4$    when bmn is not null or q ~ '(branch.manager|\mbms?\M|\mmanagers?\M|hand.?over)' then 'bm'
    when q ~ '\m(revenue|expected revenue|sales|business value)\M'
         and q !~ '(billed|invoic|collect|outstanding|receivable|cash|payment|grew|grow|growth|increase|decreas|declin|fell|improv|\mtop\M|best|worst|gain|movers|change|compare|\mvs\M|versus|\mmom\M|\mqoq\M|\myoy\M|\mqtd\M|\mytd\M|month on month|organic|effort|forecast|projection|shortfall|behind|below)' then 'revenue_now'
    when q ~ '(organic|beyond organic|business as usual|$n4$,
$n5$    when 'revenue_growth' then bi.ask_h_revenue(m, f, q)
    when 'bm' then bi.ask_h_bm(m, f, q, bmn)
    when 'revenue_now' then bi.ask_h_bm(m, f, q, null)$n5$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'bi_ask3 fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
