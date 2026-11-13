-- Applied to Supabase project via MCP on 20261113173518
-- wave 110a (13-Nov-2026 22:58 IST, owner): (1) partner / own branch as a pre-filled grid; (2) manual DAILY numbers for locations not on Force1 — the same
-- figures Force1 gives (received, completed, pending, within TAT, case and field TAT, field visits, staff), not case-wise data; (3) learning that works:
-- question trends (type, variations, frequency, feedback) for the page and the agents, and lessons tested and applied by an agent.

create or replace function bi.operating_model_grid() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with mx as (select max(month) m from bi.v_month_business),
  biz as (select coalesce(c.family, mb.client_code) fam, mb.location_id loc, sum(mb.cases) cases, round(sum(mb.revenue)) revenue, max(mb.month) last_m
            from bi.v_month_business mb join bi.location l on l.id = mb.location_id and not l.is_rollup left join bi.client c on c.code = mb.client_code
           where mb.month >= (select m from mx) - interval '5 months' and (coalesce(mb.cases, 0) > 0 or coalesce(mb.revenue, 0) > 0) group by 1, 2),
  pairs as (select fam, loc from biz union select client_family, location_id from bi.operating_model where client_code is null),
  cur as (select distinct on (client_family, location_id) * from bi.operating_model
           where client_code is null and valid_from <= current_date and (valid_to is null or valid_to >= current_date) order by client_family, location_id, valid_from desc),
  hist as (select client_family, location_id, count(*) n from bi.operating_model where client_code is null group by 1, 2)
  select coalesce(jsonb_agg(jsonb_build_object('client_family', p.fam, 'location_id', p.loc, 'location', l.label, 'zone_group', l.zone_group,
           'cases_6m', b.cases, 'revenue_6m', b.revenue, 'last_month', b.last_m, 'id', c.id, 'model', c.model, 'valid_from', c.valid_from, 'valid_to', c.valid_to,
           'partner_name', c.partner_name, 'periods', coalesce(h.n, 0))
           order by l.zone_group, l.label, coalesce(b.revenue, 0) desc), '[]'::jsonb)
    from pairs p join bi.location l on l.id = p.loc left join biz b on b.fam = p.fam and b.loc = p.loc
    left join cur c on c.client_family = p.fam and c.location_id = p.loc left join hist h on h.client_family = p.fam and h.location_id = p.loc
$f$;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $f$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $f$;
select pg_temp.patch('bi.operating_model_admin(text,jsonb)'::regprocedure, array[
  E'  elsif op = ''save'' then\n    return bi.operating_model_save(p_actor, jsonb_build_array(p->''row''), false);',
  E'  elsif op = ''save'' then\n    return bi.operating_model_save(p_actor, jsonb_build_array(p->''row''), false);\n  elsif op = ''save_many'' then   -- wave 110a: the grid saves only the rows that changed\n    return bi.operating_model_save(p_actor, coalesce(p->''rows'', ''[]''), false);\n  elsif op = ''grid'' then\n    return jsonb_build_object(''rows'', bi.operating_model_grid());'], array[1]);

create table if not exists bi.manual_ops_daily (
  id bigserial primary key,
  day date not null,
  location_id int not null references bi.location(id),
  client_family text,
  cases_received int check (cases_received >= 0),
  cases_completed int check (cases_completed >= 0),
  cases_pending_eod int check (cases_pending_eod >= 0),
  pending_past_due int check (pending_past_due >= 0),
  completed_within_tat int check (completed_within_tat >= 0),
  avg_case_tat_hours numeric(8,1) check (avg_case_tat_hours >= 0),
  field_visits_done int check (field_visits_done >= 0),
  avg_field_tat_hours numeric(8,1) check (avg_field_tat_hours >= 0),
  document_checks_done int check (document_checks_done >= 0),
  field_staff_working int check (field_staff_working >= 0),
  office_staff_working int check (office_staff_working >= 0),
  remarks text, source text, updated_by text, updated_at timestamptz not null default now(),
  check (completed_within_tat is null or cases_completed is null or completed_within_tat <= cases_completed));
create unique index if not exists manual_ops_daily_key on bi.manual_ops_daily (day, location_id, coalesce(client_family, ''));
alter table bi.manual_ops_daily enable row level security;
revoke all on bi.manual_ops_daily from anon, authenticated;
comment on table bi.manual_ops_daily is 'Daily numbers sent by locations (or clients) that do not work on Force1: the same figures Force1 gives — cases received, completed, pending, within TAT, case and field TAT, field visits, document checks, staff working. No case-wise data. Wave 110a.';

create or replace function bi.try_int(x text) returns int language sql immutable as $f$
  select case when trim(coalesce(x, '')) ~ '^\d+(\.0+)?$' then trim(x)::numeric::int end $f$;
create or replace function bi.try_num(x text) returns numeric language sql immutable as $f$
  select case when trim(coalesce(x, '')) ~ '^\d+(\.\d+)?$' then trim(x)::numeric end $f$;

create or replace function bi.manual_ops_save(p_actor text, p_rows jsonb, p_dry boolean) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare res jsonb;
begin
  if jsonb_array_length(coalesce(p_rows, '[]')) > 20000 then raise exception 'At most 20,000 rows per upload'; end if;
  with src as (select o rn, x from jsonb_array_elements(coalesce(p_rows, '[]')) with ordinality t(x, o)),
  v as (select rn, x, bi.try_date(x->>'date') as day,
          (select id from bi.location l where not l.is_rollup and (upper(l.code) = upper(trim(x->>'location')) or upper(l.label) = upper(trim(x->>'location'))) limit 1) location_id,
          nullif(trim(x->>'client'), '') client_raw,
          case when nullif(trim(x->>'client'), '') is null or upper(trim(x->>'client')) in ('ALL', 'ALL CLIENTS') then null
               else coalesce((select family from bi.client where upper(family) = upper(trim(x->>'client')) limit 1),
                             (select family from bi.client where upper(code) = upper(trim(x->>'client')) or upper(label) = upper(trim(x->>'client')) limit 1)) end client_family,
          bi.try_int(x->>'cases_received') cases_received, bi.try_int(x->>'cases_completed') cases_completed, bi.try_int(x->>'cases_pending_end_of_day') cases_pending_eod,
          bi.try_int(x->>'pending_past_due') pending_past_due, bi.try_int(x->>'completed_within_tat') completed_within_tat, bi.try_num(x->>'avg_case_tat_hours') avg_case_tat_hours,
          bi.try_int(x->>'field_visits_done') field_visits_done, bi.try_num(x->>'avg_field_tat_hours') avg_field_tat_hours, bi.try_int(x->>'document_checks_done') document_checks_done,
          bi.try_int(x->>'field_staff_working') field_staff_working, bi.try_int(x->>'office_staff_working') office_staff_working,
          nullif(trim(x->>'remarks'), '') remarks, coalesce(nullif(trim(x->>'source'), ''), nullif(trim(p_rows->0->>'_file'), '')) source
        from src),
  e as (select v.*, array_remove(array[
          case when day is null then 'date is required (e.g. 13-11-2026)' end,
          case when day > current_date then 'date is in the future' end,
          case when location_id is null then 'unknown location "' || coalesce(x->>'location', '') || '"' end,
          case when client_raw is not null and upper(client_raw) not in ('ALL', 'ALL CLIENTS') and client_family is null then 'unknown client "' || client_raw || '"' end,
          case when cases_received is null and cases_completed is null and field_visits_done is null then 'give at least cases_received, cases_completed or field_visits_done' end,
          case when nullif(trim(x->>'cases_received'), '') is not null and cases_received is null then 'cases_received must be a whole number' end,
          case when nullif(trim(x->>'cases_completed'), '') is not null and cases_completed is null then 'cases_completed must be a whole number' end,
          case when nullif(trim(x->>'cases_pending_end_of_day'), '') is not null and cases_pending_eod is null then 'cases_pending_end_of_day must be a whole number' end,
          case when nullif(trim(x->>'completed_within_tat'), '') is not null and completed_within_tat is null then 'completed_within_tat must be a whole number' end,
          case when completed_within_tat > cases_completed then 'completed_within_tat is more than cases_completed' end,
          case when pending_past_due > cases_pending_eod then 'pending_past_due is more than cases_pending_end_of_day' end,
          case when nullif(trim(x->>'avg_case_tat_hours'), '') is not null and avg_case_tat_hours is null then 'avg_case_tat_hours must be a number of hours' end,
          case when nullif(trim(x->>'avg_field_tat_hours'), '') is not null and avg_field_tat_hours is null then 'avg_field_tat_hours must be a number of hours' end,
          case when avg_case_tat_hours > 2000 or avg_field_tat_hours > 2000 then 'TAT over 2,000 hours: check the unit (hours)' end], null) errs from v),
  dup as (select e.day, e.location_id, coalesce(e.client_family, '') cf from e where e.day is not null and e.location_id is not null group by 1, 2, 3 having count(*) > 1),
  e2 as (select e.*, case when exists (select 1 from dup d where d.day = e.day and d.location_id = e.location_id and d.cf = coalesce(e.client_family, ''))
                     then e.errs || 'same date, location and client repeated in this file'::text else e.errs end errs2 from e),
  ok as (select * from e2 where cardinality(errs2) = 0),
  ins as (insert into bi.manual_ops_daily (day, location_id, client_family, cases_received, cases_completed, cases_pending_eod, pending_past_due, completed_within_tat, avg_case_tat_hours,
                                           field_visits_done, avg_field_tat_hours, document_checks_done, field_staff_working, office_staff_working, remarks, source, updated_by)
          select ok.day, ok.location_id, ok.client_family, ok.cases_received, ok.cases_completed, ok.cases_pending_eod, ok.pending_past_due, ok.completed_within_tat, ok.avg_case_tat_hours,
                 ok.field_visits_done, ok.avg_field_tat_hours, ok.document_checks_done, ok.field_staff_working, ok.office_staff_working, ok.remarks, ok.source, p_actor
            from ok where not p_dry
          on conflict (day, location_id, coalesce(client_family, '')) do update set cases_received = excluded.cases_received, cases_completed = excluded.cases_completed,
            cases_pending_eod = excluded.cases_pending_eod, pending_past_due = excluded.pending_past_due, completed_within_tat = excluded.completed_within_tat,
            avg_case_tat_hours = excluded.avg_case_tat_hours, field_visits_done = excluded.field_visits_done, avg_field_tat_hours = excluded.avg_field_tat_hours,
            document_checks_done = excluded.document_checks_done, field_staff_working = excluded.field_staff_working, office_staff_working = excluded.office_staff_working,
            remarks = excluded.remarks, source = excluded.source, updated_by = excluded.updated_by, updated_at = now()
          returning (xmax = 0) inserted)
  select jsonb_build_object('kind', 'manual_ops', 'dry_run', p_dry, 'rows', (select count(*) from e2), 'valid', (select count(*) from ok), 'invalid', (select count(*) from e2 where cardinality(errs2) > 0),
    'inserted', (select count(*) from ins where inserted), 'updated', (select count(*) from ins where not inserted),
    'already_in_master', (select count(*) from ok where exists (select 1 from bi.manual_ops_daily w where w.day = ok.day and w.location_id = ok.location_id and coalesce(w.client_family, '') = coalesce(ok.client_family, ''))),
    'cases_reported', (select coalesce(sum(ok.cases_received), 0) from ok), 'points_reported', (select coalesce(sum(ok.field_visits_done), 0) from ok),
    'days', (select jsonb_build_object('from', min(ok.day), 'to', max(ok.day), 'locations', count(distinct ok.location_id)) from ok),
    'by_client', (select coalesce(jsonb_object_agg(q.loc, q.n), '{}') from (select l.label loc, count(*) n from ok join bi.location l on l.id = ok.location_id group by 1) q),
    'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', z.rn, 'client', coalesce(z.x->>'client', 'All'), 'key', coalesce(z.x->>'location', '') || ' · ' || coalesce(z.x->>'date', ''), 'errors', to_jsonb(z.errs2)) order by z.rn), '[]')
               from (select * from e2 where cardinality(e2.errs2) > 0 order by e2.rn limit 200) z))
  into res;
  if not p_dry then insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'manual_ops_import', 'manual_ops_daily', res - 'errors'); end if;
  return res;
end $f$;

create or replace function bi.api_manual_ops(p_month date, f jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with mm as (select coalesce(p_month, date_trunc('month', current_date)::date) m),
  d as (select w.*, l.label loc, l.zone_group, coalesce(l.recon_unit, l.label) unit from bi.manual_ops_daily w join bi.location l on l.id = w.location_id
         where w.day >= (select m from mm) and w.day < (select m from mm) + interval '1 month' and bi.loc_ok(w.location_id, l.recon_unit, f, (select m from mm))
           and (f->>'client_family' is null or w.client_family = f->>'client_family' or w.client_family is null)),
  lastday as (select location_id, max(day) dmax from d group by 1),
  pend as (select d.location_id, sum(d.cases_pending_eod) pending, sum(d.pending_past_due) past_due from d join lastday x on x.location_id = d.location_id and x.dmax = d.day group by 1),
  agg as (select location_id, loc, zone_group, unit, count(distinct day) days, max(day) last_day, sum(cases_received) received, sum(cases_completed) completed, sum(completed_within_tat) within_tat,
                 round(sum(avg_case_tat_hours * cases_completed) / nullif(sum(cases_completed) filter (where avg_case_tat_hours is not null), 0), 1) case_tat_h,
                 sum(field_visits_done) visits, round(sum(avg_field_tat_hours * field_visits_done) / nullif(sum(field_visits_done) filter (where avg_field_tat_hours is not null), 0), 1) field_tat_h,
                 sum(document_checks_done) docs, sum(field_staff_working) field_staff_days, sum(office_staff_working) office_staff_days
            from d group by 1, 2, 3, 4)
  select jsonb_build_object('month', (select m from mm),
    'method', 'Numbers sent daily by locations not on Force1. TAT is the average reported for the day, weighted by cases completed (case TAT) or visits (field TAT); SLA = completed within TAT ÷ completed; pending = the last reported day.',
    'totals', (select jsonb_build_object('locations', count(*), 'days', sum(days), 'received', sum(received), 'completed', sum(completed), 'within_tat', sum(within_tat),
                 'sla_pct', round(100.0 * sum(within_tat) / nullif(sum(completed) filter (where within_tat is not null), 0), 1),
                 'case_tat_h', round(sum(case_tat_h * completed) / nullif(sum(completed) filter (where case_tat_h is not null), 0), 1),
                 'visits', sum(visits), 'field_tat_h', round(sum(field_tat_h * visits) / nullif(sum(visits) filter (where field_tat_h is not null), 0), 1),
                 'pending', (select sum(pending) from pend), 'past_due', (select sum(past_due) from pend), 'field_staff_days', sum(field_staff_days)) from agg),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('location_id', a.location_id, 'location', a.loc, 'zone_group', a.zone_group, 'unit', a.unit, 'days', a.days, 'last_day', a.last_day,
                 'stale_days', current_date - a.last_day, 'received', a.received, 'completed', a.completed, 'within_tat', a.within_tat,
                 'sla_pct', round(100.0 * a.within_tat / nullif(a.completed, 0), 1), 'case_tat_h', a.case_tat_h, 'visits', a.visits, 'field_tat_h', a.field_tat_h, 'documents', a.docs,
                 'pending', p.pending, 'past_due', p.past_due, 'field_staff_per_day', round(a.field_staff_days::numeric / nullif(a.days, 0), 1)) order by a.zone_group, a.loc), '[]')
                 from agg a left join pend p on p.location_id = a.location_id),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'received', r, 'completed', c, 'visits', v) order by day), '[]')
                from (select day, sum(cases_received) r, sum(cases_completed) c, sum(field_visits_done) v from d group by day) q))
$f$;

create or replace function bi.api_force1_gap(p_month date, f jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with mm as (select coalesce(p_month, (select max(month) from bi.v_force_usage)) m),
  u as (select v.recon_unit, sum(v.tracker_cases) tracker, sum(v.force_cases) force1, bool_and(v.case_data_available) data_ok, max(v.tracker_as_of) as_of
          from bi.v_force_usage v where v.month = (select m from mm) and bi.loc_ok(null, v.recon_unit, f - 'location_id')
           and (f->>'client_family' is null or v.client_family = f->>'client_family') group by v.recon_unit),
  r as (select coalesce(l.recon_unit, l.label) recon_unit, count(distinct w.day) days, sum(w.cases_received) cases, sum(w.field_visits_done) points, max(w.day) last_day
          from bi.manual_ops_daily w join bi.location l on l.id = w.location_id
         where w.day >= (select m from mm) and w.day < (select m from mm) + interval '1 month' and bi.loc_ok(w.location_id, l.recon_unit, f, (select m from mm))
           and (f->>'client_family' is null or w.client_family = f->>'client_family' or w.client_family is null) group by 1),
  j as (select coalesce(u.recon_unit, r.recon_unit) unit, coalesce(u.tracker, 0) tracker, coalesce(u.force1, 0) force1, coalesce(r.days, 0) days_reported, r.last_day,
               coalesce(r.cases, 0) reported, coalesce(r.points, 0) points, u.data_ok
          from u full join r on r.recon_unit = u.recon_unit)
  select jsonb_build_object('month', (select m from mm), 'as_of', (select max(as_of) from u),
    'method', 'Gap = Zonal Tracker cases − Force1 cases for the location group (never below zero). Reported = cases received on the daily manual reports for that month. Still open = gap − reported.',
    'totals', (select jsonb_build_object('tracker', sum(tracker), 'force1', sum(force1), 'gap', sum(greatest(tracker - force1, 0)), 'reported', sum(reported),
                 'still_open', sum(greatest(greatest(tracker - force1, 0) - reported, 0)), 'days_reported', sum(days_reported), 'points', sum(points)) from j),
    'units', (select coalesce(jsonb_agg(jsonb_build_object('unit', unit, 'tracker', tracker, 'force1', force1, 'gap', greatest(tracker - force1, 0), 'reported', reported,
               'still_open', greatest(greatest(tracker - force1, 0) - reported, 0), 'over_reported', greatest(reported - greatest(tracker - force1, 0), 0),
               'days_reported', days_reported, 'last_day', last_day, 'points', points,
               'covered_pct', case when tracker > 0 then round(100.0 * least(force1 + reported, tracker) / tracker, 1) end, 'case_data', data_ok)
               order by greatest(greatest(tracker - force1, 0) - reported, 0) desc), '[]') from j))
$f$;

create or replace function bi.manual_ops_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'list'); m date := bi.try_month(p->>'month'); n int;
begin
  if op = 'list' then
    return jsonb_build_object('rows', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'day', w.day, 'location', l.label, 'zone_group', l.zone_group, 'client', coalesce(w.client_family, 'All clients'),
             'received', w.cases_received, 'completed', w.cases_completed, 'pending', w.cases_pending_eod, 'past_due', w.pending_past_due, 'within_tat', w.completed_within_tat,
             'case_tat_h', w.avg_case_tat_hours, 'visits', w.field_visits_done, 'field_tat_h', w.avg_field_tat_hours, 'documents', w.document_checks_done,
             'field_staff', w.field_staff_working, 'office_staff', w.office_staff_working, 'remarks', w.remarks, 'source', w.source,
             'updated', to_char(w.updated_at at time zone 'Asia/Kolkata', 'DD-Mon HH24:MI') || ' · ' || replace(coalesce(w.updated_by, ''), 'admin-key:', ''))
             order by w.day desc, l.label), '[]')
           from bi.manual_ops_daily w join bi.location l on l.id = w.location_id where m is null or date_trunc('month', w.day) = m));
  elsif op = 'delete' then
    delete from bi.manual_ops_daily where id = (p->>'id')::bigint;
    get diagnostics n = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'manual_ops_delete', 'manual_ops_daily', p->>'id', jsonb_build_object('deleted', n));
    return jsonb_build_object('deleted', n);
  end if;
  raise exception 'op must be list or delete';
end $f$;

create or replace function bi.api_ask_trends(p jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with prm as (select least(greatest(coalesce((p->>'days')::int, 14), 1), 90) d, coalesce((p->>'admin')::boolean, false) adm, nullif(p->>'section', '') sec),
  m as (select m.id, m.question, m.created_at, m.helpful, m.mode, coalesce(o.section, '') section, coalesce(o.admin, true) adm, o.kind okind, o.title
          from bi.ai_message m left join lateral (select a.section, a.admin, a.kind, a.title from bi.ask_origin a where a.message_id = m.id order by a.id desc limit 1) o on true
         where m.created_at > now() - make_interval(days => (select d from prm)) and length(m.question) between 6 and 300),
  v as (select * from m where ((select adm from prm) or not m.adm)
          and not exists (select 1 from bi.employee e where length(e.name_key) >= 8 and upper(m.question) like '%' || e.name_key || '%')),
  t as (select v.*, case
     when question ~* '\m(how many|count|counts|number of|no\.? of)\M' then 'count'
     when question ~* '\m(why|reason|root cause|explain)\M' then 'why'
     when question ~* '\m(compare|comparison|versus|vs)\M' then 'compare'
     when question ~* '\m(list|which|names?|details?)\M' then 'list'
     when question ~* '\m(trend|growth|grew|mom|yoy|qoq|over time)\M' then 'trend'
     when question ~* '\m(target|shortfall|achiev\w*|pace|likely)\M' then 'target'
     when question ~* '\m(tat|turnaround|sla|backlog|pending|force1)\M' then 'operations'
     when question ~* '\m(collections?|outstanding|receivables?|ageing|realisation)\M' then 'collections'
     when question ~* '\m(potential|bau|opportunit\w*|organic)\M' then 'potential'
     when question ~* '\m(revenue|business|amount|value)\M' then 'value'
     else 'other' end qtype,
     (select string_agg(w, ' ' order by w) from (select distinct case when length(w) > 4 and w ~ 's$' then left(w, -1) else w end w
        from regexp_split_to_table(lower(regexp_replace(question, '[^A-Za-z ]', ' ', 'g')), '\s+') w
        where length(w) > 2 and w not in ('the','and','for','give','gave','me','what','show','please','all','this','that','with','how','many','much','can','you','are','was','were','from',
          'data','its','our','have','has','get','tell','about','does','did','there','their','them','which','who','when','where','why','also','same','into','per','any','some','let','see',
          'want','need','only','not','but','now','then','than','more','most','each','every','list','details','detail','count','number','total')) z) sig
     from v),
  cl as (select qtype, coalesce(sig, '') sig, count(*) n, count(distinct lower(trim(question))) variations, max(created_at) last_at,
                (array_agg(question order by created_at desc))[1] question, count(*) filter (where helpful) helpful_yes, count(*) filter (where helpful is false) helpful_no,
                mode() within group (order by nullif(section, '')) section
           from t where (select sec from prm) is null or section = (select sec from prm) group by 1, 2)
  select jsonb_build_object('days', (select d from prm), 'questions', (select count(*) from t),
    'clusters', (select coalesce(jsonb_agg(jsonb_build_object('question', question, 'type', qtype, 'asked', n, 'variations', variations, 'helpful_yes', helpful_yes, 'helpful_no', helpful_no,
                   'section', section, 'last', to_char(last_at at time zone 'Asia/Kolkata', 'DD-Mon HH24:MI')) order by n desc, last_at desc), '[]')
                 from (select * from cl order by n desc, last_at desc limit 25) z),
    'by_type', (select coalesce(jsonb_object_agg(qtype, n), '{}') from (select qtype, count(*) n from t group by 1) q),
    'by_section', (select coalesce(jsonb_object_agg(s, n), '{}') from (select nullif(section, '') s, count(*) n from t where nullif(section, '') is not null group by 1) q),
    'elements', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'kind', okind, 'section', section, 'asked', n) order by n desc), '[]')
                 from (select title, okind, section, count(*) n from t where title is not null and okind in ('tile', 'table', 'chart', 'card') group by 1, 2, 3 order by 4 desc limit 12) q),
    'feedback', (select jsonb_build_object('helpful', count(*) filter (where helpful), 'not_helpful', count(*) filter (where helpful is false)) from t))
$f$;

create or replace function bi.agent_lessons(p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
begin
  if coalesce(p->>'do', 'list') = 'list' then
    return jsonb_build_object('proposed', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'question', question, 'lesson', lesson, 'created_at', created_at) order by id), '[]')
                                           from (select * from bi.ai_lesson where status = 'proposed' order by id limit 6) q),
                              'active', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'question', question, 'lesson', lesson) order by id), '[]') from bi.ai_lesson where status = 'active'));
  elsif p->>'do' = 'decide' then
    update bi.ai_lesson set status = p->>'status', decided_at = now(), decided_by = coalesce(p->>'by', 'quality agent')
     where id = (p->>'id')::bigint and status = 'proposed' and p->>'status' in ('active', 'rejected');
    return jsonb_build_object('ok', found);
  end if;
  raise exception 'do must be list or decide';
end $f$;

select pg_temp.patch('public.bi_ai_gateway(jsonb)'::regprocedure, array[
  E'  elsif op = ''memory_read'' then return bi.agent_memory_read(p);',
  E'  elsif op = ''memory_read'' then return bi.agent_memory_read(p);\n  elsif op = ''lessons'' then return bi.agent_lessons(p);   -- wave 110a\n  elsif op = ''ask_trends'' then return bi.api_ask_trends(p || ''{"admin": true}'');'], array[1]);
select pg_temp.patch('bi.master_import(text,jsonb)'::regprocedure, array[
  E'  elsif k = ''non_force1'' then',
  E'  elsif k = ''manual_ops'' then   -- wave 110a\n    return bi.manual_ops_save(p_actor, coalesce(p->''rows'', ''[]''), dry);\n  elsif k = ''non_force1'' then'], array[1]);
select pg_temp.patch('public.bi_admin(text,jsonb)'::regprocedure, array[
  E'    when ''non_force1'' then return bi.non_force1_admin(',
  E'    when ''manual_ops'' then return bi.manual_ops_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');   -- wave 110a\n    when ''ask_trends'' then return bi.api_ask_trends(jsonb_build_object(''days'', coalesce((p->>''days'')::int, 14), ''admin'', true));\n    when ''non_force1'' then return bi.non_force1_admin('], array[1]);
select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  E'      when ''force1_gap'' then bi.api_force1_gap(m, f)',
  E'      when ''force1_gap'' then bi.api_force1_gap(m, f)\n      when ''manual_ops'' then bi.api_manual_ops(m, f)   -- wave 110a\n      when ''ask_trends'' then bi.api_ask_trends(jsonb_build_object(''days'', coalesce((p_args->>''days'')::int, 14), ''section'', p_args->>''section'', ''admin'', false))'], array[1]);

alter table bi.agent_report drop constraint if exists agent_report_kind_check;
alter table bi.agent_report add constraint agent_report_kind_check check (kind = any (array['daily_brief', 'market_news', 'chat_review', 'weekly_review',
  'target_watch', 'zone_west', 'zone_north_east', 'zone_south', 'client_review', 'month_close', 'data_watch', 'branch_network', 'ops_watch', 'collections_watch', 'decision_audit', 'lesson_trial']));
update bi.ai_agent set job_kind = 'lesson_trial', role = 'Tests each lesson the quality review proposes (a second opinion, then a trial answer with the lesson) and switches on the ones that pass; also re-checks high-stakes reports.', updated_at = now()
 where agent_id = 'pd_7';
select cron.schedule('bi-agent-lesson-trial', '45 0 * * *', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"lesson_trial"}'::jsonb)$c$);
