-- Applied to Supabase project via MCP on 20261021071600
create or replace function bi.api_lfl(p_month date, f jsonb, p_group text) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with s1 as (select max(snapshot_date) d from bi.zt_snapshot where report_month = p_month),
k as (select bi.workdays(p_month, (select d from s1)) n),
s0 as (select max(snapshot_date) d from bi.zt_snapshot where report_month = (p_month - interval '1 month')::date
        and bi.workdays((p_month - interval '1 month')::date, snapshot_date) <= (select n from k)),
r as (select l.snapshot_date,
             case p_group when 'client' then coalesce(c.family, l.client_code) when 'stakeholder' then lo.stakeholder when 'zone' then lo.zone_group else lo.label end k,
             l.mtd_cases
      from bi.v_zt_leaf l join bi.location lo on lo.id = l.location_id left join bi.client c on c.code = l.client_code
      where l.snapshot_date in ((select d from s1), (select d from s0))
        and bi.loc_ok(l.location_id, lo.recon_unit, f, l.snapshot_date) and bi.fam_ok(l.client_code, f)),
g as (select k, sum(mtd_cases) filter (where snapshot_date = (select d from s1)) cur, sum(mtd_cases) filter (where snapshot_date = (select d from s0)) prev from r group by k)
select jsonb_build_object('current_snapshot', (select d from s1), 'comparison_snapshot', (select d from s0),
  'basis', 'same working day (Mon-Sat) of the previous month', 'working_days', (select n from k),
  'total_current', (select sum(cur) from g), 'total_previous', (select sum(prev) from g),
  'rows', coalesce((select jsonb_agg(jsonb_build_object('group', k, 'current', cur, 'previous', prev, 'change', coalesce(cur, 0) - coalesce(prev, 0))
                     order by coalesce(cur, 0) - coalesce(prev, 0)) from g), '[]'));
$function$;

create or replace function bi.fmt_n(x numeric) returns text language sql immutable as
$f$ select case when x is null then 'n/a' when x < 0 then '-' || to_char(round(abs(x)), 'FM99,99,99,99,99,999') else to_char(round(x), 'FM99,99,99,99,99,999') end $f$;
create or replace function bi.fmt_s(x numeric) returns text language sql immutable as
$f$ select case when x is null then 'n/a' when x > 0 then '+' || bi.fmt_n(x) else bi.fmt_n(x) end $f$;
create or replace function bi.fmt_p(x numeric) returns text language sql immutable as
$f$ select case when x is null then 'n/a' else to_char(round(x * 100, 1), 'FM9999990.0') || '%' end $f$;
create or replace function bi.fmt_h(x numeric) returns text language sql immutable as
$f$ select case when x is null then 'n/a' when abs(x) >= 48 then to_char(round(x / 24, 1), 'FM99990.0') || ' d' else to_char(round(x, 1), 'FM99990.0') || ' h' end $f$;
create or replace function bi.fmt_inr(x numeric) returns text language sql immutable as
$f$ select case when x is null then 'n/a' when abs(x) >= 10000000 then '₹' || to_char(round(x / 10000000, 2), 'FM99990.00') || ' cr'
                when abs(x) >= 100000 then '₹' || to_char(round(x / 100000, 2), 'FM99990.00') || ' L' else '₹' || bi.fmt_n(x) end $f$;

create or replace function bi.ask_perf(m date, f jsonb, grp text) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with s1 as (select max(snapshot_date) d from bi.zt_snapshot where report_month = m),
wd as (select bi.workdays(m, (select d from s1)) e, bi.workdays(m, (m + interval '1 month - 1 day')::date) t),
lf as (select bi.api_lfl(m, f, case grp when 'zone' then 'zone' when 'client' then 'client' else 'location' end) j),
p as (select e->>'group' k, (e->>'previous')::numeric prev from lf, jsonb_array_elements(lf.j->'rows') e),
r as (select case grp when 'client' then coalesce(c.family, l.client_code) when 'zone' then lo.zone_group else lo.label end k,
             min(lo.id) loc_id, min(lo.zone_group) zone, sum(l.target_cases) target, sum(l.mtd_cases) mtd, sum(l.revenue_actual) revenue, sum(l.revenue_target) revenue_target
      from bi.v_zt_leaf l join bi.location lo on lo.id = l.location_id left join bi.client c on c.code = l.client_code
      where l.snapshot_date = (select d from s1) and bi.loc_ok(l.location_id, lo.recon_unit, f, l.snapshot_date) and bi.fam_ok(l.client_code, f)
      group by 1),
x as (select r.*, p.prev, round(r.mtd / nullif((select e from wd), 0) * (select t from wd)) proj from r left join p on p.k = r.k)
select jsonb_build_object('as_of', (select d from s1), 'comparison_snapshot', (select j->>'comparison_snapshot' from lf),
  'workdays_elapsed', (select e from wd), 'workdays_total', (select t from wd), 'group', grp,
  'rows', coalesce(jsonb_agg(jsonb_build_object('key', x.k,
     'label', case grp when 'zone' then coalesce((select label from bi.zone_group z where z.code = x.k), x.k) else x.k end,
     'location_id', case when grp = 'location' then x.loc_id end, 'zone', x.zone,
     'target', x.target, 'mtd', x.mtd, 'prev_same_point', x.prev, 'change', x.mtd - x.prev,
     'achievement', round(x.mtd / nullif(x.target, 0), 4), 'projection', x.proj, 'projected_gap', x.target - x.proj,
     'pace_gap', round(x.mtd - x.target * (select e from wd)::numeric / nullif((select t from wd), 0)),
     'revenue', x.revenue, 'revenue_target', x.revenue_target) order by x.target - x.proj desc nulls last), '[]'::jsonb))
from x
$function$;

create or replace function bi.ask_tat_stats(p_months date[], f jsonb, grp text) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with fe as (select (coalesce(f, '{}'::jsonb) - 'client_family') = '{}'::jsonb nofilter),
lok as (select l.id from bi.location l where bi.loc_ok(l.id, l.recon_unit, f)),
uok as (select distinct l.recon_unit u from bi.location l where l.recon_unit is not null and bi.loc_ok(null, l.recon_unit, f)),
fok as (select code from bi.client where bi.fam_ok(code, f)),
dr as (select (select start_field from bi.tat_rule where measure = 'document') s, (select end_field from bi.tat_rule where measure = 'document') e,
              coalesce((select back_entry_minutes from bi.tat_rule where measure = 'case'), 15) be),
c as (select s.received_month m, case grp when 'client' then cl.family when 'location' then s.location_id::text else s.recon_unit end k,
             count(*) n, round(avg(h)::numeric, 1) avg,
             round(percentile_cont(0.5) within group (order by h)::numeric, 1) median,
             round(percentile_cont(0.9) within group (order by h)::numeric, 1) p90,
             count(*) filter (where h * 60 < (select be from dr)) back_entered
      from (select s.*, bi.tat_hours(s.received_at, s.completed_at) h from bi.case_store s
            where s.received_month = any(p_months) and s.received_at >= '2024-03-31 18:30:00+00' and upper(s.status) = 'COMPLETED' and s.completed_at >= s.received_at) s
      left join bi.client cl on cl.code = s.client_code
      where ((select nofilter from fe) or s.location_id in (select id from lok) or (s.location_id is null and s.recon_unit in (select u from uok)))
        and (f->>'client_family' is null or cl.family = f->>'client_family')
      group by 1, 2),
p as (select q.m, q.k, count(fh) field_n, round(percentile_cont(0.5) within group (order by fh)::numeric, 1) field_median,
             round(percentile_cont(0.9) within group (order by fh)::numeric, 1) field_p90,
             count(dh) doc_n, round(percentile_cont(0.5) within group (order by dh)::numeric, 1) doc_median,
             round(percentile_cont(0.9) within group (order by dh)::numeric, 1) doc_p90
      from (select p.created_month m,
                   case grp when 'client' then cl.family when 'location' then cs.location_id::text else coalesce(cs.recon_unit, p.recon_unit) end k,
                   case when t.category = 'field' and p.field_reviewed_at < p.assigned_at + interval '120 days' then bi.tat_hours(p.assigned_at, p.field_reviewed_at) end fh,
                   case when t.category = 'document' then bi.tat_hours(
                          case (select s from dr) when 'assigned_at' then p.assigned_at when 'assigned_at_else_created_at' then coalesce(p.assigned_at, p.created_at) else p.created_at end,
                          case (select e from dr) when 'field_reviewed_at' then p.field_reviewed_at else p.completed_at end) end dh
            from bi.point_store p join bi.dim d on d.id = p.point_type_id join bi.point_type t on t.name = d.val
            left join bi.case_store cs on cs.case_id = p.case_id
            left join bi.client cl on cl.code = coalesce(cs.client_code, p.client_code_raw)
            where p.created_month = any(p_months) and p.created_at >= '2024-03-31 18:30:00+00' and t.category in ('field', 'document')
              and ((select nofilter from fe) or cs.location_id in (select id from lok) or (cs.location_id is null and coalesce(cs.recon_unit, p.recon_unit) in (select u from uok)))
              and (f->>'client_family' is null or coalesce(cs.client_code, p.client_code_raw) in (select code from fok))) q
      group by 1, 2)
select coalesce(jsonb_agg(jsonb_build_object('month', coalesce(c.m, p.m), 'key', coalesce(c.k, p.k),
   'label', case when grp = 'location' then (select label from bi.location where id::text = coalesce(c.k, p.k)) else coalesce(c.k, p.k) end,
   'case_n', coalesce(c.n, 0), 'case_avg', c.avg, 'case_median', c.median, 'case_p90', c.p90, 'case_back_entered', coalesce(c.back_entered, 0),
   'field_n', coalesce(p.field_n, 0), 'field_median', p.field_median, 'field_p90', p.field_p90,
   'doc_n', coalesce(p.doc_n, 0), 'doc_median', p.doc_median, 'doc_p90', p.doc_p90)), '[]'::jsonb)
from c full join p on p.m = c.m and p.k is not distinct from c.k
$function$;
