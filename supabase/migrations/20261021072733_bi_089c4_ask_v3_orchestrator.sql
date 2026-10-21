-- Applied to Supabase project via MCP on 20261021072733
create or replace function bi.ask_h_priorities(m date, f jsonb, n int) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare o jsonb; fo jsonb; fr jsonb; P jsonb; L jsonb; S jsonb; c jsonb := '[]'; gap numeric; tgt numeric; worst jsonb; low jsonb; tat jsonb; om date := (select max(report_month) from bi.zt_snapshot);
        cm date; pm date; items jsonb; ans text; mt jsonb; oc record;
begin
  o := public.bi_call('overview', jsonb_build_object('month', m, 'filters', f)); fo := o->'forecast'; fr := o->'force';
  tgt := (o->>'target_cases')::numeric;
  gap := tgt - coalesce((fo->>'curve_projection')::numeric, (fo->>'run_rate_projection')::numeric);
  if gap > 0 then
    P := bi.ask_perf(m, f, case when f ? 'location_id' then 'client' else 'location' end);
    c := c || jsonb_build_object('impact', gap, 'issue', 'Month end projected below target',
      'finding', format('Projected %s of %s (%s); gap %s cases. Largest location gaps: %s.', bi.fmt_n(tgt - gap), bi.fmt_n(tgt), bi.fmt_p((tgt - gap) / nullif(tgt, 0)), bi.fmt_n(gap),
                 (select string_agg(format('%s %s', x->>'label', bi.fmt_n((x->>'projected_gap')::numeric)), ', ') from (select x from jsonb_array_elements(P->'rows') x where (x->>'projected_gap')::numeric > 0 limit 3) z)),
      'action', bi.ask_act('High', 'Agree recovery plans with the three locations with the largest gaps', format('Gap of %s cases to target at the current pace', bi.fmt_n(gap)), 'Zone heads', format('Up to %s cases', bi.fmt_n(gap))));
  end if;
  L := bi.api_lfl(m, f, case when f ? 'location_id' then 'client' else 'location' end);
  select e into worst from jsonb_array_elements(L->'rows') e where (e->>'change')::numeric < 0 order by (e->>'change')::numeric limit 1;
  if worst is not null then
    c := c || jsonb_build_object('impact', -(worst->>'change')::numeric, 'issue', format('%s behind last month', worst->>'group'),
      'finding', format('%s cases vs %s at the same working day last month (%s).', bi.fmt_n((worst->>'current')::numeric), bi.fmt_n((worst->>'previous')::numeric), bi.fmt_s((worst->>'change')::numeric)),
      'action', bi.ask_act('High', format('Find the cause of the fall in %s', worst->>'group'), format('%s cases vs the same point last month', bi.fmt_s((worst->>'change')::numeric)),
                           case when f ? 'location_id' then 'Client relationship lead' else 'Location manager' end, format('About %s cases if last month''s pace returns', bi.fmt_n(-(worst->>'change')::numeric))));
  end if;
  if coalesce((fr->>'excess_cases')::numeric, 0) > 0 then
    c := c || jsonb_build_object('impact', (fr->>'excess_cases')::numeric, 'issue', 'Force1 rows above the tracker',
      'finding', format('%s cases above the business count in %s rows (utilisation withheld there).', bi.fmt_n((fr->>'excess_cases')::numeric), fr->>'units_with_force_gt_tracker'),
      'action', bi.ask_act('Medium', 'Reconcile Force1 rows that exceed the tracker', 'Tracker undercount or wrong branch mapping', 'Force1 / MIS team', 'Correct utilisation and business counts'));
  end if;
  if coalesce((fr->>'tracker_cases_covered')::numeric, 0) > 0 then
    c := c || jsonb_build_object('impact', ((fr->>'tracker_cases_covered')::numeric - (fr->>'matched_cases')::numeric) * 0.5, 'issue', 'Work outside Force1',
      'finding', format('%s of %s business cases in Force1 location groups were not found in Force1 (utilisation %s).',
                 bi.fmt_n((fr->>'tracker_cases_covered')::numeric - (fr->>'matched_cases')::numeric), bi.fmt_n((fr->>'tracker_cases_covered')::numeric), bi.fmt_p((fr->>'usage_pct')::numeric)),
      'action', bi.ask_act('Medium', 'Raise Force1 use in the lowest-utilisation location groups', 'Manual work is not measured for TAT or productivity', 'Operations head', 'Each 10 points of utilisation adds about ' || bi.fmt_n(round((fr->>'tracker_cases_covered')::numeric * 0.1)) || ' cases to Force1'));
  end if;
  cm := case when m >= om then (m - interval '1 month')::date else m end; pm := (cm - interval '1 month')::date;
  S := bi.ask_tat_stats(array[pm, cm]::date[], f, 'unit');
  select jsonb_build_object('label', c1.v->>'label', 'p90', (c1.v->>'case_p90')::numeric, 'prev', (p1.v->>'case_p90')::numeric, 'n', (c1.v->>'case_n')::numeric) into tat
    from (select x->>'key' k, x v from jsonb_array_elements(S) x where (x->>'month')::date = cm) c1 join (select x->>'key' k, x v from jsonb_array_elements(S) x where (x->>'month')::date = pm) p1 using (k)
   where c1.k <> '~total' and (c1.v->>'case_n')::int >= 100 and (c1.v->>'case_back_entered')::numeric / nullif((c1.v->>'case_n')::numeric, 0) <= 0.5
     and (c1.v->>'case_p90')::numeric > (p1.v->>'case_p90')::numeric
   order by ((c1.v->>'case_p90')::numeric - (p1.v->>'case_p90')::numeric) * (c1.v->>'case_n')::numeric desc limit 1;
  if tat is not null then
    c := c || jsonb_build_object('impact', (tat->>'n')::numeric * 0.1, 'issue', format('TAT rising in %s', tat->>'label'),
      'finding', format('Case P90 %s → %s (%s vs %s; %s cases).', bi.fmt_h((tat->>'prev')::numeric), bi.fmt_h((tat->>'p90')::numeric), to_char(cm, 'Mon'), to_char(pm, 'Mon'), bi.fmt_n((tat->>'n')::numeric)),
      'action', bi.ask_act('Medium', format('Review the slowest cases in %s', tat->>'label'), 'Slowest 10% of cases are taking longer', 'Operations head', format('P90 back to %s', bi.fmt_h((tat->>'prev')::numeric))));
  end if;
  select * into oc from bi.force_open_cut();
  if m = oc.month and oc.case_cut < oc.latest_snap then
    c := c || jsonb_build_object('impact', 0, 'issue', 'Force1 data behind the tracker',
      'finding', format('Force1 cases run to %s while the tracker runs to %s; Force1 figures cover the earlier date.', to_char(oc.case_cut, 'DD-Mon'), to_char(oc.latest_snap, 'DD-Mon')),
      'action', bi.ask_act('Low', 'Upload the latest Force1 Case Wise and Point Wise files', 'Keeps Force1 and TAT figures current', 'Data team', 'Current Force1 figures'));
  end if;
  select coalesce(jsonb_agg(x order by (x->>'impact')::numeric desc), '[]') into items from (select x from jsonb_array_elements(c) x order by (x->>'impact')::numeric desc limit greatest(least(n, 8), 1)) z;
  ans := format('The %s most important issues for %s, ranked by cases affected: %s.', jsonb_array_length(items), to_char(m, 'Mon YYYY'),
           (select string_agg(format('(%s) %s', o2, x->>'issue'), '; ' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2)));
  return jsonb_build_object('answer', ans,
    'findings', jsonb_build_object('columns', jsonb_build_array('#', 'Issue', 'What the data shows'),
      'rows', (select jsonb_agg(jsonb_build_array(o2::text, x->>'issue', x->>'finding') order by o2) from jsonb_array_elements(items) with ordinality t(x, o2))),
    'drivers', '[]'::jsonb, 'risks', '[]'::jsonb, 'opportunities', '[]'::jsonb,
    'actions', (select jsonb_agg(x->'action' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2)),
    'chart', jsonb_build_object('type', 'hbar', 'title', 'Cases affected by each issue', 'unit', 'cases',
       'labels', (select jsonb_agg(x->>'issue' order by o2) from jsonb_array_elements(items) with ordinality t(x, o2) where (x->>'impact')::numeric > 0),
       'series', jsonb_build_array(jsonb_build_object('name', 'Cases affected', 'values', (select jsonb_agg(round((x->>'impact')::numeric) order by o2) from jsonb_array_elements(items) with ordinality t(x, o2) where (x->>'impact')::numeric > 0)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open the business breakdown', 'f', f)),
    'next', jsonb_build_array('Which locations contribute most to the shortfall?', 'Where is TAT increasing?', 'What data issues need attention?'),
    'method', 'Candidate issues are computed from the dashboard functions (projection vs target, like-for-like change, Force1 reconciliation and utilisation, TAT change between complete months, source dates) and ranked by cases affected. Force1 work outside the system is weighted at half and a TAT rise at one-tenth of the cases involved, because they do not change the business count directly.',
    'sources', jsonb_build_array('bi.api_overview', 'bi.api_lfl', 'bi.ask_perf', 'bi.ask_tat_stats', 'bi.api_force1_recon'), 'confidence', 'medium',
    'limitations', 'The ranking weights are a documented rule of thumb, not a business-approved scoring. Collections are not included until the collection files are integrated.');
end $function$;

create or replace function public.bi_ask3(p_question text, p_context jsonb default '{}'::jsonb, p_conversation uuid default null) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '50s' as $function$
declare q text := lower(coalesce(p_question, '')); qo text := coalesce(p_question, ''); ctx jsonb := coalesce(p_context, '{}'::jsonb);
        f jsonb := coalesce(p_context->'filters', '{}'::jsonb); sec text := coalesce(p_context->>'section', ''); m date; intent text; a jsonb;
        conv uuid := p_conversation; prev jsonb; loc record; fam text; zg text; scope text; ver bigint := (select coalesce(max(id), 0) from bi.audit_log);
        mid bigint; mm int; yy int; mx date; nn int; entity boolean := false; notes text := ''; amb text;
begin
  if length(q) < 3 or length(q) > 500 then return jsonb_build_object('error', 'Ask a question between 3 and 500 characters.'); end if;
  if (select count(*) from bi.ai_message where created_at > now() - interval '1 hour') > 600 then return jsonb_build_object('error', 'Ask Crux is busy (hourly limit). Try again shortly.'); end if;
  if conv is not null and (select count(*) from bi.ai_message where conversation_id = conv and created_at > now() - interval '10 minutes') > 30 then
    return jsonb_build_object('error', 'Too many questions in a short time. Please wait a few minutes.'); end if;
  if conv is null or not exists (select 1 from bi.ai_conversation where id = conv) then insert into bi.ai_conversation(context) values (ctx) returning id into conv;
  else select filters into prev from bi.ai_message where conversation_id = conv order by id desc limit 1; end if;

  select l.id, l.label, count(*) over () n into loc from bi.location l,
         lateral (select w from regexp_split_to_table(lower(regexp_replace(l.label, '[^A-Za-z ]', ' ', 'g')), '\s+') w
                  where length(w) >= 4 and w not in ('zone', 'rest', 'branch', 'assam', 'kerela', 'chennai', 'karnataka', 'rajisthan', 'mukesh', 'yadav', 'firoz', 'crux')) ws
   where not l.is_rollup and q ~ ('\m' || ws.w || '\M')
   group by l.id, l.label order by count(*) desc, length(l.label) limit 1;
  select z.code into zg from bi.zone_group z, lateral (select w from regexp_split_to_table(lower(regexp_replace(z.label, '[^A-Za-z ]', ' ', 'g')), '\s+') w where length(w) >= 4 and w not in ('zone', 'rest', 'assam')) ws
   where q ~ ('\m' || ws.w || '\M') order by length(z.label) limit 1;
  if loc.id is not null and not (zg is not null and q ~ '\mzone\M') then
    f := (f - 'zone_group') || jsonb_build_object('location_id', loc.id); entity := true;
    select string_agg(l2.label, ', ') into amb from bi.location l2 where not l2.is_rollup and l2.id <> loc.id
      and lower(split_part(regexp_replace(l2.label, '[^A-Za-z ]', ' ', 'g'), ' ', 1)) = lower(split_part(regexp_replace(loc.label, '[^A-Za-z ]', ' ', 'g'), ' ', 1));
    if amb is not null then notes := notes || format('"%s" also matches %s; showing %s — name the location to choose. ', split_part(loc.label, ' ', 1), amb, loc.label); end if;
  elsif zg is not null then f := (f - 'location_id') || jsonb_build_object('zone_group', zg); entity := true; end if;
  select family into fam from bi.client c where (q ~ ('\m' || lower(family) || '\M') and family not in ('IDEA', 'OTHERS', 'CRED', 'TEZZ'))
                                            or (family in ('IDEA', 'OTHERS', 'CRED', 'TEZZ') and qo ~ ('\m' || family || '\M')) limit 1;
  if fam is not null then f := f || jsonb_build_object('client_family', fam); entity := true; end if;
  if q ~ '\m(all india|pan india|overall|whole company|company wide|everything)\M' then f := '{}'::jsonb; entity := true; end if;
  if not entity and prev is not null and q ~ '^(why|and|so|then|what about|how about|same|ok)\M|\m(it|there|that|this|they|them|those)\M' then f := prev || f; end if;

  m := coalesce(nullif(ctx->>'month', '')::date, (select max(report_month) from bi.zt_snapshot));
  select i into mm from unnest(array['\m(january|jan)\M', '\m(february|feb)\M', '\m(march)\M', '\m(april|apr)\M', '(\min may\M|\mmay\s+(20)?\d\d\M)', '\m(june|jun)\M',
       '\m(july|jul)\M', '\m(august|aug)\M', '\m(september|sept|sep)\M', '\m(october|oct)\M', '\m(november|nov)\M', '\m(december)\M']) with ordinality t(rx, i) where q ~ rx limit 1;
  if mm is not null then
    yy := (regexp_match(q, '\m(20\d\d)\M'))[1]::int;
    if yy is null then yy := (regexp_match(q, '(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*''?(\d\d)\M'))[1]::int + 2000; end if;
    mx := (select max(report_month) from bi.zt_snapshot);
    m := make_date(coalesce(yy, extract(year from mx)::int), mm, 1);
    if yy is null and m > mx then m := (m - interval '1 year')::date; end if;
  elsif q ~ '\m(last|previous) month''?s?\M' and q !~ '(than|vs\.?|versus|compared|compared to|compared with|against|same point|same day|from|over) (the )?(last|previous) month' then
    m := (m - interval '1 month')::date; notes := notes || format('Showing %s (last month). ', to_char(m, 'Mon YYYY'));
  end if;
  nn := coalesce((regexp_match(q, '\m(\d{1,2})\M'))[1]::int, case when q ~ '\mthree\M' then 3 when q ~ '\mfour\M' then 4 when q ~ '\mfive\M' then 5 when q ~ '\mten\M' then 10 end, 5);

  intent := case
    when q ~ '(phone|mobile number|salary|salaries|home address|aadha|pan card|password|personal detail|date of birth|email id of|whatsapp)' then 'decline'
    when q ~ '^(help|hi|hello|what can you|how do i use|what can i ask)' then 'help'
    when q ~ '(collect|outstanding|receivable|invoice|realis|realiz|payment|overdue|debtor|billing|billed|cash)' then 'collections'
    when q ~ '(force ?1|force one|utili[sz])' and q ~ '(above|over|more than|exceed|100|reconcil|too high|higher than)' then 'force1_recon'
    when q ~ '(data (quality|health|issue|problem|gap)|missing data|stale|freshness|reconcil|upload|data complete|is the data)' then 'health'
    when q ~ '(important|priorit|focus on|biggest (issue|problem|risk)s?|top \d+ (issue|problem|risk)|key (issue|risk)s|what should (i|we)|attention|red flag)' then 'priorities'
    when q ~ '(force ?1|force one|utili[sz]|manual work|back office|back-office|field exec)' then 'force1'
    when q ~ '(\mtat\M|turnaround|turn around|slow|delay|time taken|how long|sla|ageing|aging)' then 'tat'
    when q ~ '(who is|which employee|which person|best performer|worst performer|staff|people|attrition|employee)' then 'people'
    when q ~ '(forecast|projection|projected|month.end|will we (hit|make|reach|achieve)|on track|reach (the )?target|achieve (the )?target)' then 'forecast'
    when q ~ '(shortfall|short of|gap|behind target|below target|miss(ing|ed)? (the )?target|contribut|underperform|lagging|weakest|worst|behind plan)' then 'shortfall'
    when q ~ '(branch|dormant|inactive|traction|new branches|reactivat)' then 'branches'
    when q ~ '(last month|previous month|like for like|\mlfl\M|compared|versus|\mvs\M|lower|higher|increase|decreas|declin|dropped|drops|fell|fall|grow|growth|down|up from|why)' then 'growth'
    when q ~ '(how are we|status|summary|overview|performance|how is business|mtd|month to date|target|achievement|revenue|cases)' then 'overview'
    else case when sec in ('tat') then 'tat' when sec in ('force1') then 'force1' when sec in ('force') then 'force1_recon' when sec in ('quality', 'health') then 'health'
              when sec in ('growth', 'tracker') then 'growth' else 'overview' end end;

  a := case intent
    when 'overview' then bi.ask_h_overview(m, f)
    when 'shortfall' then bi.ask_h_shortfall(m, f)
    when 'growth' then bi.ask_h_growth(m, f, q)
    when 'tat' then bi.ask_h_tat(m, f, q)
    when 'force1' then bi.ask_h_force1(m, f)
    when 'force1_recon' then bi.ask_h_force1_recon(m, f)
    when 'forecast' then bi.ask_h_forecast(m, f)
    when 'health' then bi.ask_h_health(m, f)
    when 'priorities' then bi.ask_h_priorities(m, f, nn)
    when 'branches' then bi.ask_h_branches(m, f)
    when 'people' then jsonb_build_object('answer', 'Ask Crux does not rank or describe named people. Workload, field-executive vs back-office split and TAT by employee are on the Operations pages for those with access.',
        'next', jsonb_build_array('What is Force1 utilisation by location group?', 'Where is TAT increasing?'), 'drill', jsonb_build_array(jsonb_build_object('label', 'Open TAT by employee', 'section', 'tat')), 'confidence', 'high')
    when 'decline' then jsonb_build_object('answer', 'I can''t share personal details about employees or customers. I can give aggregated figures — business, targets, TAT, Force1 utilisation and data health — for any location, zone or client.',
        'next', jsonb_build_array('What are the five most important issues?', 'Where is TAT increasing?'), 'confidence', 'high')
    when 'collections' then jsonb_build_object('answer', 'Collection, invoice and outstanding figures are not in the database yet, so I can''t answer this from data. Revenue figures from the tracker are available.',
        'next', jsonb_build_array('How are we doing this month?', 'Which locations contribute most to the shortfall?'), 'confidence', 'high',
        'limitations', 'Collection and outstanding workbooks have not been integrated yet.')
    else jsonb_build_object('answer', 'I answer from the dashboard''s own data: business vs target and projection, the gap by location or client, change vs the same point last month, Force1 utilisation and reconciliation, TAT (case, field, document), branches and data health. Your current month and filters are used.',
        'next', jsonb_build_array('How are we doing this month?', 'Which locations contribute most to the shortfall?', 'Where is TAT increasing?', 'What are the five most important issues?', 'Why is Force1 above the tracker for some locations?'),
        'confidence', 'high') end;

  scope := case when f - 'client_family' = '{}'::jsonb then 'Pan India'
                else concat_ws(', ', (select label from bi.location where id = nullif(f->>'location_id', '')::int), (select label from bi.zone_group where code = f->>'zone_group'),
                               case when f ? 'region' then 'Region ' || (f->>'region') end, case when f ? 'stakeholder' then 'Stakeholder filter' end) end
           || case when f ? 'client_family' then ' · ' || (f->>'client_family') else ' · all clients' end;
  a := a || jsonb_build_object('conversation_id', conv, 'intent', intent, 'scope', scope, 'period', to_char(m, 'Mon YYYY'), 'month', m, 'filters', f, 'section', nullif(sec, ''),
            'data_version', ver, 'version', 3, 'notes', nullif(trim(notes), ''));
  if a->>'answer' is null then a := a || jsonb_build_object('answer', 'No figures are available for this selection.', 'confidence', 'low'); end if;
  insert into bi.ai_message(conversation_id, question, intent, filters, answer, data_version) values (conv, left(p_question, 500), intent, f, a, ver) returning id into mid;
  return a || jsonb_build_object('message_id', mid);
end $function$;
grant execute on function public.bi_ask3(text, jsonb, uuid) to anon, authenticated;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'ask_crux', 'bi_089c', jsonb_build_object('version', 3, 'register', 'A3'));
