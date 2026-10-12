-- Applied to Supabase project via MCP on 20261012052048

create or replace function bi.loc_ok(p_loc int, p_unit text, f jsonb) returns boolean language sql stable as $$
  select case when coalesce(f,'{}'::jsonb) - 'client_family' = '{}'::jsonb then true
    when p_loc is not null then exists(select 1 from bi.location l where l.id=p_loc
          and (f->>'region' is null or l.region=f->>'region') and (f->>'zone_group' is null or l.zone_group=f->>'zone_group')
          and (f->>'stakeholder' is null or l.stakeholder=f->>'stakeholder') and (f->>'location_id' is null or l.id=(f->>'location_id')::int))
    else f->>'location_id' is null and exists(select 1 from bi.location l where l.recon_unit=p_unit
          and (f->>'region' is null or l.region=f->>'region') and (f->>'zone_group' is null or l.zone_group=f->>'zone_group')
          and (f->>'stakeholder' is null or l.stakeholder=f->>'stakeholder')) end $$;
create or replace function bi.fam_ok(p_client text, f jsonb) returns boolean language sql stable as $$
  select f->>'client_family' is null or exists(select 1 from bi.client c where c.code=p_client and c.family=f->>'client_family') $$;

create or replace function bi.api_meta() returns jsonb language sql stable as $$
select jsonb_build_object(
 'locations',(select jsonb_agg(jsonb_build_object('id',id,'label',label,'zone_group',zone_group,'zone_label',(select label from bi.zone_group z where z.code=l.zone_group),
       'region',region,'tier',tier,'stakeholder',stakeholder,'recon_unit',recon_unit) order by region,zone_group,label) from bi.location l),
 'client_families',(select jsonb_agg(distinct family) from bi.client),
 'months',(select jsonb_agg(m order by m desc) from (select distinct month m from bi.v_month_business where month>=date '2024-04-01') x),
 'freshness',jsonb_build_object(
    'zonal_latest_snapshot',(select max(snapshot_date) from bi.zt_snapshot),
    'zonal_snapshots',(select count(*) from bi.zt_snapshot),
    'case_latest_received_ist',(select max(received_at at time zone 'Asia/Kolkata') from bi.fact_case),
    'case_rows',(select count(*) from bi.fact_case),
    'point_latest_created_ist',(select max(created_at at time zone 'Asia/Kolkata') from bi.fact_point),
    'point_rows',(select count(*) from bi.fact_point),
    'case_coverage',(select jsonb_object_agg(recon_unit, mx) from (select recon_unit, max(month) mx from bi.v_case_coverage group by 1) x),
    'point_coverage',(select jsonb_object_agg(recon_unit, mx) from (select recon_unit, max(created_month) mx from bi.fact_point where recon_unit is not null group by 1) x)),
 'dq_open',(select jsonb_object_agg(rule,n) from (select rule,count(*) n from bi.dq_exception where status='open' group by 1) x),
 'mapping_needs_review',(select count(*) from bi.location_alias where review_status='needs_review')
   +(select count(*) from bi.client_alias where review_status='needs_review')+(select count(*) from bi.point_type where review_status='needs_review'))
$$;

create or replace function bi.api_forecast(p_month date, f jsonb default '{}') returns jsonb language plpgsql stable as $$
declare v_asof date; v_mtd numeric; v_tgt numeric; v_k int; v_total int; v_rr numeric; v_curve numeric; v_lo numeric; v_hi numeric; v_n int;
begin
  select snapshot_date into v_asof from bi.v_latest_snapshot where report_month=p_month;
  if v_asof is null then return jsonb_build_object('available',false,'reason','no snapshot for month'); end if;
  select sum(mtd_cases), sum(target_cases) into v_mtd, v_tgt from bi.v_zt_leaf l join bi.location lo on lo.id=l.location_id
   where l.snapshot_date=v_asof and bi.loc_ok(l.location_id,lo.recon_unit,f) and bi.fam_ok(l.client_code,f);
  v_k := bi.workdays(p_month, v_asof); v_total := bi.workdays(p_month, (p_month + interval '1 month - 1 day')::date);
  v_rr := round(v_mtd / nullif(v_k,0) * v_total);
  with s as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x join bi.location lo on lo.id=x.location_id
              where x.report_month < p_month and bi.loc_ok(x.location_id,lo.recon_unit,f) and bi.fam_ok(x.client_code,f) group by 1,2),
       fin as (select mb.month, sum(mb.cases) final from bi.v_month_business mb join bi.location lo on lo.id=mb.location_id
              where mb.month < p_month and bi.loc_ok(mb.location_id,lo.recon_unit,f) and bi.fam_ok(mb.client_code,f) group by 1),
       r as (select s.report_month, s.mtd / nullif(fin.final,0) frac from s join fin on fin.month=s.report_month
              where bi.workdays(s.report_month, s.snapshot_date) = v_k)
  select avg(frac), min(frac), max(frac), count(*) into v_curve, v_lo, v_hi, v_n from r where frac > 0;
  return jsonb_build_object('available',true,'as_of',v_asof,'mtd',v_mtd,'target',v_tgt,'workdays_elapsed',v_k,'workdays_in_month',v_total,
    'run_rate_projection',v_rr,'run_rate_achievement',round(v_rr/nullif(v_tgt,0),4),
    'curve_projection',case when v_n>=2 then round(v_mtd/v_curve) end,
    'curve_range',case when v_n>=2 then jsonb_build_array(round(v_mtd/v_hi), round(v_mtd/v_lo)) end,
    'curve_months_used',v_n,'curve_achievement',case when v_n>=2 then round(v_mtd/v_curve/nullif(v_tgt,0),4) end,
    'method_note','Run-rate = MTD / Mon-Sat working days elapsed x working days in month. Curve = MTD / average share of month-end volume reached by the same working day in past months with daily snapshots (needs >=2 months); range uses min/max share. Not a guarantee.');
end $$;

create or replace function bi.api_overview(p_month date, f jsonb default '{}') returns jsonb language plpgsql stable as $$
declare v_asof date; j jsonb; v_k int; v_pm date := (p_month - interval '1 month')::date; v_pm_snap date;
begin
  select snapshot_date into v_asof from bi.v_latest_snapshot where report_month=p_month;
  v_k := bi.workdays(p_month, coalesce(v_asof, p_month));
  select max(snapshot_date) into v_pm_snap from bi.zt_snapshot where report_month=v_pm and bi.workdays(v_pm, snapshot_date) <= v_k;
  select jsonb_build_object(
    'month',p_month,'as_of',v_asof,
    'target_cases',sum(target_cases),'mtd_cases',sum(mtd_cases),'revenue_target',sum(revenue_target),'revenue_actual',sum(revenue_actual),
    'achievement',round(sum(mtd_cases)/nullif(sum(target_cases),0),4),'revenue_achievement',round(sum(revenue_actual)/nullif(sum(revenue_target),0),4),
    'shortfall_cases',sum(target_cases)-sum(mtd_cases),'shortfall_revenue',sum(revenue_target)-sum(revenue_actual),
    'latest_change',sum(change_cases),'latest_change_basis',(select string_agg(distinct change_basis,',') from bi.v_zt_daily d2 where d2.snapshot_date=v_asof),
    'prev_snapshot',max(prev_snapshot),'negative_change_rows',count(*) filter (where change_cases<0)) into j
  from bi.v_zt_daily d join bi.location lo on lo.id=d.location_id
  where d.snapshot_date=v_asof and bi.loc_ok(d.location_id,lo.recon_unit,f) and bi.fam_ok(d.client_code,f);
  j := j || jsonb_build_object(
    'prev_month_same_day',(select jsonb_build_object('snapshot',v_pm_snap,'mtd',sum(mtd_cases)) from bi.v_zt_leaf l join bi.location lo on lo.id=l.location_id
                           where l.snapshot_date=v_pm_snap and bi.loc_ok(l.location_id,lo.recon_unit,f) and bi.fam_ok(l.client_code,f)),
    'prev_month_final',(select sum(cases) from bi.v_month_business mb join bi.location lo on lo.id=mb.location_id where mb.month=v_pm and bi.loc_ok(mb.location_id,lo.recon_unit,f) and bi.fam_ok(mb.client_code,f)),
    'same_month_last_year',(select sum(cases) from bi.v_month_business mb join bi.location lo on lo.id=mb.location_id where mb.month=(p_month - interval '1 year')::date and bi.loc_ok(mb.location_id,lo.recon_unit,f) and bi.fam_ok(mb.client_code,f)),
    'forecast',bi.api_forecast(p_month,f),
    'force',(select jsonb_build_object('tracker_cases_covered',sum(tracker_cases) filter (where case_data_available),'force_cases',sum(force_cases),
                'tracker_cases_not_covered',sum(tracker_cases) filter (where not case_data_available),
                'usage_pct',round(sum(force_cases)/nullif(sum(tracker_cases) filter (where case_data_available),0),4),
                'units_with_force_gt_tracker',count(*) filter (where force_cases>tracker_cases))
             from bi.v_force_usage fu where fu.month=p_month and bi.loc_ok(null,fu.recon_unit,f - 'location_id') and (f->>'client_family' is null or fu.client_family=f->>'client_family')
               and (f->>'location_id' is null or fu.recon_unit=(select recon_unit from bi.location where id=(f->>'location_id')::int))),
    'case_tat',(select jsonb_build_object('cases_received',count(*),'completed_valid',count(*) filter (where tat_flag='valid'),
                'median_hours',round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag='valid')::numeric,1),
                'p90_hours',round(percentile_cont(0.9) within group (order by raw_tat_hours) filter (where tat_flag='valid')::numeric,1),
                'sla_met_pct',round(avg(case when sla_met then 1.0 when sla_met=false then 0 end),4),
                'negative_durations',count(*) filter (where tat_flag='negative_duration'),'open',count(*) filter (where tat_flag='open'))
                from bi.v_case c where c.received_month=p_month and bi.loc_ok(c.location_id,c.recon_unit,f) and (f->>'client_family' is null or c.client_family=f->>'client_family')));
  return j;
end $$;

create or replace function bi.api_zonal(p_snapshot date, f jsonb default '{}') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(jsonb_build_object('location_id',d.location_id,'location',lo.label,'zone',zg.label,'region',lo.region,'tier',lo.tier,'stakeholder',lo.stakeholder,
   'client',c.label,'client_code',d.client_code,'family',c.family,'target',d.target_cases,'mtd',d.mtd_cases,'achievement',round(d.mtd_cases/nullif(d.target_cases,0),4),
   'revenue_target',d.revenue_target,'revenue',d.revenue_actual,'rate',d.rate,'shortfall_revenue',d.revenue_target-d.revenue_actual,
   'change',d.change_cases,'change_basis',d.change_basis,'prev_snapshot',d.prev_snapshot,'src_daily',d.src_daily_cases,
   'prev_month_cases',(select cases from bi.v_month_business mb where mb.month=(d.report_month - interval '1 month')::date and mb.location_id=d.location_id and mb.client_code=d.client_code))
   order by lo.region, zg.label, lo.label, d.mtd_cases desc), '[]')
from bi.v_zt_daily d join bi.location lo on lo.id=d.location_id left join bi.zone_group zg on zg.code=lo.zone_group join bi.client c on c.code=d.client_code
where d.snapshot_date=p_snapshot and (coalesce(d.target_cases,0)<>0 or coalesce(d.mtd_cases,0)<>0)
  and bi.loc_ok(d.location_id,lo.recon_unit,f) and bi.fam_ok(d.client_code,f) $$;

create or replace function bi.api_daily(p_month date, f jsonb default '{}') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(x order by x->>'date'),'[]') from (
 select jsonb_build_object('date',d.snapshot_date,'mtd',sum(d.mtd_cases),'target',sum(d.target_cases),'change',sum(d.change_cases),
   'basis',string_agg(distinct d.change_basis,','),'gap_days',max(d.gap_days),'negative_rows',count(*) filter (where d.change_cases<0)) x
 from bi.v_zt_daily d join bi.location lo on lo.id=d.location_id
 where d.report_month=p_month and bi.loc_ok(d.location_id,lo.recon_unit,f) and bi.fam_ok(d.client_code,f) group by d.snapshot_date) q $$;

create or replace function bi.api_monthly(p_from date, p_to date, f jsonb default '{}', p_group text default 'total') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(jsonb_build_object('month',month,'key',key,'cases',cases,'revenue',revenue,'billing',billing,'target',target,'source',src) order by month, key),'[]') from (
 select mb.month, case p_group when 'region' then lo.region when 'zone' then zg.label when 'location' then lo.label
          when 'stakeholder' then lo.stakeholder when 'client' then c.family when 'tier' then lo.tier else 'Total' end as key,
   sum(mb.cases) cases, sum(mb.revenue) revenue, sum(mb.billing) billing, sum(mb.target_cases) target, string_agg(distinct mb.cases_source,',') src
 from bi.v_month_business mb join bi.location lo on lo.id=mb.location_id left join bi.zone_group zg on zg.code=lo.zone_group join bi.client c on c.code=mb.client_code
 where mb.month between greatest(p_from, date '2024-04-01') and p_to and bi.loc_ok(mb.location_id,lo.recon_unit,f) and bi.fam_ok(mb.client_code,f)
 group by 1,2) q $$;

create or replace function bi.api_force(p_month date, f jsonb default '{}') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(jsonb_build_object('recon_unit',recon_unit,'client_family',client_family,'tracker_cases',tracker_cases,'force_cases',force_cases,
   'usage_pct',round(force_cases/nullif(tracker_cases,0),4),
   'estimated_manual',case when force_cases<=tracker_cases then tracker_cases-force_cases end,
   'reconciliation_excess',case when force_cases>tracker_cases then force_cases-tracker_cases end,
   'case_data_available',case_data_available,'tracker_as_of',tracker_as_of,'open_month',open_month) order by tracker_cases desc),'[]')
from bi.v_force_usage fu where month=p_month and (coalesce(tracker_cases,0)>0 or coalesce(force_cases,0)>0)
  and bi.loc_ok(null,recon_unit,f - 'location_id') and (f->>'client_family' is null or client_family=f->>'client_family') $$;

create or replace function bi.api_force_trend(f jsonb default '{}') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(jsonb_build_object('month',month,'tracker_cases_covered',tc,'force_cases',fc,'usage_pct',round(fc/nullif(tc,0),4)) order by month),'[]') from (
 select month, sum(tracker_cases) filter (where case_data_available) tc, sum(force_cases) fc from bi.v_force_usage
 where bi.loc_ok(null,recon_unit,f - 'location_id') and (f->>'client_family' is null or client_family=f->>'client_family') and month>=date '2026-01-01' group by 1) q
where tc is not null $$;

create or replace function bi.api_case_tat(p_month date, f jsonb default '{}', p_group text default 'location') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(x order by (x->>'cases')::int desc),'[]') from (
 select jsonb_build_object('key',k,'cases',count(*),'completed_valid',count(*) filter (where tat_flag='valid'),
   'median_hours',round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag='valid')::numeric,1),
   'avg_hours',round(avg(raw_tat_hours) filter (where tat_flag='valid')::numeric,1),
   'p90_hours',round(percentile_cont(0.9) within group (order by raw_tat_hours) filter (where tat_flag='valid')::numeric,1),
   'sla_met_pct',round(avg(case when sla_met then 1.0 when sla_met=false then 0 end),4),
   'open',count(*) filter (where tat_flag='open'),'negative',count(*) filter (where tat_flag='negative_duration'),
   'low_sample',count(*) filter (where tat_flag='valid')<30) x
 from (select v.*, case p_group when 'client' then v.client_family when 'branch' then v.branch when 'unit' then v.recon_unit when 'product' then coalesce(v.product,'(none)')
         else coalesce((select label from bi.location l where l.id=v.location_id), v.recon_unit||' (unit)') end k
       from bi.v_case v where v.received_month=p_month and bi.loc_ok(v.location_id,v.recon_unit,f) and (f->>'client_family' is null or v.client_family=f->>'client_family')) z
 group by k) q $$;

create or replace function bi.api_point_tat(p_month date, f jsonb default '{}', p_group text default 'category') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(x order by (x->>'points')::int desc),'[]') from (
 select jsonb_build_object('key',k,'points',count(*),'cases',count(distinct case_id),
   'field_points',count(*) filter (where category='field'),'field_tat_n',count(field_tat_hours),
   'field_median_hours',round(percentile_cont(0.5) within group (order by field_tat_hours)::numeric,1),
   'field_p90_hours',round(percentile_cont(0.9) within group (order by field_tat_hours)::numeric,1),
   'field_invalid_dates',count(*) filter (where field_tat_invalid),
   'doc_points',count(*) filter (where category='document'),'doc_tat_n',count(doc_tat_hours),
   'doc_median_hours',round(percentile_cont(0.5) within group (order by doc_tat_hours)::numeric,1),
   'tele_points',count(*) filter (where category='tele'),'tele_median_hours',round(percentile_cont(0.5) within group (order by tele_tat_hours)::numeric,1),
   'route_in_force',count(*) filter (where processing_route like 'in_force%'),
   'route_backoffice',count(*) filter (where processing_route='back_office_update_likely_outside_force'),
   'route_unknown',count(*) filter (where processing_route like 'unknown%'),
   'low_sample',count(field_tat_hours)<30) x
 from (select v.*, case p_group when 'point_type' then v.point_type when 'unit' then v.recon_unit when 'client' then v.client_code when 'executive' then coalesce(v.assign_to,'(unassigned)')
         when 'location' then coalesce((select label from bi.location l where l.id=v.location_id), v.recon_unit||' (unit)') when 'pincode' then coalesce(v.pincode,'(none)')
         when 'branch' then v.branch else v.category end k
       from bi.v_point v where v.created_month=p_month and bi.loc_ok(v.location_id,v.recon_unit,f) and bi.fam_ok(v.client_code,f)) z
 group by k) q $$;

create or replace function bi.api_manual_tat(p_month date, f jsonb default '{}') returns jsonb language sql stable as $$
with obs as (select recon_unit, client_family, percentile_cont(0.5) within group (order by raw_tat_hours) med, count(*) n
             from bi.v_case where tat_flag='valid' and received_month=p_month group by 1,2),
fam as (select client_family, percentile_cont(0.5) within group (order by raw_tat_hours) med, count(*) n from bi.v_case where tat_flag='valid' and received_month=p_month group by 1),
allc as (select percentile_cont(0.5) within group (order by raw_tat_hours) med, count(*) n from bi.v_case where tat_flag='valid' and received_month=p_month),
fu as (select * from bi.v_force_usage where month=p_month and case_data_available and tracker_cases>coalesce(force_cases,0)
         and bi.loc_ok(null,recon_unit,f - 'location_id') and (f->>'client_family' is null or client_family=f->>'client_family'))
select coalesce(jsonb_agg(jsonb_build_object('recon_unit',fu.recon_unit,'client_family',fu.client_family,'estimated_manual_cases',fu.tracker_cases-coalesce(fu.force_cases,0),
   'estimated_tat_hours',round(coalesce(case when o.n>=30 then o.med end, case when fa.n>=30 then fa.med end, a.med)::numeric,1),
   'estimate_basis',case when o.n>=30 then 'same unit & client (n='||o.n||')' when fa.n>=30 then 'same client, all units (n='||fa.n||')' else 'all observed cases (n='||a.n||')' end,
   'is_estimate',true)),'[]')
from fu left join obs o using (recon_unit, client_family) left join fam fa on fa.client_family=fu.client_family cross join allc a $$;

create or replace function bi.api_employees(p_month date, f jsonb default '{}') returns jsonb language sql stable as $$
select coalesce(jsonb_agg(x order by (x->>'points')::int desc),'[]') from (
 select jsonb_build_object('name',initcap(v.verified_by),'classification',coalesce(e.classification,'unclassified'),'override',coalesce(e.override,false),
   'points',count(*),'field',count(*) filter (where v.category='field'),'document',count(*) filter (where v.category='document'),'tele',count(*) filter (where v.category='tele'),
   'field_median_hours',round(percentile_cont(0.5) within group (order by v.field_tat_hours)::numeric,1),'field_tat_n',count(v.field_tat_hours),
   'units',string_agg(distinct v.recon_unit,', '),'verified_for_other_assignee',count(*) filter (where v.category='field' and v.assign_to is not null and v.assign_to<>v.verified_by)) x
 from bi.v_point v left join bi.employee e on e.name_key=v.verified_by
 where v.created_month=p_month and v.verified_by is not null and bi.loc_ok(v.location_id,v.recon_unit,f) and bi.fam_ok(v.client_code,f)
 group by v.verified_by, e.classification, e.override) q $$;

create or replace function bi.api_exceptions(p_limit int default 200) returns jsonb language sql stable as $$
select jsonb_build_object(
 'summary',(select coalesce(jsonb_agg(jsonb_build_object('rule',rule,'severity',severity,'status',status,'n',n) order by n desc),'[]')
            from (select rule,severity,status,count(*) n from bi.dq_exception group by 1,2,3) s),
 'negative_daily_changes',(select coalesce(jsonb_agg(jsonb_build_object('snapshot',d.snapshot_date,'prev',d.prev_snapshot,'location',l.label,'client',d.client_code,'mtd',d.mtd_cases,'prev_mtd',d.prev_mtd,'change',d.change_cases) order by d.snapshot_date desc),'[]')
            from bi.v_zt_daily d join bi.location l on l.id=d.location_id where d.change_cases<0),
 'recent',(select coalesce(jsonb_agg(to_jsonb(e) - 'batch_id' order by e.id desc),'[]') from (select * from bi.dq_exception where rule not in ('case_in_multiple_location_files','point_in_multiple_location_files') order by id desc limit p_limit) e),
 'case_tat_negative_by_unit',(select coalesce(jsonb_object_agg(recon_unit,n),'{}') from (select recon_unit,count(*) n from bi.v_case where tat_flag='negative_duration' group by 1) x),
 'force_exceeds_tracker',(select coalesce(jsonb_agg(jsonb_build_object('month',month,'unit',recon_unit,'family',client_family,'tracker',tracker_cases,'force',force_cases)),'[]')
            from bi.v_force_usage where force_cases>tracker_cases))
$$;
create or replace function bi.api_mapping_queue() returns jsonb language sql stable as $$
select jsonb_build_object(
 'locations',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'source',a.source,'alias',a.alias,'location',l.label,'location_id',a.location_id,'unit',a.recon_unit,
     'method',a.method,'confidence',a.confidence,'evidence',a.evidence,'status',a.review_status) order by a.review_status desc, a.confidence),'[]')
     from bi.location_alias a left join bi.location l on l.id=a.location_id),
 'clients',(select coalesce(jsonb_agg(jsonb_build_object('source',source,'alias',alias,'client_code',client_code,'method',method,'confidence',confidence,'status',review_status)),'[]') from bi.client_alias),
 'point_types',(select coalesce(jsonb_agg(to_jsonb(p) order by p.review_status desc, p.name),'[]') from bi.point_type p),
 'location_options',(select jsonb_agg(jsonb_build_object('id',id,'label',label) order by label) from bi.location))
$$;

create or replace function bi.api_insights(p_month date, f jsonb default '{}') returns jsonb language plpgsql stable as $$
declare v_asof date; fc jsonb; out jsonb := '[]'; r record;
begin
  select snapshot_date into v_asof from bi.v_latest_snapshot where report_month=p_month;
  fc := bi.api_forecast(p_month, f);
  if (fc->>'available')::boolean then
    out := out || jsonb_build_object('type','forecast','severity',case when (fc->>'run_rate_achievement')::numeric < 0.85 then 'high' when (fc->>'run_rate_achievement')::numeric < 1 then 'medium' else 'low' end,
      'text',format('At the current run-rate the month projects to %s cases (%s%% of target %s) as of %s; historical-curve projection %s.',
        fc->>'run_rate_projection', round((fc->>'run_rate_achievement')::numeric*100), fc->>'target', fc->>'as_of', coalesce(fc->>'curve_projection','n/a (insufficient history)')),'evidence',fc);
  end if;
  if v_asof is not null then
  for r in select lo.label, sum(l.target_cases) t, sum(l.mtd_cases) m,
              sum(l.mtd_cases) - sum(l.target_cases)*bi.workdays(p_month,v_asof)/nullif(bi.workdays(p_month,(p_month+interval '1 month - 1 day')::date),0) gap
           from bi.v_zt_leaf l join bi.location lo on lo.id=l.location_id
           where l.snapshot_date=v_asof and bi.loc_ok(l.location_id,lo.recon_unit,f) and bi.fam_ok(l.client_code,f)
           group by lo.label having sum(l.target_cases)>0 order by 4 asc limit 5 loop
    if r.gap < 0 then out := out || jsonb_build_object('type','behind_pro_rata','severity',case when r.gap < -0.2*r.t then 'high' else 'medium' end,
      'text',format('%s is %s cases behind pro-rata target (MTD %s of %s) as of %s.', r.label, round(-r.gap), r.m, r.t, v_asof),
      'evidence',jsonb_build_object('location',r.label,'mtd',r.m,'target',r.t,'gap',round(r.gap))); end if;
  end loop;
  end if;
  for r in select recon_unit, client_family, tracker_cases, force_cases from bi.v_force_usage
           where month=p_month and case_data_available and tracker_cases>=100 and bi.loc_ok(null,recon_unit,f - 'location_id')
             and force_cases/nullif(tracker_cases,0) < 0.5 order by tracker_cases - force_cases desc limit 5 loop
    out := out || jsonb_build_object('type','low_force_usage','severity','medium','text',
      format('%s / %s: %s of %s tracker cases found in Force (%s%%). The gap may be manual work, mapping or extract differences.', r.recon_unit, r.client_family, r.force_cases, r.tracker_cases, round(r.force_cases*100.0/r.tracker_cases)),
      'evidence',to_jsonb(r));
  end loop;
  for r in select recon_unit, client_family, tracker_cases, force_cases from bi.v_force_usage where month=p_month and force_cases>tracker_cases and tracker_cases>0
           and bi.loc_ok(null,recon_unit,f - 'location_id') order by force_cases-tracker_cases desc limit 5 loop
    out := out || jsonb_build_object('type','reconciliation','severity','medium','text',
      format('%s / %s: Force shows %s cases vs %s in the tracker (excess %s) - check location mapping or tracker completeness.', r.recon_unit, r.client_family, r.force_cases, r.tracker_cases, r.force_cases-r.tracker_cases),'evidence',to_jsonb(r));
  end loop;
  for r in select l.label, d.client_code, d.snapshot_date, d.change_cases from bi.v_zt_daily d join bi.location l on l.id=d.location_id
           where d.report_month=p_month and d.change_cases<0 and bi.loc_ok(d.location_id,l.recon_unit,f) order by d.change_cases limit 3 loop
    out := out || jsonb_build_object('type','negative_change','severity','low','text',format('%s / %s MTD fell by %s on %s (correction or source change).', r.label, r.client_code, -r.change_cases, r.snapshot_date),'evidence',to_jsonb(r));
  end loop;
  for r in select l.recon_unit, max(cov.month) m from bi.location l left join bi.v_case_coverage cov on cov.recon_unit=l.recon_unit
           where l.recon_unit is not null and bi.loc_ok(null,l.recon_unit,f - 'location_id') group by 1 having coalesce(max(cov.month), date '1900-01-01') < p_month loop
    out := out || jsonb_build_object('type','stale_source','severity','low','text',format('Case Wise data for %s ends at %s; Force metrics for this month are not available there.', r.recon_unit, coalesce(to_char(r.m,'Mon YYYY'),'never')),'evidence',to_jsonb(r));
  end loop;
  return out;
end $$;

create or replace function public.bi_call(p_fn text, p_args jsonb default '{}') returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare v_role text := bi.app_role(); m date := nullif(p_args->>'month','')::date; f jsonb := coalesce(p_args->'filters','{}');
begin
  if v_role is null then raise exception 'not authorised' using errcode='42501'; end if;
  return case p_fn
    when 'meta' then bi.api_meta() when 'overview' then bi.api_overview(m,f) when 'forecast' then bi.api_forecast(m,f)
    when 'zonal' then bi.api_zonal((p_args->>'snapshot')::date,f) when 'daily' then bi.api_daily(m,f)
    when 'monthly' then bi.api_monthly((p_args->>'from')::date,(p_args->>'to')::date,f,coalesce(p_args->>'group','total'))
    when 'force' then bi.api_force(m,f) when 'force_trend' then bi.api_force_trend(f)
    when 'case_tat' then bi.api_case_tat(m,f,coalesce(p_args->>'group','location'))
    when 'point_tat' then bi.api_point_tat(m,f,coalesce(p_args->>'group','category'))
    when 'manual_tat' then bi.api_manual_tat(m,f) when 'employees' then bi.api_employees(m,f) when 'insights' then bi.api_insights(m,f)
    when 'exceptions' then case when v_role='admin' then bi.api_exceptions() end
    when 'mapping_queue' then case when v_role='admin' then bi.api_mapping_queue() end
    else null end;
end $$;
revoke all on function public.bi_call(text,jsonb) from public, anon;
grant execute on function public.bi_call(text,jsonb) to authenticated;

create or replace function bi.api_mapping_update(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if p->>'kind'='location_alias' then
    update bi.location_alias set location_id=coalesce((p->>'location_id')::int,location_id), review_status=p->>'status', reviewed_by=p_actor, reviewed_at=now() where id=(p->>'id')::bigint;
  elsif p->>'kind'='point_type' then
    update bi.point_type set category=coalesce(p->>'category',category), review_status=p->>'status', reviewed_by=p_actor, reviewed_at=now() where name=p->>'name';
  elsif p->>'kind'='employee' then
    update bi.employee set classification=p->>'classification', override=true, reviewed_by=p_actor, reviewed_at=now() where name_key=bi.norm(p->>'name');
  elsif p->>'kind'='dq' then
    update bi.dq_exception set status=p->>'status' where id=(p->>'id')::bigint;
  else raise exception 'unknown kind'; end if;
  insert into bi.audit_log(actor,action,entity,entity_key,detail) values (p_actor,'mapping_update',p->>'kind',coalesce(p->>'id',p->>'name'),p);
  return jsonb_build_object('ok',true);
end $$;
create or replace function public.bi_admin(p_action text, p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if bi.app_role() is distinct from 'admin' then raise exception 'admin only' using errcode='42501'; end if;
  if p_action='mapping_update' then return bi.api_mapping_update(bi.current_email(), p); end if;
  if p_action='refresh_employees' then return jsonb_build_object('employees',bi.refresh_employee_classification()); end if;
  raise exception 'unknown action';
end $$;
revoke all on function public.bi_admin(text,jsonb) from public, anon;
grant execute on function public.bi_admin(text,jsonb) to authenticated;

