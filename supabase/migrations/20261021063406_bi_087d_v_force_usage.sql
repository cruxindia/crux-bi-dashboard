-- Applied to Supabase project via MCP on 20261021063406
-- bi_087d (21-Oct-2026): one definition of Force1 case utilisation (AUDIT_REGISTER A2)
-- force_cases   = Force1 cases attributed to this location group (bank branch's tracker location; processing team when the branch is not located)
-- matched_cases = least(force_cases, tracker_cases)  — the only numerator used for utilisation
-- excess_cases  = force_cases above the business count — a reconciliation exception, never utilisation above 100 %
-- recon_status  = ok | over | no_business_row | not_covered
create or replace view bi.v_force_usage as
with tr as (
  select mb.month, l.recon_unit, c.family as client_family, sum(mb.cases) as tracker_cases, max(mb.as_of) as tracker_as_of,
         bool_or(mb.cases_source = 'tracker_snapshot') as open_month
  from bi.v_month_business mb join bi.location l on l.id = mb.location_id join bi.client c on c.code = mb.client_code
  where l.recon_unit is not null and not l.is_rollup
  group by mb.month, l.recon_unit, c.family),
latest as (select report_month as month, max(snapshot_date) as as_of from bi.zt_snapshot group by 1),
keys as (select month, recon_unit, client_family from tr
         union select month, attr_unit, client_family from bi.force_case_daily where n > 0 and attr_unit <> '~outside'
         union select month, proc_unit, client_family from bi.force_case_daily where n > 0),
base as (
  select k.month, k.recon_unit, k.client_family, tr.tracker_cases,
         coalesce(tr.tracker_as_of, lt.as_of) as tracker_as_of,
         coalesce(tr.open_month, k.month = (select max(month) from latest)) as open_month,
         cov.month is not null as case_data_available
  from keys k left join tr using (month, recon_unit, client_family)
  left join latest lt on lt.month = k.month
  left join bi.v_case_coverage cov on cov.recon_unit = k.recon_unit and cov.month = k.month),
cnt as (
  select b.month, b.recon_unit, b.client_family,
         sum(d.n) filter (where d.attr_unit = b.recon_unit) as f_attr,
         sum(d.n) filter (where d.proc_unit = b.recon_unit) as f_proc,
         sum(d.n) filter (where d.attr_unit = b.recon_unit and d.proc_unit <> b.recon_unit) as f_in,
         sum(d.n) filter (where d.proc_unit = b.recon_unit and d.attr_unit <> b.recon_unit) as f_out
  from base b join bi.force_case_daily d on d.month = b.month and d.client_family = b.client_family
                     and (d.attr_unit = b.recon_unit or d.proc_unit = b.recon_unit)
                     and (not b.open_month or d.received_date <= b.tracker_as_of)
  where d.n > 0
  group by 1, 2, 3)
select b.month, b.recon_unit, b.client_family, b.tracker_cases, b.tracker_as_of, b.open_month, b.case_data_available,
       case when b.case_data_available then coalesce(c.f_attr, 0)::numeric end as force_cases,
       coalesce(c.f_proc, 0)::numeric as force_cases_processed,
       case when b.case_data_available then least(coalesce(c.f_attr, 0), coalesce(b.tracker_cases, 0))::numeric end as matched_cases,
       case when b.case_data_available then greatest(coalesce(c.f_attr, 0) - coalesce(b.tracker_cases, 0), 0)::numeric end as excess_cases,
       case when not b.case_data_available then 'not_covered'
            when coalesce(b.tracker_cases, 0) = 0 and coalesce(c.f_attr, 0) > 0 then 'no_business_row'
            when coalesce(c.f_attr, 0) > coalesce(b.tracker_cases, 0) then 'over'
            else 'ok' end as recon_status,
       coalesce(c.f_in, 0)::numeric as attributed_in, coalesce(c.f_out, 0)::numeric as attributed_out
from base b left join cnt c using (month, recon_unit, client_family);

comment on view bi.v_force_usage is 'Force1 case utilisation per month x location group x client family (bi_087). force_cases = cases attributed by bank branch (else processing team); matched_cases = least(force, tracker) = the only utilisation numerator; excess_cases = reconciliation exception; recon_status ok / over / no_business_row / not_covered.';
