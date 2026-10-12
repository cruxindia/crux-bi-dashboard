-- Applied to Supabase project via MCP on 20261012113716

drop table if exists bi.point_derived;
create table bi.point_derived (
  point_id bigint primary key, created_month date not null, recon_unit text, location_id int, client_code text,
  category text, route smallint,         -- 1 field executive (Force1), 2 manual by back office, 3 not verified, 4 unknown; null = non-field
  verifier_id int, verifier_class smallint, -- 1 field executive, 2 back office, 0 other/unclassified
  field_tat_hours real);
alter table bi.point_derived enable row level security;
create index point_derived_month on bi.point_derived(created_month, recon_unit);

create or replace function bi.refresh_point_derived() returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare t0 timestamptz := clock_timestamp(); n int; v bigint := (select coalesce(max(id),0) from bi.audit_log); e int;
begin
  e := bi.refresh_employee_classification();
  truncate bi.point_derived;
  insert into bi.point_derived
  select p.point_id, p.created_month, p.recon_unit, p.location_id, p.client_code, p.category,
         case p.processing_route when 'in_force_by_field_executive' then 1 when 'back_office_update_likely_outside_force' then 2
              when 'unknown_not_verified' then 3 else case when p.category='field' then 4 end end,
         d.id, case p.verifier_class when 'field_executive' then 1 when 'back_office' then 2 else 0 end, p.field_tat_hours
  from bi.v_point p left join bi.dim d on d.kind='emp' and d.val=p.verified_by;
  get diagnostics n = row_count;
  insert into bi.refresh_state values ('point_derived', now(), v, n, round(extract(epoch from clock_timestamp()-t0)*1000))
  on conflict (name) do update set refreshed_at=excluded.refreshed_at, source_version=excluded.source_version, rows=excluded.rows, ms=excluded.ms;
  return jsonb_build_object('rows', n, 'employees', e, 'ms', round(extract(epoch from clock_timestamp()-t0)*1000));
end $$;

create or replace function bi.refresh_if_stale() returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare v bigint := (select coalesce(max(id),0) from bi.audit_log);
begin
  if exists (select 1 from bi.refresh_state where name='point_derived' and source_version >= v) then return jsonb_build_object('stale', false); end if;
  return bi.refresh_point_derived();
end $$;
revoke all on function bi.refresh_point_derived() from public, anon, authenticated;
revoke all on function bi.refresh_if_stale() from public, anon, authenticated;

create or replace function bi.api_force1(p_month date, f jsonb) returns jsonb
language sql stable security definer set search_path = bi, public as $$
with g as (select created_month, recon_unit, location_id, client_code, verifier_id, verifier_class, category, route, count(*) n
           from bi.point_derived group by 1,2,3,4,5,6,7,8),
gf as (select * from g where bi.loc_ok(location_id, recon_unit, f) and bi.fam_ok(client_code, f)),
m as (select * from gf where created_month = p_month),
tat as (select recon_unit, route, field_tat_hours from bi.point_derived
        where created_month = p_month and route in (1,2) and field_tat_hours is not null
          and bi.loc_ok(location_id, recon_unit, f) and bi.fam_ok(client_code, f)),
tat_u as (select recon_unit as unit,
    percentile_cont(0.5) within group (order by field_tat_hours) filter (where route=1) f1_tat,
    percentile_cont(0.5) within group (order by field_tat_hours) filter (where route=2) man_tat from tat group by recon_unit),
tat_t as (select percentile_cont(0.5) within group (order by field_tat_hours) filter (where route=1) f1_tat,
                 percentile_cont(0.5) within group (order by field_tat_hours) filter (where route=2) man_tat from tat),
unit_pts as (select recon_unit as unit, sum(n) filter (where category='field') field_points,
    sum(n) filter (where route=1) f1_field, sum(n) filter (where route=2) manual_field, sum(n) filter (where route in (3,4)) unverified_field,
    count(distinct verifier_id) filter (where verifier_class=1) field_execs, count(distinct verifier_id) filter (where verifier_class=2) back_office_staff,
    sum(n) filter (where verifier_class=2) back_office_points from m group by recon_unit),
case_u as (select recon_unit as unit, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases from bi.v_force_usage
  where month = p_month and case_data_available and bi.loc_ok(null, recon_unit, f) and (f->>'client_family' is null or client_family = f->>'client_family')
  group by recon_unit),
u as (select coalesce(c.unit, p.unit) as unit, c.tracker_cases, c.force1_cases, p.field_points, p.f1_field, p.manual_field, p.unverified_field,
         p.field_execs, p.back_office_staff, p.back_office_points, t.f1_tat, t.man_tat
  from case_u c full join unit_pts p on p.unit = c.unit left join tat_u t on t.unit = coalesce(c.unit, p.unit)),
tot as (select (select sum(tracker_cases) from case_u) tracker_cases, (select sum(force1_cases) from case_u) force1_cases,
    sum(n) filter (where category='field') field_points, sum(n) filter (where route=1) f1_field, sum(n) filter (where route=2) manual_field,
    sum(n) filter (where route in (3,4)) unverified_field,
    count(distinct verifier_id) filter (where verifier_class=1) field_execs, count(distinct verifier_id) filter (where verifier_class=2) back_office_staff,
    sum(n) filter (where verifier_class=2) back_office_points, sum(n) filter (where verifier_class=2 and category<>'field') back_office_desk_points,
    sum(n) total_points from m),
trend_p as (select created_month as mon, sum(n) filter (where route=1) f1_field, sum(n) filter (where route=2) manual_field,
    count(distinct verifier_id) filter (where verifier_class=1) field_execs, count(distinct verifier_id) filter (where verifier_class=2) back_office_staff
  from gf group by created_month),
trend_c as (select v.month as mon, sum(force_cases) force1_cases, sum(tracker_cases) tracker_cases from bi.v_force_usage v
  where case_data_available and bi.loc_ok(null, recon_unit, f) and (f->>'client_family' is null or client_family = f->>'client_family') group by v.month)
select jsonb_build_object(
  'month', p_month,
  'points_as_of', (select refreshed_at from bi.refresh_state where name='point_derived'),
  'totals', (select jsonb_build_object(
      'tracker_cases', tracker_cases, 'force1_cases', force1_cases, 'case_utilisation', round(force1_cases::numeric / nullif(tracker_cases,0), 4),
      'field_points', field_points, 'f1_field', f1_field, 'manual_field', manual_field, 'unverified_field', unverified_field,
      'field_utilisation', round(f1_field::numeric / nullif(f1_field + manual_field,0), 4),
      'field_execs', field_execs, 'back_office_staff', back_office_staff,
      'field_points_per_exec', round(f1_field::numeric / nullif(field_execs,0), 1),
      'back_office_points', back_office_points, 'back_office_desk_points', back_office_desk_points,
      'back_office_points_per_person', round(back_office_points::numeric / nullif(back_office_staff,0), 1),
      'manual_field_per_back_office_person', round(manual_field::numeric / nullif(back_office_staff,0), 1),
      'total_points', total_points,
      'f1_field_tat_hours', (select round(f1_tat::numeric,1) from tat_t), 'manual_field_tat_hours', (select round(man_tat::numeric,1) from tat_t)) from tot),
  'by_unit', coalesce((select jsonb_agg(jsonb_build_object(
      'recon_unit', unit, 'tracker_cases', tracker_cases, 'force1_cases', force1_cases, 'case_utilisation', round(force1_cases::numeric / nullif(tracker_cases,0), 4),
      'field_points', field_points, 'f1_field', f1_field, 'manual_field', manual_field, 'unverified_field', unverified_field,
      'field_utilisation', round(f1_field::numeric / nullif(f1_field + manual_field,0), 4),
      'field_execs', field_execs, 'back_office_staff', back_office_staff,
      'field_points_per_exec', round(f1_field::numeric / nullif(field_execs,0), 1),
      'back_office_points_per_person', round(back_office_points::numeric / nullif(back_office_staff,0), 1),
      'f1_field_tat_hours', round(f1_tat::numeric,1), 'manual_field_tat_hours', round(man_tat::numeric,1)) order by tracker_cases desc nulls last) from u), '[]'::jsonb),
  'trend', coalesce((select jsonb_agg(jsonb_build_object('month', coalesce(c.mon,p.mon),
      'case_utilisation', round(c.force1_cases::numeric / nullif(c.tracker_cases,0),4),
      'field_utilisation', round(p.f1_field::numeric / nullif(p.f1_field + p.manual_field,0),4),
      'field_execs', p.field_execs, 'back_office_staff', p.back_office_staff) order by coalesce(c.mon,p.mon))
     from trend_c c full join trend_p p on p.mon = c.mon), '[]'::jsonb),
  'definitions', jsonb_build_object(
      'case_utilisation', 'Force1 cases received in the month / Zonal Tracker cases, same location group, client family and month; only where Case Wise data exists',
      'field_utilisation', 'Field points submitted by field executives (Force1) / (field-executive + back-office submissions); unverified points excluded',
      'field_executive', 'Submits only field points; never creates cases/points; never handles document or tele points',
      'back_office', 'Creates cases/points or handles any document/tele point; their field submissions are manual'));
$$;

-- cache version also follows the derived-table refresh
do $$ declare d text; begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if position($a$v_ver bigint := (select coalesce(max(id),0) from bi.audit_log);$a$ in d) = 0 then raise exception 'version line not found'; end if;
  d := replace(d, $a$v_ver bigint := (select coalesce(max(id),0) from bi.audit_log);$a$,
    $a$v_ver bigint := (select coalesce(max(id),0) from bi.audit_log) * 100000 + coalesce((select (extract(epoch from max(refreshed_at))::bigint % 100000) from bi.refresh_state), 0);$a$);
  execute d;
end $$;
grant execute on function public.bi_call(text, jsonb) to anon, authenticated;

-- admin "Re-run classification" now just marks data stale; the background job rebuilds (no 20 s request limit)
create or replace function public.bi_admin(p_action text, p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if not bi.admin_ok(p->>'admin_key') then raise exception 'admin key required' using errcode='42501'; end if;
  if p_action = 'verify' then return jsonb_build_object('ok', true); end if;
  if p_action = 'mapping_update' then return bi.api_mapping_update('admin-key', p - 'admin_key'); end if;
  if p_action = 'refresh_employees' then
    insert into bi.audit_log(actor,action,entity) values ('admin-key','request_refresh','point_derived');
    return jsonb_build_object('queued', true, 'note', 'Classification and Force1 figures refresh within 10 minutes');
  end if;
  raise exception 'unknown action';
end $$;
grant execute on function public.bi_admin(text, jsonb) to anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('bi-refresh-point-derived', '*/10 * * * *', $c$set statement_timeout = '300s'; select bi.refresh_if_stale();$c$);

