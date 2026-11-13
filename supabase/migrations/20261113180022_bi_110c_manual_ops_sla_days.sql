-- Applied to Supabase project via MCP on 20261113180022
-- wave 110c (13-Nov-2026): manual daily numbers — SLA and staff per day use only the days that report them
-- (a day sent without "completed within TAT" no longer pulls SLA down; a day without staff no longer halves staff per day).
create or replace function bi.api_manual_ops(p_month date, f jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
  with mm as (select coalesce(p_month, date_trunc('month', current_date)::date) m),
  d as (select w.*, l.label loc, l.zone_group, coalesce(l.recon_unit, l.label) unit from bi.manual_ops_daily w join bi.location l on l.id = w.location_id
         where w.day >= (select m from mm) and w.day < (select m from mm) + interval '1 month' and bi.loc_ok(w.location_id, l.recon_unit, f, (select m from mm))
           and (f->>'client_family' is null or w.client_family = f->>'client_family' or w.client_family is null)),
  lastday as (select location_id, max(day) dmax from d group by 1),
  pend as (select d.location_id, sum(d.cases_pending_eod) pending, sum(d.pending_past_due) past_due from d join lastday x on x.location_id = d.location_id and x.dmax = d.day group by 1),
  agg as (select location_id, loc, zone_group, unit, count(distinct day) days, max(day) last_day, sum(cases_received) received, sum(cases_completed) completed, sum(completed_within_tat) within_tat,
                 sum(cases_completed) filter (where completed_within_tat is not null) completed_sla,
                 round(sum(avg_case_tat_hours * cases_completed) / nullif(sum(cases_completed) filter (where avg_case_tat_hours is not null), 0), 1) case_tat_h,
                 sum(cases_completed) filter (where avg_case_tat_hours is not null) completed_tat,
                 sum(field_visits_done) visits, round(sum(avg_field_tat_hours * field_visits_done) / nullif(sum(field_visits_done) filter (where avg_field_tat_hours is not null), 0), 1) field_tat_h,
                 sum(field_visits_done) filter (where avg_field_tat_hours is not null) visits_tat,
                 sum(document_checks_done) docs, sum(field_staff_working) field_staff_days, sum(office_staff_working) office_staff_days,
                 count(distinct day) filter (where field_staff_working is not null) staff_days
            from d group by 1, 2, 3, 4)
  select jsonb_build_object('month', (select m from mm),
    'method', 'Numbers sent daily by locations not on Force1. TAT is the average reported for the day, weighted by cases completed (case TAT) or visits (field TAT); SLA = completed within TAT ÷ completed, counting only the days that report "completed within TAT"; pending = the last reported day; staff per day = over the days that report staff.',
    'totals', (select jsonb_build_object('locations', count(*), 'days', sum(days), 'received', sum(received), 'completed', sum(completed), 'within_tat', sum(within_tat),
                 'sla_pct', round(100.0 * sum(within_tat) / nullif(sum(completed_sla), 0), 1),
                 'case_tat_h', round(sum(case_tat_h * completed_tat) / nullif(sum(completed_tat) filter (where case_tat_h is not null), 0), 1),
                 'visits', sum(visits), 'field_tat_h', round(sum(field_tat_h * visits_tat) / nullif(sum(visits_tat) filter (where field_tat_h is not null), 0), 1),
                 'pending', (select sum(pending) from pend), 'past_due', (select sum(past_due) from pend), 'field_staff_days', sum(field_staff_days)) from agg),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('location_id', a.location_id, 'location', a.loc, 'zone_group', a.zone_group, 'unit', a.unit, 'days', a.days, 'last_day', a.last_day,
                 'stale_days', current_date - a.last_day, 'received', a.received, 'completed', a.completed, 'within_tat', a.within_tat,
                 'sla_pct', round(100.0 * a.within_tat / nullif(a.completed_sla, 0), 1), 'case_tat_h', a.case_tat_h, 'visits', a.visits, 'field_tat_h', a.field_tat_h, 'documents', a.docs,
                 'pending', p.pending, 'past_due', p.past_due, 'field_staff_per_day', round(a.field_staff_days::numeric / nullif(a.staff_days, 0), 1)) order by a.zone_group, a.loc), '[]')
                 from agg a left join pend p on p.location_id = a.location_id),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'received', r, 'completed', c, 'visits', v) order by day), '[]')
                from (select day, sum(cases_received) r, sum(cases_completed) c, sum(field_visits_done) v from d group by day) q))
$function$;
delete from bi.api_cache where fn = 'manual_ops';
