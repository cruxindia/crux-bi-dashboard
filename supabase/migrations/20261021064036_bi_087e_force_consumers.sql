-- Applied to Supabase project via MCP on 20261021064036
-- bi_087e (21-Oct-2026): every Force1 case-utilisation figure uses validated (matched) cases (AUDIT_REGISTER A2)
-- utilisation = sum(matched_cases) / sum(tracker_cases), covered location groups only; excess shown separately as a reconciliation exception.
-- Row level (location group x client family): utilisation is withheld (null) when status is over / no_business_row; the figures stay visible.

create or replace function bi.api_force(p_month date, f jsonb default '{}'::jsonb) returns jsonb language sql stable as $function$
select coalesce(jsonb_agg(jsonb_build_object('recon_unit',recon_unit,'client_family',client_family,'tracker_cases',tracker_cases,'force_cases',force_cases,
   'matched_cases',matched_cases,'excess_cases',excess_cases,'recon_status',recon_status,
   'usage_pct',case when recon_status='ok' then round(matched_cases/nullif(tracker_cases,0),4) end,
   'estimated_manual',case when recon_status='ok' then tracker_cases-matched_cases end,
   'reconciliation_excess',nullif(excess_cases,0),
   'force_cases_processed',force_cases_processed,'attributed_in',attributed_in,'attributed_out',attributed_out,
   'case_data_available',case_data_available,'tracker_as_of',tracker_as_of,'open_month',open_month) order by tracker_cases desc nulls last),'[]')
from bi.v_force_usage fu where month=p_month and (coalesce(tracker_cases,0)>0 or coalesce(force_cases,0)>0)
  and bi.loc_ok(null,recon_unit,f - 'location_id') and (f->>'client_family' is null or client_family=f->>'client_family') $function$;

create or replace function bi.api_force_trend(f jsonb default '{}'::jsonb) returns jsonb language sql stable as $function$
select coalesce(jsonb_agg(jsonb_build_object('month',month,'tracker_cases_covered',tc,'force_cases',fc,'matched_cases',mc,'excess_cases',xc,
         'rows_under_reconciliation',ro,'usage_pct',round(mc/nullif(tc,0),4)) order by month),'[]') from (
 select month, sum(tracker_cases) filter (where case_data_available) tc, sum(force_cases) fc, sum(matched_cases) mc, sum(excess_cases) xc,
        count(*) filter (where recon_status in ('over','no_business_row')) ro
 from bi.v_force_usage
 where bi.loc_ok(null,recon_unit,f - 'location_id') and (f->>'client_family' is null or client_family=f->>'client_family') and month>=date '2026-01-01' group by 1) q
where tc is not null $function$;

create or replace function bi.api_exceptions(p_limit integer default 200) returns jsonb language sql stable as $function$
select jsonb_build_object(
 'summary',(select coalesce(jsonb_agg(jsonb_build_object('rule',rule,'severity',severity,'status',status,'n',n) order by n desc),'[]')
            from (select rule,severity,status,count(*) n from bi.dq_exception group by 1,2,3) s),
 'negative_daily_changes',(select coalesce(jsonb_agg(jsonb_build_object('snapshot',d.snapshot_date,'prev',d.prev_snapshot,'location',l.label,'client',d.client_code,'mtd',d.mtd_cases,'prev_mtd',d.prev_mtd,'change',d.change_cases) order by d.snapshot_date desc),'[]')
            from bi.v_zt_daily d join bi.location l on l.id=d.location_id where d.change_cases<0),
 'recent',(select coalesce(jsonb_agg(to_jsonb(e) - 'batch_id' order by e.id desc),'[]') from (select * from bi.dq_exception where rule not in ('case_in_multiple_location_files','point_in_multiple_location_files') order by id desc limit p_limit) e),
 'case_tat_negative_by_unit',(select coalesce(jsonb_object_agg(recon_unit,n),'{}') from (select recon_unit,count(*) n from bi.v_case where tat_flag='negative_duration' group by 1) x),
 'force_exceeds_tracker',(select coalesce(jsonb_agg(jsonb_build_object('month',month,'unit',recon_unit,'family',client_family,'tracker',tracker_cases,'force',force_cases,
                                   'excess',excess_cases,'status',recon_status) order by month desc, excess_cases desc),'[]')
            from bi.v_force_usage where recon_status in ('over','no_business_row')))
$function$;

create or replace function bi.api_manual_tat(p_month date, f jsonb default '{}'::jsonb) returns jsonb language sql stable as $function$
with obs as (select recon_unit, client_family, percentile_cont(0.5) within group (order by raw_tat_hours) med, count(*) n
             from bi.v_case where tat_flag='valid' and received_month=p_month group by 1,2),
fam as (select client_family, percentile_cont(0.5) within group (order by raw_tat_hours) med, count(*) n from bi.v_case where tat_flag='valid' and received_month=p_month group by 1),
allc as (select percentile_cont(0.5) within group (order by raw_tat_hours) med, count(*) n from bi.v_case where tat_flag='valid' and received_month=p_month),
fu as (select * from bi.v_force_usage where month=p_month and recon_status='ok' and tracker_cases>matched_cases
         and bi.loc_ok(null,recon_unit,f - 'location_id') and (f->>'client_family' is null or client_family=f->>'client_family'))
select coalesce(jsonb_agg(jsonb_build_object('recon_unit',fu.recon_unit,'client_family',fu.client_family,'estimated_manual_cases',fu.tracker_cases-fu.matched_cases,
   'estimated_tat_hours',round(coalesce(case when o.n>=30 then o.med end, case when fa.n>=30 then fa.med end, a.med)::numeric,1),
   'estimate_basis',case when o.n>=30 then 'same unit & client (n='||o.n||')' when fa.n>=30 then 'same client, all units (n='||fa.n||')' else 'all observed cases (n='||a.n||')' end,
   'is_estimate',true)),'[]')
from fu left join obs o using (recon_unit, client_family) left join fam fa on fa.client_family=fu.client_family cross join allc a $function$;

do $do$
declare r record; d text; cur text := null; n int;
begin
  for r in select * from (values
    (1,'bi.api_overview(date,jsonb)',
     $a$'usage_pct',round(sum(force_cases)/nullif(sum(tracker_cases) filter (where case_data_available),0),4),$a$,
     $b$'usage_pct',round(sum(matched_cases)/nullif(sum(tracker_cases) filter (where case_data_available),0),4),'matched_cases',sum(matched_cases),'excess_cases',sum(excess_cases),'measure','validated (matched) Force1 cases / tracker cases',$b$,1),
    (2,'bi.api_overview(date,jsonb)',
     $a$'units_with_force_gt_tracker',count(*) filter (where force_cases>tracker_cases))$a$,
     $b$'units_with_force_gt_tracker',count(*) filter (where recon_status in ('over','no_business_row')))$b$,1),
    (1,'bi.api_insights(date,jsonb)',
     $a$and force_cases/nullif(tracker_cases,0) < 0.5 order by tracker_cases - force_cases desc limit 5 loop$a$,
     $b$and recon_status='ok' and matched_cases/nullif(tracker_cases,0) < 0.5 order by tracker_cases - matched_cases desc limit 5 loop$b$,1),
    (2,'bi.api_insights(date,jsonb)',
     $a$from bi.v_force_usage where month=p_month and force_cases>tracker_cases and tracker_cases>0$a$,
     $b$from bi.v_force_usage where month=p_month and recon_status='over' and tracker_cases>0$b$,1),
    (3,'bi.api_insights(date,jsonb)',
     $a$format('%s / %s: Force shows %s cases vs %s in the tracker (excess %s) - check location mapping or tracker completeness.'$a$,
     $b$format('%s / %s: %s Force1 cases belong here by bank branch against %s business cases in the tracker (%s above it). Utilisation for this row is withheld until reconciled - check branch-to-location mapping and tracker completeness.'$b$,1),
    (1,'bi.api_force1(date,jsonb)',
     $a$case_u as (select recon_unit as unit, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases from bi.v_force_usage$a$,
     $b$case_u as (select recon_unit as unit, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases, sum(matched_cases) matched_cases, sum(excess_cases) excess_cases,
     count(*) filter (where recon_status in ('over','no_business_row')) rows_over, sum(force_cases_processed) processed_cases, sum(attributed_in) attributed_in, sum(attributed_out) attributed_out from bi.v_force_usage$b$,1),
    (2,'bi.api_force1(date,jsonb)',
     $a$u as (select coalesce(c.unit, p.unit) as unit, c.tracker_cases, c.force1_cases, p.field_points,$a$,
     $b$u as (select coalesce(c.unit, p.unit) as unit, c.tracker_cases, c.force1_cases, c.matched_cases, c.excess_cases, c.rows_over, c.processed_cases, c.attributed_in, c.attributed_out, p.field_points,$b$,1),
    (3,'bi.api_force1(date,jsonb)',
     $a$tot as (select (select sum(tracker_cases) from case_u) tracker_cases, (select sum(force1_cases) from case_u) force1_cases,$a$,
     $b$tot as (select (select sum(tracker_cases) from case_u) tracker_cases, (select sum(force1_cases) from case_u) force1_cases,
     (select sum(matched_cases) from case_u) matched_cases, (select sum(excess_cases) from case_u) excess_cases, (select sum(rows_over) from case_u) rows_over,$b$,1),
    (4,'bi.api_force1(date,jsonb)',
     $a$trend_c as (select v.month as mon, sum(force_cases) force1_cases, sum(tracker_cases) tracker_cases from bi.v_force_usage v$a$,
     $b$trend_c as (select v.month as mon, sum(force_cases) force1_cases, sum(matched_cases) matched_cases, sum(excess_cases) excess_cases, sum(tracker_cases) tracker_cases from bi.v_force_usage v$b$,1),
    (5,'bi.api_force1(date,jsonb)',
     $a$'recon_unit', unit, 'tracker_cases', tracker_cases, 'force1_cases', force1_cases, 'case_utilisation', round(force1_cases::numeric / nullif(tracker_cases,0), 4),$a$,
     $b$'recon_unit', unit, 'tracker_cases', tracker_cases, 'force1_cases', force1_cases, 'matched_cases', matched_cases, 'excess_cases', excess_cases,
      'rows_under_reconciliation', rows_over, 'processed_cases', processed_cases, 'attributed_in', attributed_in, 'attributed_out', attributed_out,
      'case_utilisation', round(matched_cases::numeric / nullif(tracker_cases,0), 4),$b$,1),
    (6,'bi.api_force1(date,jsonb)',
     $a$'tracker_cases', tracker_cases, 'force1_cases', force1_cases, 'case_utilisation', round(force1_cases::numeric / nullif(tracker_cases,0), 4),$a$,
     $b$'tracker_cases', tracker_cases, 'force1_cases', force1_cases, 'matched_cases', matched_cases, 'excess_cases', excess_cases, 'rows_under_reconciliation', rows_over,
      'case_utilisation', round(matched_cases::numeric / nullif(tracker_cases,0), 4),$b$,1),
    (7,'bi.api_force1(date,jsonb)',
     $a$'case_utilisation', round(c.force1_cases::numeric / nullif(c.tracker_cases,0),4),$a$,
     $b$'case_utilisation', round(c.matched_cases::numeric / nullif(c.tracker_cases,0),4), 'tracker_cases', c.tracker_cases, 'force1_cases', c.force1_cases, 'matched_cases', c.matched_cases, 'excess_cases', c.excess_cases,$b$,1),
    (8,'bi.api_force1(date,jsonb)',
     $a$'case_utilisation', 'Force1 cases received in the month / Zonal Tracker cases, same location group, client family and month; only where Case Wise data exists',$a$,
     $b$'case_utilisation', 'Validated Force1 cases / Zonal Tracker cases, same location group, client family and month, only where the Case Wise file was received. A Force1 case belongs to the tracker location of its bank branch (client branch master); when the branch is not located, to the team that processed it. Validated (matched) = Force1 cases up to the business count of that location group and client family.',
      'excess_cases', 'Force1 cases above the business count of a location group and client family. A reconciliation exception (tracker incomplete or branch mapped to the wrong location), never utilisation above 100 %.',$b$,1),
    (1,'bi.api_drill_ops(date,jsonb,text,text)',
     $a$cagg as (select ft.k id, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases from ft group by 1),$a$,
     $b$cagg as (select ft.k id, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases, sum(matched_cases) matched_cases, sum(excess_cases) excess_cases,
                     count(*) filter (where recon_status in ('over','no_business_row')) rows_over from ft group by 1),$b$,1),
    (2,'bi.api_drill_ops(date,jsonb,text,text)',
     $a$'tracker_cases', c.tracker_cases, 'force1_cases', c.force1_cases, 'case_utilisation', round(c.force1_cases::numeric / nullif(c.tracker_cases, 0), 4),$a$,
     $b$'tracker_cases', c.tracker_cases, 'force1_cases', c.force1_cases, 'matched_cases', c.matched_cases, 'excess_cases', c.excess_cases, 'rows_under_reconciliation', c.rows_over,
              'case_utilisation', round(c.matched_cases::numeric / nullif(c.tracker_cases, 0), 4),$b$,1),
    (3,'bi.api_drill_ops(date,jsonb,text,text)',
     $a$'Case utilisation = Force1 cases ÷ Zonal Tracker cases for location groups with Force1 case data$a$,
     $b$'Case utilisation = validated Force1 cases (attributed by bank branch; at most the business count per location group and client) ÷ Zonal Tracker cases for location groups with Force1 case data; cases above the business count are shown as excess under reconciliation$b$,1)
  ) v(ord, fn, a, b, cnt) order by fn, ord loop
    if cur is distinct from r.fn then
      if cur is not null then execute d; end if;
      cur := r.fn; d := pg_get_functiondef(r.fn::regprocedure);
    end if;
    n := (length(d) - length(replace(d, r.a, ''))) / length(r.a);
    if n <> r.cnt then raise exception '% patch %: expected % occurrence(s) of [%], found %', r.fn, r.ord, r.cnt, left(r.a, 90), n; end if;
    d := replace(d, r.a, r.b);
  end loop;
  if cur is not null then execute d; end if;
end $do$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'force1_utilisation', 'bi_087e',
        jsonb_build_object('rule', 'utilisation = validated (matched) Force1 cases / tracker cases; excess = reconciliation exception', 'register', 'A2'));
