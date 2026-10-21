-- Applied to Supabase project via MCP on 20261021064319
-- bi_087f (21-Oct-2026): Force1 reconciliation for Data Health (AUDIT_REGISTER A2)
-- Identity checked by tests: force1_cases_total = matched + excess + outside_scope + attributed_to_groups_without_case_file
create or replace function bi.api_force1_recon(p_month date, f jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with v as (select * from bi.v_force_usage where month = p_month and bi.loc_ok(null, recon_unit, f - 'location_id')
             and (f->>'client_family' is null or client_family = f->>'client_family')),
lat as (select max(snapshot_date) as as_of, p_month = (select max(report_month) from bi.zt_snapshot) as is_open from bi.zt_snapshot where report_month = p_month),
cov as (select recon_unit from bi.v_case_coverage where month = p_month),
auth as (select sum(mb.cases) total from bi.v_month_business mb join bi.location l on l.id = mb.location_id
          where mb.month = p_month and not l.is_rollup and bi.loc_ok(mb.location_id, l.recon_unit, f - 'location_id') and bi.fam_ok(mb.client_code, f)),
d as (select x.*, (x.attr_unit <> '~outside' and c.recon_unit is null) as to_uncovered
       from bi.force_case_daily x cross join lat left join cov c on c.recon_unit = x.attr_unit
       where x.month = p_month and x.n > 0 and (not coalesce(lat.is_open, false) or x.received_date <= lat.as_of)
         and bi.loc_ok(null, case when x.attr_unit = '~outside' then x.proc_unit else x.attr_unit end, f - 'location_id')
         and (f->>'client_family' is null or x.client_family = f->>'client_family')),
fc as (select sum(n) total, sum(n) filter (where by_branch) by_branch, sum(n) filter (where not by_branch) by_team,
              sum(n) filter (where attr_unit = '~outside') outside,
              sum(n) filter (where to_uncovered) uncovered,
              sum(n) filter (where attr_unit <> proc_unit) moved
       from d),
dup as (select count(*) n from bi.dq_exception e join bi.import_batch b on b.id = e.batch_id
         where e.rule = 'case_in_multiple_location_files' and b.period_month = p_month)
select jsonb_build_object(
  'month', p_month, 'tracker_as_of', (select as_of from lat), 'open_month', (select is_open from lat),
  'authoritative_tracker_cases', (select total from auth),
  'eligible_tracker_cases', (select sum(tracker_cases) from v where case_data_available),
  'not_covered_tracker_cases', (select sum(tracker_cases) from v where not case_data_available),
  'force1_cases_total', (select total from fc),
  'force1_by_branch', (select by_branch from fc),
  'force1_by_processing_team', (select by_team from fc),
  'force1_moved_to_branch_location', (select moved from fc),
  'force1_outside_scope', (select outside from fc),
  'force1_to_groups_without_case_file', (select uncovered from fc),
  'matched_cases', (select sum(matched_cases) from v),
  'excess_cases', (select sum(excess_cases) from v),
  'unmatched_tracker_cases', (select sum(tracker_cases - matched_cases) from v where case_data_available),
  'duplicate_case_rows_rejected', (select n from dup),
  'utilisation', round((select sum(matched_cases) from v) / nullif((select sum(tracker_cases) from v where case_data_available), 0), 4),
  'rows_under_reconciliation', (select count(*) from v where recon_status in ('over', 'no_business_row')),
  'status', case when (select sum(tracker_cases) from v where case_data_available) is null then 'unavailable'
                 when (select count(*) from v where recon_status in ('over', 'no_business_row')) = 0 then 'reconciled'
                 else 'exceptions' end,
  'rows', (select coalesce(jsonb_agg(jsonb_build_object('recon_unit', recon_unit, 'client_family', client_family, 'tracker_cases', tracker_cases,
              'force1_cases', force_cases, 'processed_here', force_cases_processed, 'attributed_in', attributed_in, 'attributed_out', attributed_out,
              'matched_cases', matched_cases, 'excess_cases', excess_cases, 'status', recon_status,
              'utilisation', case when recon_status = 'ok' then round(matched_cases / nullif(tracker_cases, 0), 4) end)
              order by (recon_status in ('over', 'no_business_row')) desc, excess_cases desc nulls last, tracker_cases desc nulls last), '[]'::jsonb)
           from v where coalesce(tracker_cases, 0) > 0 or coalesce(force_cases, 0) > 0 or force_cases_processed > 0),
  'definitions', jsonb_build_object(
    'authoritative_tracker_cases', 'Zonal Tracker business cases for the month (location rows only, zone sub-totals excluded); open month = latest tracker date',
    'eligible_tracker_cases', 'Tracker cases of location groups whose Force1 Case Wise file was received for the month - the utilisation denominator',
    'force1_cases_total', 'Distinct Force1 case ids received in the month (open month: up to the tracker date); a case id is stored once',
    'force1_by_branch', 'Cases placed by their bank branch (client branch master); the rest fall back to the team that processed them',
    'matched_cases', 'Per location group x client family: Force1 cases up to the tracker count - the utilisation numerator',
    'excess_cases', 'Force1 cases above the tracker count of a location group x client family - reconciliation exception',
    'force1_outside_scope', 'Cases whose branch sits in a tracker location without a Force1 location group',
    'force1_to_groups_without_case_file', 'Cases placed in a location group that sent no Case Wise file this month (its tracker cases are not in the denominator)',
    'duplicate_case_rows_rejected', 'Case rows found in more than one location file at import (kept once)'))
$function$;

do $do$
declare d text := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure); a text := $a$when 'force1' then bi.api_force1(m,f)$a$;
begin
  if position('force1_recon' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'bi_call anchor not found exactly once'; end if;
  execute replace(d, a, a || E'\n      when ''force1_recon'' then bi.api_force1_recon(m,f)');
end $do$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'force1_reconciliation', 'bi_087f', jsonb_build_object('api', 'force1_recon', 'register', 'A2'));
