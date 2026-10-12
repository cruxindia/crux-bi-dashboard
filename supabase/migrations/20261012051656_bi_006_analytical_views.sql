-- Applied to Supabase project via MCP on 20261012051656

create or replace function bi.workdays(d1 date, d2 date) returns int language sql immutable as
$$ select count(*)::int from generate_series(d1, d2, interval '1 day') g where extract(isodow from g) <> 7 $$;

create or replace view bi.v_zt_leaf as
select r.snapshot_date, s.report_month, r.location_id, r.client_code,
       sum(r.target_cases) target_cases, sum(r.mtd_cases) mtd_cases, sum(r.revenue_target) revenue_target,
       sum(r.revenue_actual) revenue_actual, max(r.rate) rate, sum(r.bd_revenue) bd_revenue, sum(r.src_daily_value) src_daily_cases,
       count(*) source_rows
from bi.zt_row r join bi.zt_snapshot s using (snapshot_date)
where r.row_type='leaf' and r.location_id is not null
group by 1,2,3,4;

create or replace view bi.v_zt_daily as
select l.*, p.prev_snapshot, p.prev_mtd,
  case when p.prev_snapshot is null and extract(day from l.snapshot_date)=1 then l.mtd_cases
       when p.prev_snapshot is null then null else l.mtd_cases - p.prev_mtd end as change_cases,
  case when p.prev_snapshot is null and extract(day from l.snapshot_date)=1 then 'from_month_start'
       when p.prev_snapshot is null then 'no_prior_snapshot'
       when bi.workdays(p.prev_snapshot + 1, l.snapshot_date) <= 1 then 'one_working_day'
       else 'multi_day_gap' end as change_basis,
  (l.snapshot_date - p.prev_snapshot) as gap_days
from bi.v_zt_leaf l
left join lateral (
  select x.snapshot_date prev_snapshot, x.mtd_cases prev_mtd from bi.v_zt_leaf x
  where x.report_month=l.report_month and x.location_id=l.location_id and x.client_code=l.client_code and x.snapshot_date<l.snapshot_date
  order by x.snapshot_date desc limit 1) p on true;

create or replace view bi.v_latest_snapshot as
select report_month, max(snapshot_date) snapshot_date from bi.zt_snapshot group by 1;

create or replace view bi.v_month_business as
with snap as (
  select l.report_month as month, l.location_id, l.client_code, l.target_cases, l.mtd_cases, l.revenue_target, l.revenue_actual, l.snapshot_date
  from bi.v_zt_leaf l join bi.v_latest_snapshot ls on ls.report_month=l.report_month and ls.snapshot_date=l.snapshot_date)
select coalesce(h.month,s.month) as month, coalesce(h.location_id,s.location_id) location_id, coalesce(h.client_code,s.client_code) client_code,
       coalesce(h.cases, s.mtd_cases) cases, coalesce(h.revenue, s.revenue_actual) revenue, h.billing,
       s.target_cases, s.revenue_target,
       case when h.month is not null then 'tracker_history' else 'tracker_snapshot' end as cases_source,
       coalesce(s.snapshot_date, h.source_snapshot) as as_of,
       s.mtd_cases as month_end_snapshot_mtd
from bi.zt_month_history h full join snap s on s.month=h.month and s.location_id=h.location_id and s.client_code=h.client_code;

create or replace view bi.v_case as
select c.case_id, c.received_month, c.recon_unit, c.location_id, c.client_code, cl.family client_family, c.branch, c.branch_code, c.product, c.status,
       c.received_at, c.completed_at, c.due_at, c.points_declared,
       (c.received_at at time zone 'Asia/Kolkata')::date received_date_ist,
       case when c.completed_at is not null and c.received_at is not null then extract(epoch from c.completed_at - c.received_at)/3600.0 end raw_tat_hours,
       case when upper(c.status)<>'COMPLETED' then 'open'
            when c.completed_at is null then 'completed_without_date'
            when c.completed_at < c.received_at then 'negative_duration'
            else 'valid' end tat_flag,
       case when upper(c.status)='COMPLETED' and c.completed_at>=c.received_at and c.due_at is not null then c.completed_at <= c.due_at end sla_met
from bi.fact_case c left join bi.client cl on cl.code=c.client_code
where c.received_at >= timestamptz '2024-04-01 00:00+05:30';

create or replace function bi.refresh_employee_classification(p_min_points int default 20) returns int
language plpgsql security definer set search_path = bi, public as $$
declare n int;
begin
  insert into bi.employee(name_key, display_name, classification, rule, evidence)
  select v.verified_by, initcap(v.verified_by),
    case when v.total < p_min_points then 'unclassified'
         when v.field = v.total then 'field_executive'
         when v.field = 0 then 'back_office' else 'mixed' end,
    'verified_by point mix; field_executive = exclusively field point types (min '||p_min_points||' points)',
    jsonb_build_object('field',v.field,'document',v.doc,'tele',v.tele,'other',v.total-v.field-v.doc-v.tele,'total',v.total,
                       'assigned_field_points',v.assigned_field, 'as_of', now())
  from (select p.verified_by, count(*) total, count(*) filter (where t.category='field') field, count(*) filter (where t.category='document') doc,
               count(*) filter (where t.category='tele') tele, count(*) filter (where t.category='field' and p.assign_to=p.verified_by) assigned_field
        from bi.fact_point p left join bi.point_type t on t.name=p.point_type
        where p.verified_by is not null group by 1) v
  on conflict (name_key) do update set classification = case when bi.employee.override then bi.employee.classification else excluded.classification end,
     rule=excluded.rule, evidence=excluded.evidence;
  get diagnostics n = row_count; return n;
end $$;

create or replace view bi.v_point as
select p.point_id, p.case_id, p.point_type, coalesce(t.category,'unknown') category, t.review_status category_review,
       p.created_month, coalesce(c.recon_unit, p.recon_unit) recon_unit, c.location_id, coalesce(c.client_code, p.client_code_raw) client_code,
       p.branch, p.pincode, p.has_address, p.status, p.assign_to, p.verified_by, p.completed_by,
       p.created_at, p.assigned_at, p.field_reviewed_at, p.completed_at,
       case when t.category='field' and p.assigned_at is not null and p.field_reviewed_at is not null
                 and p.field_reviewed_at >= p.assigned_at and p.field_reviewed_at < p.assigned_at + interval '120 days'
            then extract(epoch from p.field_reviewed_at - p.assigned_at)/3600.0 end field_tat_hours,
       (t.category='field' and p.assigned_at is not null and p.field_reviewed_at is not null
                 and (p.field_reviewed_at < p.assigned_at or p.field_reviewed_at >= p.assigned_at + interval '120 days')) field_tat_invalid,
       case when t.category='document' and p.completed_at is not null and p.completed_at >= p.created_at
            then extract(epoch from p.completed_at - p.created_at)/3600.0 end doc_tat_hours,
       case when t.category='tele' and p.completed_at is not null and p.assigned_at is not null and p.completed_at >= p.assigned_at
            then extract(epoch from p.completed_at - p.assigned_at)/3600.0 end tele_tat_hours,
       case when t.category is distinct from 'field' then null
            when p.assign_to is null then 'unknown_no_assignee'
            when p.verified_by = p.assign_to and ev.classification='field_executive' then 'in_force_by_field_executive'
            when p.verified_by = p.assign_to then 'in_force_by_assignee_inferred'
            when ev.classification in ('back_office','mixed') then 'back_office_update_likely_outside_force'
            else 'unknown' end processing_route,
       ev.classification verifier_class, ea.classification assignee_class
from bi.fact_point p
left join bi.point_type t on t.name=p.point_type
left join bi.fact_case c on c.case_id=p.case_id
left join bi.employee ev on ev.name_key=p.verified_by
left join bi.employee ea on ea.name_key=p.assign_to
where p.created_at >= timestamptz '2024-04-01 00:00+05:30';

create or replace view bi.v_case_coverage as
select la.recon_unit, b.period_month as month, max(b.committed_at) loaded_at, string_agg(distinct b.file_name, ', ') files
from bi.import_batch b join bi.location_alias la on la.source='case_file' and la.alias=bi.norm(b.location_group)
where b.source_category='case' and b.status='committed' group by 1,2;

create or replace view bi.v_force_usage as
with tr as (
  select mb.month, l.recon_unit, c.family client_family, sum(mb.cases) tracker_cases, max(mb.as_of) tracker_as_of, bool_or(mb.cases_source='tracker_snapshot') open_month
  from bi.v_month_business mb join bi.location l on l.id=mb.location_id join bi.client c on c.code=mb.client_code
  where l.recon_unit is not null group by 1,2,3),
fc as (
  select v.received_month as month, v.recon_unit, v.client_family, v.received_date_ist, count(*) n
  from bi.v_case v where v.recon_unit is not null group by 1,2,3,4)
select tr.month, tr.recon_unit, tr.client_family, tr.tracker_cases, tr.tracker_as_of, tr.open_month,
       cov.month is not null as case_data_available,
       case when cov.month is null then null
            else coalesce((select sum(n) from fc where fc.month=tr.month and fc.recon_unit=tr.recon_unit and fc.client_family=tr.client_family
                             and (not tr.open_month or fc.received_date_ist <= tr.tracker_as_of)),0) end force_cases
from tr left join bi.v_case_coverage cov on cov.recon_unit=tr.recon_unit and cov.month=tr.month;

