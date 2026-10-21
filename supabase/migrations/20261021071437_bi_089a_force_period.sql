-- Applied to Supabase project via MCP on 20261021071437
-- bi_089a (21-Oct-2026): Force1 utilisation compares the same period on both sides (open month)
create or replace function bi.force_open_cut() returns table(month date, snap date, case_cut date, latest_snap date)
language sql stable security definer set search_path to 'bi', 'public' as $function$
with om as (select max(report_month) m from bi.zt_snapshot),
cc as (select max(received_date) cut from bi.force_case_daily where month = (select m from om) and n > 0)
select (select m from om),
       coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = (select m from om) and snapshot_date <= (select cut from cc)),
                (select max(snapshot_date) from bi.zt_snapshot where report_month = (select m from om))),
       (select cut from cc),
       (select max(snapshot_date) from bi.zt_snapshot where report_month = (select m from om))
$function$;

create or replace view bi.v_force_usage as
with oc as (select * from bi.force_open_cut()),
tr_closed as (
  select mb.month, l.recon_unit, c.family as client_family, sum(mb.cases) as tracker_cases, max(mb.as_of) as tracker_as_of, false as open_month
  from bi.v_month_business mb join bi.location l on l.id = mb.location_id join bi.client c on c.code = mb.client_code
  where l.recon_unit is not null and not l.is_rollup and mb.month <> (select month from oc)
  group by mb.month, l.recon_unit, c.family),
tr_open as (
  select z.report_month as month, l.recon_unit, c.family as client_family, sum(z.mtd_cases) as tracker_cases, max(z.snapshot_date) as tracker_as_of, true as open_month
  from bi.v_zt_leaf z join bi.location l on l.id = z.location_id join bi.client c on c.code = z.client_code
  where l.recon_unit is not null and not l.is_rollup and z.snapshot_date = (select snap from oc)
  group by z.report_month, l.recon_unit, c.family),
tr as (select * from tr_closed union all select * from tr_open),
latest as (select report_month as month, max(snapshot_date) as as_of from bi.zt_snapshot group by 1),
keys as (select month, recon_unit, client_family from tr
         union select month, attr_unit, client_family from bi.force_case_daily where n > 0 and attr_unit <> '~outside'
         union select month, proc_unit, client_family from bi.force_case_daily where n > 0),
base as (
  select k.month, k.recon_unit, k.client_family, tr.tracker_cases,
         coalesce(tr.tracker_as_of, case when k.month = (select month from oc) then (select snap from oc) else lt.as_of end) as tracker_as_of,
         coalesce(tr.open_month, k.month = (select month from oc)) as open_month,
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

comment on view bi.v_force_usage is 'Force1 case utilisation per month x location group x client family (bi_087/bi_089a). Open month: tracker snapshot on or before the last Force1 case date, Force1 cases up to that snapshot. force_cases = cases attributed by bank branch (else processing team); matched_cases = least(force, tracker) = the only utilisation numerator; excess_cases = reconciliation exception.';

do $do$
declare d text := pg_get_functiondef('bi.api_force1_recon(date,jsonb)'::regprocedure); r record; n int;
begin
  if position('force_open_cut' in d) > 0 then return; end if;
  for r in select * from (values
   (1, $a$lat as (select max(snapshot_date) as as_of, p_month = (select max(report_month) from bi.zt_snapshot) as is_open from bi.zt_snapshot where report_month = p_month),$a$,
       $b$lat as (select case when p_month = oc.month then oc.snap else (select max(snapshot_date) from bi.zt_snapshot where report_month = p_month) end as as_of,
                  p_month = oc.month as is_open, oc.case_cut, oc.latest_snap from bi.force_open_cut() oc),$b$),
   (2, $a$auth as (select sum(mb.cases) total from bi.v_month_business mb join bi.location l on l.id = mb.location_id
          where mb.month = p_month and not l.is_rollup and bi.loc_ok(mb.location_id, l.recon_unit, f - 'location_id') and bi.fam_ok(mb.client_code, f)),$a$,
       $b$auth as (select case when (select is_open from lat)
                   then (select sum(z.mtd_cases) from bi.v_zt_leaf z join bi.location l on l.id = z.location_id
                         where z.snapshot_date = (select as_of from lat) and not l.is_rollup and bi.loc_ok(z.location_id, l.recon_unit, f - 'location_id') and bi.fam_ok(z.client_code, f))
                   else (select sum(mb.cases) from bi.v_month_business mb join bi.location l on l.id = mb.location_id
                         where mb.month = p_month and not l.is_rollup and bi.loc_ok(mb.location_id, l.recon_unit, f - 'location_id') and bi.fam_ok(mb.client_code, f)) end total),$b$),
   (3, $a$'month', p_month, 'tracker_as_of', (select as_of from lat), 'open_month', (select is_open from lat),$a$,
       $b$'month', p_month, 'tracker_as_of', (select as_of from lat), 'open_month', (select is_open from lat),
  'force1_data_to', case when (select is_open from lat) then (select case_cut from lat) end,
  'tracker_latest_snapshot', case when (select is_open from lat) then (select latest_snap from lat) end,
  'period_note', case when (select is_open from lat) and (select as_of from lat) < (select latest_snap from lat)
                      then format('Force1 case data runs to %s, so both sides are compared up to the tracker of %s (latest tracker: %s).',
                                  to_char((select case_cut from lat), 'DD-Mon'), to_char((select as_of from lat), 'DD-Mon'), to_char((select latest_snap from lat), 'DD-Mon')) end,$b$)
  ) v(ord, a, b) order by ord loop
    n := (length(d) - length(replace(d, r.a, ''))) / length(r.a);
    if n <> 1 then raise exception 'recon patch %: found % times', r.ord, n; end if;
    d := replace(d, r.a, r.b);
  end loop;
  execute d;
end $do$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'force1_utilisation', 'bi_089a', jsonb_build_object('change', 'open month compared up to the tracker snapshot on or before the last Force1 case date'));
