-- Applied to Supabase project via MCP on 20261021065328
-- bi_088 (21-Oct-2026): one TAT standard everywhere (AUDIT_REGISTER A4)
create table if not exists bi.tat_rule (
  measure text primary key check (measure in ('case', 'field', 'document', 'tele')),
  start_field text not null, end_field text not null,
  back_entry_minutes numeric, min_sample int not null default 30,
  status text not null default 'provisional' check (status in ('provisional', 'confirmed')),
  note text, updated_by text not null default 'migration', updated_at timestamptz not null default now(),
  check (start_field in ('received_at', 'created_at', 'assigned_at', 'assigned_at_else_created_at')),
  check (end_field in ('completed_at', 'field_reviewed_at')));
alter table bi.tat_rule enable row level security;
comment on table bi.tat_rule is 'TAT measure definitions; document rule is configurable by an admin (bi_admin tat_rule); every change is audit-logged';
insert into bi.tat_rule(measure, start_field, end_field, back_entry_minutes, status, note) values
 ('case', 'received_at', 'completed_at', 15, 'confirmed', 'Overall case TAT = case completed - case received (Force1 Case Wise). Cases closed within 15 minutes of receipt are counted as back-entered and flagged.'),
 ('field', 'assigned_at', 'field_reviewed_at', null, 'confirmed', 'Field TAT = field review - assignment, field points only; negative or > 120 days excluded as invalid.'),
 ('document', 'created_at', 'completed_at', null, 'provisional', 'Provisional: document point created -> completed. Assignment time is recorded for only ~3 % of document points (Sep-26: 1,272 of 42,586) and field review equals completion for documents (median gap 0 h). Admin can switch the start to assigned_at_else_created_at or the end to field_reviewed_at.'),
 ('tele', 'assigned_at', 'completed_at', null, 'confirmed', 'Tele TAT = completed - assignment, tele points only.')
on conflict (measure) do nothing;

create or replace view bi.v_point as
 SELECT p.point_id, p.case_id, p.point_type, COALESCE(t.category, 'unknown'::text) AS category, t.review_status AS category_review,
    p.created_month, COALESCE(c.recon_unit, p.recon_unit) AS recon_unit, c.location_id, COALESCE(c.client_code, p.client_code_raw) AS client_code,
    p.branch, p.pincode, p.has_address, p.status, p.assign_to, p.verified_by, p.completed_by, p.created_at, p.assigned_at, p.field_reviewed_at, p.completed_at,
        CASE
            WHEN t.category = 'field'::text AND p.assigned_at IS NOT NULL AND p.field_reviewed_at IS NOT NULL AND p.field_reviewed_at >= p.assigned_at AND p.field_reviewed_at < (p.assigned_at + '120 days'::interval) THEN EXTRACT(epoch FROM p.field_reviewed_at - p.assigned_at) / 3600.0
            ELSE NULL::numeric
        END AS field_tat_hours,
    t.category = 'field'::text AND p.assigned_at IS NOT NULL AND p.field_reviewed_at IS NOT NULL AND (p.field_reviewed_at < p.assigned_at OR p.field_reviewed_at >= (p.assigned_at + '120 days'::interval)) AS field_tat_invalid,
        CASE
            WHEN t.category = 'document'::text AND dz.t_end IS NOT NULL AND dz.t_start IS NOT NULL AND dz.t_end >= dz.t_start THEN EXTRACT(epoch FROM dz.t_end - dz.t_start) / 3600.0
            ELSE NULL::numeric
        END AS doc_tat_hours,
        CASE
            WHEN t.category = 'tele'::text AND p.completed_at IS NOT NULL AND p.assigned_at IS NOT NULL AND p.completed_at >= p.assigned_at THEN EXTRACT(epoch FROM p.completed_at - p.assigned_at) / 3600.0
            ELSE NULL::numeric
        END AS tele_tat_hours,
        CASE
            WHEN t.category IS DISTINCT FROM 'field'::text THEN NULL::text
            WHEN p.verified_by IS NULL THEN 'unknown_not_verified'::text
            WHEN ev.classification = 'field_executive'::text THEN 'in_force_by_field_executive'::text
            WHEN ev.classification = ANY (ARRAY['back_office'::text, 'mixed'::text]) THEN 'back_office_update_likely_outside_force'::text
            ELSE 'unknown'::text
        END AS processing_route,
    ev.classification AS verifier_class,
    ea.classification AS assignee_class
   FROM bi.fact_point p
     LEFT JOIN bi.point_type t ON t.name = p.point_type
     LEFT JOIN bi.fact_case c ON c.case_id = p.case_id
     LEFT JOIN bi.employee ev ON ev.name_key = p.verified_by
     LEFT JOIN bi.employee ea ON ea.name_key = p.assign_to
     LEFT JOIN bi.tat_rule dr ON dr.measure = 'document'
     CROSS JOIN LATERAL (SELECT
        CASE coalesce(dr.start_field, 'created_at') WHEN 'assigned_at' THEN p.assigned_at WHEN 'assigned_at_else_created_at' THEN coalesce(p.assigned_at, p.created_at) ELSE p.created_at END AS t_start,
        CASE coalesce(dr.end_field, 'completed_at') WHEN 'field_reviewed_at' THEN p.field_reviewed_at ELSE p.completed_at END AS t_end) dz
  WHERE p.created_at >= '2024-03-31 18:30:00+00'::timestamp with time zone;

create or replace function bi.tat_summary(m date, f jsonb, grp text default 'total') returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with zm as materialized (select * from bi.zone_map(coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = m), (m + interval '1 month - 1 day')::date))),
uz as materialized (select recon_unit, min(zone) zone from zm group by 1),
rc as materialized (select coalesce((select back_entry_minutes from bi.tat_rule where measure = 'case'), 15) be_min,
              coalesce((select min_sample from bi.tat_rule where measure = 'case'), 30) ms,
              (select status || ': ' || start_field || ' -> ' || end_field from bi.tat_rule where measure = 'document') doc_rule,
              (select max(committed_at) from bi.import_batch where source_category = 'case' and status = 'committed') case_extract_at),
cs as (select case grp when 'zone' then coalesce((select zone from zm where zm.location_id = v.location_id), (select zone from uz where uz.recon_unit = v.recon_unit))
                       when 'location' then v.location_id::text when 'client' then v.client_family when 'unit' then v.recon_unit
                       when 'branch' then v.client_family || '|' || coalesce(bi.norm_code(v.branch_code), '') else 'total' end id,
              v.tat_flag, v.raw_tat_hours, v.sla_met, v.due_at
       from bi.v_case v
       where grp not in ('pin', 'employee') and v.received_month = m and bi.loc_ok(v.location_id, v.recon_unit, f)
         and (f->>'client_family' is null or v.client_family = f->>'client_family')),
ca as (select id, count(*) cases, count(*) filter (where tat_flag = 'valid') completed, count(*) filter (where tat_flag = 'open') open,
         count(*) filter (where tat_flag = 'open' and due_at < (select case_extract_at from rc)) open_past_due,
         count(*) filter (where tat_flag in ('negative_duration', 'completed_without_date')) invalid,
         count(*) filter (where tat_flag = 'valid' and raw_tat_hours * 60 < (select be_min from rc)) back_entered,
         round(avg(raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) avg,
         round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) median,
         round(percentile_cont(0.9) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) p90,
         round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag = 'valid' and raw_tat_hours * 60 >= (select be_min from rc))::numeric, 1) median_excl_back_entered,
         round(avg(case when sla_met then 1.0 when sla_met = false then 0 end), 4) sla_met_pct
       from cs group by id),
pv as (select v.*, c.family fam from bi.v_point v left join bi.client c on c.code = v.client_code
       where v.created_month = m and bi.loc_ok(v.location_id, v.recon_unit, f) and bi.fam_ok(v.client_code, f)),
ps as (select case grp when 'zone' then coalesce((select zone from zm where zm.location_id = v.location_id), (select zone from uz where uz.recon_unit = v.recon_unit))
                       when 'location' then v.location_id::text when 'client' then v.fam when 'unit' then v.recon_unit
                       when 'branch' then cf.family || '|' || coalesce(bi.norm_code(c2.branch_code), '')
                       when 'pin' then coalesce(nullif(v.pincode, ''), '(no PIN)')
                       when 'employee' then coalesce(v.verified_by, v.completed_by, '(not recorded)')
                       else 'total' end id,
              v.category, v.field_tat_hours, v.field_tat_invalid, v.doc_tat_hours, v.tele_tat_hours
       from pv v left join bi.case_store c2 on grp = 'branch' and c2.case_id = v.case_id left join bi.client cf on cf.code = c2.client_code),
pa as (select id, count(*) points,
         count(*) filter (where category = 'field') field_points, count(field_tat_hours) field_n, count(*) filter (where field_tat_invalid) field_invalid,
         round(avg(field_tat_hours)::numeric, 1) field_avg,
         round(percentile_cont(0.5) within group (order by field_tat_hours)::numeric, 1) field_median,
         round(percentile_cont(0.9) within group (order by field_tat_hours)::numeric, 1) field_p90,
         count(*) filter (where category = 'document') doc_points, count(doc_tat_hours) doc_n,
         round(avg(doc_tat_hours)::numeric, 1) doc_avg,
         round(percentile_cont(0.5) within group (order by doc_tat_hours)::numeric, 1) doc_median,
         round(percentile_cont(0.9) within group (order by doc_tat_hours)::numeric, 1) doc_p90,
         count(*) filter (where category = 'tele') tele_points, count(tele_tat_hours) tele_n,
         round(percentile_cont(0.5) within group (order by tele_tat_hours)::numeric, 1) tele_median
       from ps group by id),
j as (select coalesce(ca.id, pa.id) id, coalesce(ca.cases, 0) ncases, coalesce(pa.points, 0) npoints,
         ca.completed c_completed, ca.open c_open, ca.open_past_due c_open_past_due, ca.invalid c_invalid, ca.back_entered c_back_entered,
         ca.avg c_avg, ca.median c_median, ca.p90 c_p90, ca.median_excl_back_entered c_median_excl_back_entered, ca.sla_met_pct c_sla_met_pct,
         pa.field_points, pa.field_n, pa.field_invalid, pa.field_avg, pa.field_median, pa.field_p90,
         pa.doc_points, pa.doc_n, pa.doc_avg, pa.doc_median, pa.doc_p90, pa.tele_points, pa.tele_n, pa.tele_median
       from ca full join pa on coalesce(pa.id, '~none') = coalesce(ca.id, '~none')),
jl as (select * from j order by ncases desc, npoints desc limit case when grp in ('pin', 'employee') then 500 else 100000 end)
select coalesce(jsonb_agg(jsonb_build_object('id', id,
  'case', jsonb_build_object('cases', ncases, 'completed', coalesce(c_completed, 0), 'open', coalesce(c_open, 0),
       'open_past_due', coalesce(c_open_past_due, 0), 'invalid', coalesce(c_invalid, 0),
       'n', coalesce(c_completed, 0), 'avg', c_avg, 'median', c_median, 'p90', c_p90, 'sla_met_pct', c_sla_met_pct,
       'back_entered', coalesce(c_back_entered, 0),
       'back_entered_share', round(coalesce(c_back_entered, 0)::numeric / nullif(c_completed, 0), 4),
       'median_excl_back_entered', c_median_excl_back_entered,
       'low_sample', coalesce(c_completed, 0) < (select ms from rc),
       'reliability', case when coalesce(c_completed, 0) = 0 then 'unavailable'
                           when coalesce(c_back_entered, 0)::numeric / c_completed > 0.5 then 'unreliable'
                           when c_completed < (select ms from rc) or coalesce(c_back_entered, 0)::numeric / c_completed > 0.2 then 'indicative' else 'ok' end,
       'reason', case when grp = 'pin' then 'Case TAT is not split by PIN code: PIN codes are recorded on points, not on cases'
                      when grp = 'employee' then 'Case TAT is not split by employee: a case is not assigned to one person'
                      when ncases = 0 then 'No Force1 cases received for this selection in the month'
                      when coalesce(c_completed, 0) = 0 then 'No case completed yet'
                      when coalesce(c_back_entered, 0)::numeric / c_completed > 0.5 then
                        format('%s%% of completed cases were closed within %s minutes of receipt (entered in Force1 after the work), so this TAT does not show working time',
                               round(100.0 * c_back_entered / c_completed), (select be_min from rc))
                      when c_completed < (select ms from rc) then format('Only %s completed cases - indicative', c_completed) end),
  'field', jsonb_build_object('points', coalesce(field_points, 0), 'n', coalesce(field_n, 0), 'avg', field_avg, 'median', field_median,
       'p90', field_p90, 'invalid', coalesce(field_invalid, 0), 'low_sample', coalesce(field_n, 0) < (select ms from rc),
       'reason', case when coalesce(field_points, 0) = 0 then 'No field points for this selection in the month'
                      when coalesce(field_n, 0) = 0 then 'Field points exist but none has both an assignment time and a field-review time'
                      when field_n < (select ms from rc) then format('Only %s timed field points - indicative', field_n) end),
  'document', jsonb_build_object('points', coalesce(doc_points, 0), 'n', coalesce(doc_n, 0), 'avg', doc_avg, 'median', doc_median,
       'p90', doc_p90, 'low_sample', coalesce(doc_n, 0) < (select ms from rc), 'rule', (select doc_rule from rc),
       'reason', case when coalesce(doc_points, 0) = 0 then 'No document points for this selection in the month'
                      when coalesce(doc_n, 0) = 0 then 'No document point completed yet'
                      when doc_n < (select ms from rc) then format('Only %s completed document points - indicative', doc_n) end),
  'tele', jsonb_build_object('points', coalesce(tele_points, 0), 'n', coalesce(tele_n, 0), 'median', tele_median),
  'points', npoints) order by ncases desc, npoints desc), '[]'::jsonb)
from jl
$function$;

create or replace function bi.tat_trend(f jsonb, p_months int default 12) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with mm as (select generate_series(date_trunc('month', (select max(received_month) from bi.case_store)) - make_interval(months => greatest(least(p_months, 24), 2) - 1),
                                   (select max(received_month) from bi.case_store), interval '1 month')::date m),
c as (select v.received_month m, count(*) filter (where tat_flag = 'valid') n,
             round(avg(raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) avg,
             round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) median,
             round(percentile_cont(0.9) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) p90
      from bi.v_case v where v.received_month in (select m from mm) and bi.loc_ok(v.location_id, v.recon_unit, f)
        and (f->>'client_family' is null or v.client_family = f->>'client_family') group by 1),
p as (select v.created_month m,
             count(field_tat_hours) field_n, round(avg(field_tat_hours)::numeric, 1) field_avg,
             round(percentile_cont(0.5) within group (order by field_tat_hours)::numeric, 1) field_median,
             round(percentile_cont(0.9) within group (order by field_tat_hours)::numeric, 1) field_p90,
             count(doc_tat_hours) doc_n, round(avg(doc_tat_hours)::numeric, 1) doc_avg,
             round(percentile_cont(0.5) within group (order by doc_tat_hours)::numeric, 1) doc_median,
             round(percentile_cont(0.9) within group (order by doc_tat_hours)::numeric, 1) doc_p90
      from bi.v_point v where v.created_month in (select m from mm) and v.category in ('field', 'document')
        and bi.loc_ok(v.location_id, v.recon_unit, f) and bi.fam_ok(v.client_code, f) group by 1)
select coalesce(jsonb_agg(jsonb_build_object('month', mm.m,
   'case', jsonb_build_object('n', coalesce(c.n, 0), 'avg', c.avg, 'median', c.median, 'p90', c.p90),
   'field', jsonb_build_object('n', coalesce(p.field_n, 0), 'avg', p.field_avg, 'median', p.field_median, 'p90', p.field_p90),
   'document', jsonb_build_object('n', coalesce(p.doc_n, 0), 'avg', p.doc_avg, 'median', p.doc_median, 'p90', p.doc_p90)) order by mm.m), '[]'::jsonb)
from mm left join c on c.m = mm.m left join p on p.m = mm.m
$function$;

create or replace function bi.tat_records(m date, f jsonb, lvl text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare lim int := least(greatest(coalesce((p->>'limit')::int, 200), 1), 1000); be numeric := coalesce((select back_entry_minutes from bi.tat_rule where measure = 'case'), 15);
begin
  if lvl = 'case' then
    return (select jsonb_build_object('level', 'case', 'month', m, 'limit', lim, 'rows', coalesce(jsonb_agg(x order by o), '[]'::jsonb)) from (
      select jsonb_build_object('case_id', v.case_id, 'client_family', v.client_family, 'branch_code', v.branch_code, 'branch', v.branch, 'recon_unit', v.recon_unit,
               'location_id', v.location_id, 'status', v.status, 'received_at', v.received_at, 'completed_at', v.completed_at, 'due_at', v.due_at,
               'tat_hours', round(v.raw_tat_hours::numeric, 1), 'flag', case when v.tat_flag = 'valid' and v.raw_tat_hours * 60 < be then 'back_entered' else v.tat_flag end,
               'sla_met', v.sla_met) x,
             row_number() over (order by v.raw_tat_hours desc nulls last) o
      from bi.v_case v
      where v.received_month = m and bi.loc_ok(v.location_id, v.recon_unit, f) and (f->>'client_family' is null or v.client_family = f->>'client_family')
        and (p->>'branch' is null or v.client_family || '|' || coalesce(bi.norm_code(v.branch_code), '') = p->>'branch')
        and (p->>'case_id' is null or v.case_id = (p->>'case_id')::bigint)
        and (p->>'flag' is null or (case when v.tat_flag = 'valid' and v.raw_tat_hours * 60 < be then 'back_entered' else v.tat_flag end) = p->>'flag')
      order by v.raw_tat_hours desc nulls last limit lim) q);
  elsif lvl = 'point' then
    return (select jsonb_build_object('level', 'point', 'month', m, 'limit', lim, 'rows', coalesce(jsonb_agg(x order by o), '[]'::jsonb)) from (
      select jsonb_build_object('point_id', v.point_id, 'case_id', v.case_id, 'category', v.category, 'point_type', v.point_type, 'pincode', v.pincode,
               'employee', coalesce(v.verified_by, v.completed_by), 'assigned_to', v.assign_to, 'status', v.status,
               'created_at', v.created_at, 'assigned_at', v.assigned_at, 'field_reviewed_at', v.field_reviewed_at, 'completed_at', v.completed_at,
               'field_tat_hours', round(v.field_tat_hours::numeric, 1), 'document_tat_hours', round(v.doc_tat_hours::numeric, 1),
               'tele_tat_hours', round(v.tele_tat_hours::numeric, 1), 'field_tat_invalid', v.field_tat_invalid) x,
             row_number() over (order by coalesce(v.field_tat_hours, v.doc_tat_hours, v.tele_tat_hours) desc nulls last) o
      from bi.v_point v
      where v.created_month = m and bi.loc_ok(v.location_id, v.recon_unit, f) and bi.fam_ok(v.client_code, f)
        and (p->>'category' is null or v.category = p->>'category')
        and (p->>'pin' is null or v.pincode = p->>'pin')
        and (p->>'employee' is null or coalesce(v.verified_by, v.completed_by) = p->>'employee')
        and (p->>'case_id' is null or v.case_id = (p->>'case_id')::bigint)
      order by coalesce(v.field_tat_hours, v.doc_tat_hours, v.tele_tat_hours) desc nulls last limit lim) q);
  end if;
  raise exception 'level must be case or point';
end $function$;

create or replace function bi.tat_rule_admin(p_actor text, p jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare r bi.tat_rule;
begin
  if coalesce(p->>'op', 'list') = 'list' then
    return (select jsonb_agg(to_jsonb(t) order by measure) from bi.tat_rule t);
  end if;
  if p->>'op' <> 'set' then raise exception 'op must be list or set'; end if;
  if p->>'measure' <> 'document' then raise exception 'only the document rule is configurable; case and field TAT are fixed definitions'; end if;
  if length(coalesce(p->>'note', '')) < 5 then raise exception 'a note explaining the change is required'; end if;
  update bi.tat_rule set start_field = coalesce(p->>'start_field', start_field), end_field = coalesce(p->>'end_field', end_field),
         status = coalesce(p->>'status', status), note = p->>'note', updated_by = p_actor, updated_at = now()
   where measure = 'document' returning * into r;
  insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'definition_change', 'tat_rule', 'document', to_jsonb(r));
  return to_jsonb(r);
end $function$;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if position('tat_trend' in d) = 0 then
    if (length(d) - length(replace(d, $a$when 'force1' then bi.api_force1(m,f)$a$, ''))) / length($a$when 'force1' then bi.api_force1(m,f)$a$) <> 1 then raise exception 'bi_call anchor'; end if;
    execute replace(d, $a$when 'force1' then bi.api_force1(m,f)$a$,
      $b$when 'force1' then bi.api_force1(m,f)
      when 'tat_trend' then bi.tat_trend(f, coalesce((p_args->>'months')::int, 12))$b$);
  end if;
  d := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
  if position('tat_rule' in d) = 0 then
    if (length(d) - length(replace(d, $a$when 'verify' then return jsonb_build_object('ok', true);$a$, ''))) / length($a$when 'verify' then return jsonb_build_object('ok', true);$a$) <> 1 then raise exception 'bi_admin anchor'; end if;
    execute replace(d, $a$when 'verify' then return jsonb_build_object('ok', true);$a$,
      $b$when 'verify' then return jsonb_build_object('ok', true);
    when 'tat_rule' then return bi.tat_rule_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'tat_records' then return bi.tat_records((p->>'month')::date, coalesce(p->'filters', '{}'::jsonb), coalesce(p->>'level', 'case'), coalesce(p->'p', '{}'::jsonb));$b$);
  end if;
end $do$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'tat_standard', 'bi_088', jsonb_build_object('register', 'A4', 'document_rule', 'provisional created -> completed'));
