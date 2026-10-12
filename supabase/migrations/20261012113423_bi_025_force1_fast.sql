-- Applied to Supabase project via MCP on 20261012113423

create or replace function bi.api_force1(p_month date, f jsonb) returns jsonb
language sql stable security definer set search_path = bi, public as $$
with g as (   -- one pass, grouped; filters applied to groups, not rows
  select created_month, recon_unit, location_id, client_code, verified_by, verifier_class, category, processing_route, count(*) n
  from bi.v_point group by 1,2,3,4,5,6,7,8),
gf as (select * from g where bi.loc_ok(location_id, recon_unit, f) and bi.fam_ok(client_code, f)),
m as (select * from gf where created_month = p_month),
tat as (select recon_unit, processing_route, field_tat_hours from bi.v_point
        where created_month = p_month and category = 'field' and field_tat_hours is not null
          and bi.loc_ok(location_id, recon_unit, f) and bi.fam_ok(client_code, f)),
tat_u as (select recon_unit as unit,
    percentile_cont(0.5) within group (order by field_tat_hours) filter (where processing_route='in_force_by_field_executive') f1_tat,
    percentile_cont(0.5) within group (order by field_tat_hours) filter (where processing_route='back_office_update_likely_outside_force') man_tat
  from tat group by recon_unit),
tat_t as (select
    percentile_cont(0.5) within group (order by field_tat_hours) filter (where processing_route='in_force_by_field_executive') f1_tat,
    percentile_cont(0.5) within group (order by field_tat_hours) filter (where processing_route='back_office_update_likely_outside_force') man_tat
  from tat),
unit_pts as (
  select recon_unit as unit,
    sum(n) filter (where category='field') field_points,
    sum(n) filter (where processing_route='in_force_by_field_executive') f1_field,
    sum(n) filter (where processing_route='back_office_update_likely_outside_force') manual_field,
    sum(n) filter (where category='field' and processing_route not in ('in_force_by_field_executive','back_office_update_likely_outside_force')) unverified_field,
    count(distinct verified_by) filter (where verifier_class='field_executive') field_execs,
    count(distinct verified_by) filter (where verifier_class='back_office') back_office_staff,
    sum(n) filter (where verifier_class='back_office') back_office_points
  from m group by recon_unit),
case_u as (
  select recon_unit as unit, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases
  from bi.v_force_usage
  where month = p_month and case_data_available and bi.loc_ok(null, recon_unit, f)
    and (f->>'client_family' is null or client_family = f->>'client_family')
  group by recon_unit),
u as (
  select coalesce(c.unit, p.unit) as unit, c.tracker_cases, c.force1_cases,
         p.field_points, p.f1_field, p.manual_field, p.unverified_field, p.field_execs, p.back_office_staff, p.back_office_points,
         t.f1_tat, t.man_tat
  from case_u c full join unit_pts p on p.unit = c.unit left join tat_u t on t.unit = coalesce(c.unit, p.unit)),
tot as (
  select (select sum(tracker_cases) from case_u) tracker_cases, (select sum(force1_cases) from case_u) force1_cases,
    sum(n) filter (where category='field') field_points,
    sum(n) filter (where processing_route='in_force_by_field_executive') f1_field,
    sum(n) filter (where processing_route='back_office_update_likely_outside_force') manual_field,
    sum(n) filter (where category='field' and processing_route not in ('in_force_by_field_executive','back_office_update_likely_outside_force')) unverified_field,
    count(distinct verified_by) filter (where verifier_class='field_executive') field_execs,
    count(distinct verified_by) filter (where verifier_class='back_office') back_office_staff,
    sum(n) filter (where verifier_class='back_office') back_office_points,
    sum(n) filter (where verifier_class='back_office' and category<>'field') back_office_desk_points,
    sum(n) total_points
  from m),
trend_p as (
  select created_month as mon,
    sum(n) filter (where processing_route='in_force_by_field_executive') f1_field,
    sum(n) filter (where processing_route='back_office_update_likely_outside_force') manual_field,
    count(distinct verified_by) filter (where verifier_class='field_executive') field_execs,
    count(distinct verified_by) filter (where verifier_class='back_office') back_office_staff
  from gf group by created_month),
trend_c as (
  select v.month as mon, sum(force_cases) force1_cases, sum(tracker_cases) tracker_cases from bi.v_force_usage v
  where case_data_available and bi.loc_ok(null, recon_unit, f) and (f->>'client_family' is null or client_family = f->>'client_family') group by v.month)
select jsonb_build_object(
  'month', p_month,
  'totals', (select jsonb_build_object(
      'tracker_cases', tracker_cases, 'force1_cases', force1_cases,
      'case_utilisation', round(force1_cases::numeric / nullif(tracker_cases,0), 4),
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
      'recon_unit', unit, 'tracker_cases', tracker_cases, 'force1_cases', force1_cases,
      'case_utilisation', round(force1_cases::numeric / nullif(tracker_cases,0), 4),
      'field_points', field_points, 'f1_field', f1_field, 'manual_field', manual_field, 'unverified_field', unverified_field,
      'field_utilisation', round(f1_field::numeric / nullif(f1_field + manual_field,0), 4),
      'field_execs', field_execs, 'back_office_staff', back_office_staff,
      'field_points_per_exec', round(f1_field::numeric / nullif(field_execs,0), 1),
      'back_office_points_per_person', round(back_office_points::numeric / nullif(back_office_staff,0), 1),
      'f1_field_tat_hours', round(f1_tat::numeric,1), 'manual_field_tat_hours', round(man_tat::numeric,1))
      order by tracker_cases desc nulls last) from u), '[]'::jsonb),
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

