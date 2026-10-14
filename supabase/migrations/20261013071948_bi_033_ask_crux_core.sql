-- Applied to Supabase project via MCP on 20261013071948

create table if not exists bi.ai_conversation (id uuid primary key default gen_random_uuid(), created_at timestamptz default now(), context jsonb);
create table if not exists bi.ai_message (id bigserial primary key, conversation_id uuid references bi.ai_conversation(id) on delete cascade,
  question text not null, intent text, filters jsonb, answer jsonb, data_version bigint, provider text default 'deterministic', model text,
  created_at timestamptz default now(), helpful boolean, correction text, status text default 'unreviewed' check (status in ('unreviewed','validated','disputed')));
create index if not exists ai_message_conv on bi.ai_message(conversation_id, id);
create index if not exists ai_message_fts on bi.ai_message using gin (to_tsvector('english', question));
alter table bi.ai_conversation enable row level security; alter table bi.ai_message enable row level security;

-- like-for-like MTD by group: latest snapshot of month vs previous month's snapshot on/before the same day
create or replace function bi.api_lfl(p_month date, f jsonb, p_group text) returns jsonb
language sql stable security definer set search_path=bi,public as $$
with s1 as (select max(snapshot_date) d from bi.zt_snapshot where report_month=p_month),
s0 as (select max(snapshot_date) d from bi.zt_snapshot where report_month=(p_month - interval '1 month')::date
       and extract(day from snapshot_date) <= extract(day from (select d from s1))),
r as (select z.snapshot_date, case p_group when 'client' then coalesce(c.family, z.client_label) when 'stakeholder' then l.stakeholder when 'zone' then l.zone_group else l.label end k, z.mtd_cases
      from bi.zt_row z left join bi.location l on l.id=z.location_id left join bi.client c on c.code=z.client_code
      where z.row_type='leaf' and z.snapshot_date in ((select d from s1),(select d from s0)) and bi.loc_ok(z.location_id, null, f) and bi.fam_ok(z.client_code, f)),
g as (select k, sum(mtd_cases) filter (where snapshot_date=(select d from s1)) cur, sum(mtd_cases) filter (where snapshot_date=(select d from s0)) prev from r group by k)
select jsonb_build_object('current_snapshot',(select d from s1),'comparison_snapshot',(select d from s0),
  'total_current',(select sum(cur) from g),'total_previous',(select sum(prev) from g),
  'rows',coalesce((select jsonb_agg(jsonb_build_object('group',k,'current',cur,'previous',prev,'change',coalesce(cur,0)-coalesce(prev,0)) order by coalesce(cur,0)-coalesce(prev,0)) from g),'[]'));
$$;

create or replace function public.bi_ask(p_question text, p_context jsonb default '{}', p_conversation uuid default null)
returns jsonb language plpgsql security definer set search_path=bi,public as $$
declare q text := lower(coalesce(p_question,'')); f jsonb := coalesce(p_context->'filters','{}'); m date; intent text; a jsonb; x jsonb; y jsonb;
        conv uuid := p_conversation; prev jsonb; txt text; nums jsonb := '[]'; src jsonb := '[]'; meth text; conf text := 'high'; lim text := ''; nxt text := '';
        loc record; fam text; ver bigint := (select coalesce(max(id),0) from bi.audit_log); mid bigint;
begin
  if length(q) < 3 or length(q) > 500 then return jsonb_build_object('error','Ask a question between 3 and 500 characters.'); end if;
  if (select count(*) from bi.ai_message where created_at > now() - interval '1 hour') > 600 then return jsonb_build_object('error','Ask Crux is busy (hourly limit). Try again shortly.'); end if;
  if conv is not null and (select count(*) from bi.ai_message where conversation_id=conv and created_at > now() - interval '10 minutes') > 30 then
    return jsonb_build_object('error','Too many questions in a short time. Please wait a few minutes.'); end if;
  if conv is null or not exists (select 1 from bi.ai_conversation where id=conv) then insert into bi.ai_conversation(context) values (p_context) returning id into conv;
  else select filters into prev from bi.ai_message where conversation_id=conv order by id desc limit 1; end if;
  -- follow-ups inherit previous filters; explicit mentions override
  f := coalesce(prev,'{}') || f;
  select id, label into loc from bi.location where q like '%'||lower(split_part(regexp_replace(label,'[^A-Za-z ]',' ','g'),' ',1))||'%' and length(split_part(regexp_replace(label,'[^A-Za-z ]',' ','g'),' ',1))>=4 order by length(label) limit 1;
  if loc.id is not null then f := f || jsonb_build_object('location_id', loc.id); end if;
  select family into fam from bi.client where q ~ ('\m'||lower(family)||'\M') limit 1;
  if fam is not null then f := f || jsonb_build_object('client_family', fam); end if;
  if q ~ '\m(all india|overall|pan india|everything)\M' then f := '{}'; end if;
  m := coalesce(nullif(p_context->>'month','')::date, (select max(report_month) from bi.zt_snapshot));

  intent := case
    when q ~ '(branch|dormant|opportunit|potential|recover|leak|inactive|traction)' then 'branches'
    when q ~ '(force1|force 1|utilis|utiliz|manual)' then 'force1'
    when q ~ '(manpower|field exec|back office|backoffice|people|staff|employee|workload|attrition)' then 'people'
    when q ~ '(tat|turnaround|sla|delay)' then 'tat'
    when q ~ '(forecast|month.end|projection|project|expect|will we)' then 'forecast'
    when q ~ '(upload|changed|last update|latest data|refresh)' then 'upload'
    when q ~ '(year|yoy|last year|grow|growth)' then 'growth'
    when q ~ '(why|lower|decline|drop|down|fall|less|reduce|which location|which client|contribut)' then 'decline'
    else 'overview' end;

  if intent = 'decline' or intent = 'overview' then
    a := bi.api_lfl(m, f, case when q ~ 'client' then 'client' when q ~ 'stakeholder' then 'stakeholder' else 'location' end);
    x := bi.api_overview(m, f);
    txt := format('MTD cases as of %s: %s, vs %s at the same point last month (%s) — change %s.',
      a->>'current_snapshot', a->>'total_current', coalesce(a->>'total_previous','n/a'), coalesce(a->>'comparison_snapshot','n/a'),
      coalesce(((a->>'total_current')::numeric - (a->>'total_previous')::numeric)::text,'n/a'));
    if intent='decline' then
      txt := txt || ' Largest decreases: ' || coalesce((select string_agg(format('%s %s', e->>'group', e->>'change'), '; ') from (select e from jsonb_array_elements(a->'rows') e where (e->>'change')::numeric < 0 limit 5) z),'none') ||
             '. Largest increases: ' || coalesce((select string_agg(format('%s +%s', e->>'group', e->>'change'), '; ') from (select e from jsonb_array_elements(a->'rows') e where (e->>'change')::numeric > 0 order by (e->>'change')::numeric desc limit 3) z),'none') || '.';
      nxt := 'Open Growth & trends for the full breakdown; check Data quality for missing snapshots before acting on a drop.';
    else
      txt := txt || format(' Target %s, achievement %s%%, projected month-end %s.', x->>'target_cases', round((x->>'achievement')::numeric*100,1), coalesce(x->'forecast'->>'run_rate_projection','n/a'));
    end if;
    nums := jsonb_build_array(jsonb_build_object('metric','MTD cases','value',a->'total_current'),jsonb_build_object('metric','Same day last month','value',a->'total_previous'));
    src := '["Zonal Tracker leaf rows (bi.v_zt_leaf via bi.api_lfl)","bi.api_overview"]'; meth := 'Like-for-like: latest snapshot of the month vs previous month''s snapshot on or before the same day. Cumulative MTD values compared, never summed.';
    if a->>'comparison_snapshot' is null then conf := 'low'; lim := 'No comparable snapshot in the previous month.'; end if;
  elsif intent = 'branches' then
    a := bi.api_branches(f);
    txt := format('Branches seen in Force1 Case Wise: %s. Status — growing %s, stable %s, losing traction %s, dormant %s, reactivated %s, new %s, insufficient data %s. Top priorities: %s.',
      (select sum(v::int) from jsonb_each_text(a->'summary') t(k,v)), coalesce(a->'summary'->>'growing','0'), coalesce(a->'summary'->>'stable','0'), coalesce(a->'summary'->>'losing_traction','0'),
      coalesce(a->'summary'->>'dormant','0'), coalesce(a->'summary'->>'reactivated','0'), coalesce(a->'summary'->>'new','0'), coalesce(a->'summary'->>'insufficient_data','0'),
      coalesce((select string_agg(format('%s %s (%s, %s→%s cases/3m)', e->>'client', e->>'branch', e->>'status', e->>'prior3m', e->>'last3m'), '; ') from (select e from jsonb_array_elements(a->'priority') e limit 5) z),'none'));
    src := '["Force1 Case Wise (bi.case_store) via bi.api_branches"]'; meth := a->'method'->>'rules'; conf := 'medium';
    lim := 'Branch universe = branches seen in Force1 only; verified client branch master not yet supplied, so coverage % and never-activated branches cannot be computed. Opportunity values are peer-based estimates, not confirmed leakage.';
    nxt := 'Business tracker → Branch lifecycle for the full prioritised list.';
  elsif intent = 'force1' or intent = 'people' then
    y := bi.api_force1((select max(created_month) from bi.point_derived), f); x := bi.api_force1(m, f);
    txt := format('Case-level Force1 utilisation %s: %s%% (%s of %s tracker cases). Field-level (latest month with Point Wise data, %s): %s%% — field executives submitted %s field points, back office %s manually. Active: %s field executives, %s back-office staff; field points per executive %s, per back-office person %s.',
      to_char(m,'Mon YYYY'), round((x->'totals'->>'case_utilisation')::numeric*100,1), x->'totals'->>'force1_cases', x->'totals'->>'tracker_cases',
      to_char((y->>'month')::date,'Mon YYYY'), round((y->'totals'->>'field_utilisation')::numeric*100,1), y->'totals'->>'f1_field', y->'totals'->>'manual_field',
      y->'totals'->>'field_execs', y->'totals'->>'back_office_staff', y->'totals'->>'field_points_per_exec', y->'totals'->>'manual_field_per_back_office_person');
    if intent='people' then txt := txt || ' Lowest field Force1 share: ' || coalesce((select string_agg(format('%s %s%%', e->>'recon_unit', round((e->>'field_utilisation')::numeric*100)), '; ')
        from (select e from jsonb_array_elements(y->'by_unit') e where e->>'field_utilisation' is not null order by (e->>'field_utilisation')::numeric limit 3) z),'n/a') || '.'; end if;
    src := '["bi.api_force1 (Case Wise, Zonal Tracker, Point Wise)"]'; meth := (x->'definitions'->>'case_utilisation')||'. '||(x->'definitions'->>'field_utilisation');
    lim := 'Point Wise data ends '||to_char((y->>'month')::date,'Mon YYYY')||'. Attrition needs a workforce master (joining/exit dates) not yet supplied.';
  elsif intent = 'tat' then
    x := bi.api_overview(m, f);
    txt := format('Case TAT %s: median %s h, P90 %s h over %s completed cases; SLA met %s%%; %s open.', to_char(m,'Mon YYYY'), x->'case_tat'->>'median_hours', x->'case_tat'->>'p90_hours',
      x->'case_tat'->>'completed_valid', round((x->'case_tat'->>'sla_met_pct')::numeric*100,1), x->'case_tat'->>'open');
    src := '["Force1 Case Wise via bi.api_overview"]'; meth := 'TAT = Completed − Received; SLA met = completed by Force1 due time; negative durations excluded.';
  elsif intent = 'forecast' then
    x := bi.api_forecast(m, f);
    txt := format('Month-end projection for %s: run-rate %s; historical-curve %s (range %s–%s). Assumptions: %s', to_char(m,'Mon YYYY'), x->>'run_rate_projection', x->>'curve_projection',
      x->'curve_range'->>0, x->'curve_range'->>1, x->>'method_note');
    src := '["bi.api_forecast"]'; meth := x->>'method_note'; conf := 'medium'; lim := 'Projection, not a guarantee.';
  elsif intent = 'upload' then
    txt := 'Latest data loads: ' || (select string_agg(format('%s %s (%s, %s rows)', source_category, coalesce(snapshot_date::text, to_char(period_month,'Mon YYYY')), file_name, rows_in), '; ')
       from (select * from bi.import_batch where status='committed' order by coalesce(committed_at, created_at) desc limit 5) b) || '.';
    src := '["bi.import_batch"]'; meth := 'Most recent committed imports.';
  elsif intent = 'growth' then
    x := bi.api_monthly((m - interval '13 months')::date, m, f, 'total');
    txt := 'Monthly cases (complete months): ' || (select string_agg(format('%s %s', to_char((e->>'month')::date,'Mon YY'), e->>'cases'), '; ' order by e->>'month') from jsonb_array_elements(x) e where (e->>'month')::date < m) || '.';
    src := '["Zonal Tracker history (bi.api_monthly)"]'; meth := 'Complete months only; current month is month-to-date and excluded from MoM/YoY.';
    lim := 'Organic vs new-client attribution needs management-approved classification fields (not yet supplied); shown as unattributed.';
  end if;

  a := jsonb_build_object('conversation_id', conv, 'intent', intent, 'answer', txt, 'period', to_char(m,'Mon YYYY'), 'filters', f,
        'numbers', nums, 'sources', src, 'method', meth, 'confidence', conf, 'limitations', nullif(lim,''), 'next_steps', nullif(nxt,''), 'data_version', ver,
        'related', (select jsonb_agg(jsonb_build_object('question', question, 'asked', created_at::date, 'status', status)) from (select question, created_at, status from bi.ai_message
                     where status <> 'disputed' and to_tsvector('english', question) @@ plainto_tsquery('english', p_question) order by created_at desc limit 3) r));
  insert into bi.ai_message(conversation_id, question, intent, filters, answer, data_version) values (conv, left(p_question,500), intent, f, a, ver) returning id into mid;
  return a || jsonb_build_object('message_id', mid);
end $$;

create or replace function public.bi_feedback(p_message bigint, p_helpful boolean, p_correction text default null) returns jsonb
language sql security definer set search_path=bi,public as $$
  update bi.ai_message set helpful=p_helpful, correction=left(p_correction,1000), status=case when p_helpful is false and p_correction is not null then 'disputed' else status end
  where id=p_message and created_at > now() - interval '1 day' returning jsonb_build_object('ok',true) $$;
grant execute on function public.bi_ask(text,jsonb,uuid), public.bi_feedback(bigint,boolean,text) to anon, authenticated;
revoke all on function bi.api_lfl(date,jsonb,text) from public, anon, authenticated;

