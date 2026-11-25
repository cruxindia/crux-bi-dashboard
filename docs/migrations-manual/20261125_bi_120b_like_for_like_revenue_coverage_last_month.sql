-- Wave 120b (25-Nov-2026): like-for-like month comparisons with revenue, client-branch comparison, coverage last month.
-- Owner's weekly review 25-Nov: "against last month / against October" must compare like for like (this month so far vs the previous
-- month up to the same working day) and give revenue next to cases; coverage this month vs last month for one client (asked 4 times on
-- 24-Nov); non-core clients showing 0% coverage although they have business.
-- All changes are additive: new keys in existing results, one new column, one new function. Old definitions saved in bi.fn_backup (wave '120b').

create or replace function pg_temp.patch(p regprocedure, olds text[], news text[]) returns void language plpgsql as $$
declare d text := pg_get_functiondef(p); i int; k int;
begin
  insert into bi.fn_backup(fn, def, wave) values (p::text, d, '120b');
  for i in 1 .. array_length(olds, 1) loop
    k := (length(d) - length(replace(d, olds[i], ''))) / length(olds[i]);
    if k <> 1 then raise exception 'patch %: piece % found % times', p, i, k; end if;
    d := replace(d, olds[i], news[i]);
  end loop;
  execute d;
end $$;

-- 1. bi.api_lfl: revenue beside cases, the previous month's final figures, ids, and groups 'client_code' / 'total' (existing keys unchanged)
insert into bi.fn_backup(fn, def, wave) values ('bi.api_lfl(date,jsonb,text)', pg_get_functiondef('bi.api_lfl(date,jsonb,text)'::regprocedure), '120b');
CREATE OR REPLACE FUNCTION bi.api_lfl(p_month date, f jsonb, p_group text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'bi', 'public'
AS $function$
with s1 as (select max(snapshot_date) d from bi.zt_snapshot where report_month = p_month),
k as (select bi.workdays(p_month, (select d from s1)) n),
s0 as (select max(snapshot_date) d from bi.zt_snapshot where report_month = (p_month - interval '1 month')::date
        and bi.workdays((p_month - interval '1 month')::date, snapshot_date) <= (select n from k)),
sf as (select max(snapshot_date) d from bi.zt_snapshot where report_month = (p_month - interval '1 month')::date),   -- wave 120: previous month's final report
r as (select l.snapshot_date,
             case p_group when 'client' then coalesce(c.family, l.client_code) when 'client_code' then l.client_code when 'stakeholder' then lo.stakeholder
                          when 'zone' then lo.zone_group when 'total' then 'Total' else lo.label end k,
             case p_group when 'location' then l.location_id::text when 'client' then coalesce(c.family, l.client_code) when 'client_code' then l.client_code
                          when 'zone' then lo.zone_group when 'total' then 'TOTAL' end kid,
             l.mtd_cases, l.revenue_actual
      from bi.v_zt_leaf l join bi.location lo on lo.id = l.location_id left join bi.client c on c.code = l.client_code
      where l.snapshot_date in ((select d from s1), (select d from s0), (select d from sf))
        and bi.loc_ok(l.location_id, lo.recon_unit, f, l.snapshot_date) and bi.fam_ok(l.client_code, f)),
g as (select k, max(kid) kid,
             sum(mtd_cases) filter (where snapshot_date = (select d from s1)) cur, sum(mtd_cases) filter (where snapshot_date = (select d from s0)) prev,
             sum(revenue_actual) filter (where snapshot_date = (select d from s1)) rcur, sum(revenue_actual) filter (where snapshot_date = (select d from s0)) rprev,
             sum(mtd_cases) filter (where snapshot_date = (select d from sf)) fin, sum(revenue_actual) filter (where snapshot_date = (select d from sf)) rfin
      from r group by k)
select jsonb_build_object('current_snapshot', (select d from s1), 'comparison_snapshot', (select d from s0),
  'basis', 'same working day (Mon-Sat) of the previous month', 'working_days', (select n from k),
  'total_current', (select sum(cur) from g), 'total_previous', (select sum(prev) from g),
  'total_revenue_current', (select round(sum(rcur)) from g), 'total_revenue_previous', (select round(sum(rprev)) from g),
  'previous_month_final_snapshot', (select d from sf), 'previous_month_final_cases', (select sum(fin) from g), 'previous_month_final_revenue', (select round(sum(rfin)) from g),
  'rows', coalesce((select jsonb_agg(jsonb_build_object('group', k, 'id', kid, 'current', cur, 'previous', prev, 'change', coalesce(cur, 0) - coalesce(prev, 0),
                     'revenue_current', round(rcur), 'revenue_previous', round(rprev), 'revenue_change', round(coalesce(rcur, 0) - coalesce(rprev, 0)),
                     'previous_month_final_cases', fin, 'previous_month_final_revenue', round(rfin))
                     order by coalesce(cur, 0) - coalesce(prev, 0)) from g), '[]'));
$function$;

-- 2. Client branches this month vs the previous month to the same working day (Force1 cases by branch code), with estimated revenue
CREATE OR REPLACE FUNCTION bi.api_branch_lfl(p_month date, f jsonb DEFAULT '{}'::jsonb, p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'bi', 'public'
 SET statement_timeout TO '40s'
AS $function$
declare m date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
        pm date; d1 date; d0 date; n int; v_sort text := coalesce(nullif(p->>'sort', ''), 'decline');
        v_lim int := least(greatest(coalesce((p->>'limit')::int, 25), 1), 100); v_out jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  pm := (m - interval '1 month')::date;
  if v_sort not in ('decline', 'growth', 'cases', 'lowest') then v_sort := 'decline'; end if;
  select max((s.received_at at time zone 'Asia/Kolkata')::date) into d1 from bi.case_store s where s.received_month = m;
  if d1 is null then return jsonb_build_object('error', 'no Force1 cases for ' || to_char(m, 'Mon-YYYY'), 'month', m); end if;
  n := bi.workdays(m, d1);
  select max(g::date) into d0 from generate_series(pm, m - 1, interval '1 day') g where bi.workdays(pm, g::date) <= n;
  with locs as materialized (select l.id from bi.location l where bi.loc_ok(l.id, l.recon_unit, f)),
  cs as materialized (
    select s.client_code, coalesce(cl.family, s.client_code) fam, bi.norm_code(s.branch_code) code, s.location_id,
           (s.received_at at time zone 'Asia/Kolkata')::date d, s.received_month rm
      from bi.case_store s left join bi.client cl on cl.code = s.client_code
     where s.received_month in (m, pm) and bi.norm_code(s.branch_code) is not null and bi.fam_ok(s.client_code, f)
       and (f - 'client_family' = '{}'::jsonb or s.location_id in (select id from locs))),
  agg as (select client_code, fam, code, location_id,
                 count(*) filter (where rm = m and d <= d1) cur, count(*) filter (where rm = pm and d <= d0) prev, count(*) filter (where rm = pm) prev_full
            from cs group by 1, 2, 3, 4),
  rate as (select distinct on (z.location_id, z.client_code) z.location_id, z.client_code, z.rate
             from bi.v_zt_leaf z where z.report_month in (m, pm) and z.rate > 0 order by z.location_id, z.client_code, z.snapshot_date desc),
  nm as (select distinct on (b.client_family, b.code_norm) b.client_family fam, b.code_norm code, b.branch_name, b.branch_code, bi.unit_type(b.branch_name, b.branch_type) ut
           from bi.client_branch_master b where b.code_norm in (select code from agg) order by b.client_family, b.code_norm, (b.status = 'active') desc, b.branch_uid),
  r as (select a.*, coalesce(nm.branch_name, 'branch code ' || a.code) branch, nm.branch_code, nm.ut unit_type, l.label team, rt.rate,
               a.cur * rt.rate est_cur, a.prev * rt.rate est_prev, a.prev_full * rt.rate est_prev_full
          from agg a left join nm on nm.fam = a.fam and nm.code = a.code left join bi.location l on l.id = a.location_id
          left join rate rt on rt.location_id = a.location_id and rt.client_code = a.client_code
         where a.cur > 0 or a.prev > 0)
  select jsonb_build_object('month', m, 'filters', f, 'force1_as_of', d1, 'comparison_month', pm, 'compared_to', d0, 'working_days', n,
    'basis', 'Force1 cases by client branch (bank branch code) received ' || to_char(m, 'Mon') || ' 1 to ' || to_char(d1, 'DD-Mon') || ' vs ' || to_char(pm, 'Mon') || ' 1 to '
             || to_char(d0, 'DD-Mon') || ' (the same working day, Mon-Sat). Force1 runs to its own date, which can differ from the Zonal Tracker date.',
    'revenue_note', 'Estimated revenue = Force1 cases × the team''s Zonal Tracker rate for that client (latest report of the month). The tracker does not split business by client branch, so branch revenue is an estimate; team and client revenue come from the tracker.',
    'totals', (select jsonb_build_object('branches', count(*), 'cases_current', sum(cur), 'cases_previous_same_day', sum(prev), 'cases_previous_month_full', sum(prev_full),
                  'est_revenue_current', round(sum(est_cur)), 'est_revenue_previous_same_day', round(sum(est_prev)), 'est_revenue_previous_month_full', round(sum(est_prev_full)),
                  'branches_fell', count(*) filter (where cur < prev), 'branches_grew', count(*) filter (where cur > prev), 'branches_no_case_yet_this_month', count(*) filter (where cur = 0 and prev > 0),
                  'cases_without_rate', coalesce(sum(cur) filter (where rate is null), 0)) from r),
    'sorted_by', case v_sort when 'decline' then 'biggest fall in cases first' when 'growth' then 'biggest rise in cases first' when 'cases' then 'most cases this month first'
                             else 'fewest cases this month first (branches that had cases last month)' end,
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('client_code', client_code, 'branch', branch, 'branch_code', coalesce(branch_code, code), 'unit_type', unit_type, 'team', team, 'team_id', location_id,
                 'cases_current', cur, 'cases_previous_same_day', prev, 'change', cur - prev, 'change_pct', round((cur - prev)::numeric / nullif(prev, 0), 4), 'cases_previous_month_full', prev_full,
                 'rate', rate, 'est_revenue_current', round(est_cur), 'est_revenue_previous_same_day', round(est_prev), 'est_revenue_change', round(est_cur - est_prev)) order by o), '[]'::jsonb)
               from (select r.*, row_number() over (order by case v_sort when 'growth' then -(cur - prev) when 'cases' then -cur when 'lowest' then cur else (cur - prev) end, prev desc, branch) o
                       from r where v_sort <> 'lowest' or prev > 0) z where o <= v_lim))
    into v_out;
  return v_out;
end $function$;

select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure,
  array[$a$when 'lfl' then bi.api_lfl(m,f,coalesce(p_args->>'group','location'))$a$],
  array[$a$when 'lfl' then bi.api_lfl(m,f,coalesce(p_args->>'group','location'))
      when 'branch_lfl' then bi.api_branch_lfl(m, f, coalesce(p_args->'p', '{}'::jsonb))   -- wave 120b$a$]);

-- 3. Coverage last month: the last Force1 case month before the current month, per client branch
alter table bi.branch_activity add column if not exists prev_last_m date;
comment on column bi.branch_activity.prev_last_m is 'wave 120b: last Force1 case month before the current month (IST) — coverage as at the end of the previous month';
select pg_temp.patch('bi.branch_activity_refresh()'::regprocedure,
  array[$a$insert into bi.branch_activity(fam, code_norm, last_m, first_m, n, n3, refreshed_at)$a$,
        $a$and s.received_month < date_trunc('month', current_date)::date), now()$a$,
        $a$refreshed_at = excluded.refreshed_at;$a$],
  array[$a$insert into bi.branch_activity(fam, code_norm, last_m, first_m, n, n3, refreshed_at, prev_last_m)$a$,
        $a$and s.received_month < date_trunc('month', current_date)::date), now(),
         max(s.received_month) filter (where s.received_month < date_trunc('month', now() at time zone 'Asia/Kolkata')::date)$a$,
        $a$refreshed_at = excluded.refreshed_at, prev_last_m = excluded.prev_last_m;$a$]);
select bi.branch_activity_refresh();

select pg_temp.patch('bi.api_drill_ops(date,jsonb,text,text)'::regprocedure,
  array[$a$x as (select v.*, a.last_m, a.n, a.n3,$a$,
        $a$count(*) filter (where last_m >= (select c from cut)) active_6m,$a$,
        $a$'coverage_6m', round(a.active_6m::numeric / nullif(a.matchable, 0), 4),$a$,
        $a$Same definitions as Business tracker → branch coverage.');$a$],
  array[$a$x as (select v.*, a.last_m, a.n, a.n3, a.prev_last_m,$a$,
        $a$count(*) filter (where last_m >= (select c from cut)) active_6m,
                 count(*) filter (where prev_last_m >= ((select c from cut) - interval '1 month')::date) active_6m_prev,$a$,
        $a$'coverage_6m', round(a.active_6m::numeric / nullif(a.matchable, 0), 4),
            'active_6m_prev_month', coalesce(a.active_6m_prev, 0), 'coverage_6m_prev_month', round(a.active_6m_prev::numeric / nullif(a.matchable, 0), 4),
            'coverage_change_pts', round(100 * (a.active_6m - a.active_6m_prev)::numeric / nullif(a.matchable, 0), 1),$a$,
        $a$Last month = the same count at the end of the previous month (a Force1 case in the 6 months before it), on today''s branch list; change in points = coverage now minus last month. Coverage counts Force1 cases only: a client with business in the Zonal Tracker but no Force1 cases shows 0% (not measured). Same definitions as Business tracker → branch coverage.');$a$]);

select pg_temp.patch('bi.api_branch_coverage(jsonb)'::regprocedure,
  array[$a$select v.*, a.last_m, a.first_m, a.n, a.n3, l.label location$a$,
        $a$count(*) filter (where v.last_m >= (select c from cut)) active_with_crux_6m,$a$,
        $a$lv as (select r.family fam,$a$,
        $a$'coverage_6m', case when website_source then null else round(active_with_crux_6m::numeric / nullif(verified_active, 0), 4) end,$a$,
        $a$from bc left join cl on cl.fam = bc.client_code left join lv on lv.fam = bc.client_code),$a$,
        $a$'coverage_6m', round(sum(active_with_crux_6m)::numeric / nullif(sum(verified_active - website_listed), 0), 4),$a$,
        $a$'active_with_crux_6m', a, 'coverage_6m', round(a::numeric / nullif(nm, 0), 4))$a$,
        $a$count(*) filter (where last_m >= (select c from cut)) a,$a$,
        $a$other clients there have no team yet and are counted under the zone.')$a$],
  array[$a$select v.*, a.last_m, a.first_m, a.n, a.n3, a.prev_last_m, l.label location$a$,
        $a$count(*) filter (where v.last_m >= (select c from cut)) active_with_crux_6m,
              count(*) filter (where v.prev_last_m >= ((select c from cut) - interval '1 month')::date) active_prev,$a$,
        $a$biz as (select cl2.family fam, sum(mb.revenue) rev6 from bi.v_month_business mb join bi.client cl2 on cl2.code = mb.client_code
              where mb.month >= (select c from cut) and mb.location_id in (select id from locs) group by 1),
f1c as (select coalesce(cl3.family, s.client_code) fam, count(*) n6 from bi.case_store s left join bi.client cl3 on cl3.code = s.client_code
         where s.received_month >= (select c from cut) and (coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb or s.location_id in (select id from locs)) group by 1),
lv as (select r.family fam,$a$,
        $a$'coverage_6m', case when website_source then null else round(active_with_crux_6m::numeric / nullif(verified_active, 0), 4) end,
       'active_with_crux_6m_prev_month', case when website_source then null else active_prev end,
       'coverage_6m_prev_month', case when website_source then null else round(active_prev::numeric / nullif(verified_active, 0), 4) end,
       'coverage_change_pts', case when website_source then null else round(100 * (active_with_crux_6m - active_prev)::numeric / nullif(verified_active, 0), 1) end,
       'force1_cases_6m', coalesce(f1c.n6, 0), 'tracker_revenue_6m', round(coalesce(biz.rev6, 0)),
       'coverage_measured', not (website_source or (coalesce(f1c.n6, 0) = 0 and coalesce(biz.rev6, 0) > 0)),
       'coverage_note', case when website_source then null
                             when coalesce(f1c.n6, 0) = 0 and coalesce(biz.rev6, 0) > 0 then 'business in the Zonal Tracker but no Force1 cases in the last 6 months: coverage cannot be measured (0% here does not mean no business)'
                             when coalesce(f1c.n6, 0) = 0 then 'no Crux business with this client in the last 6 months' end,$a$,
        $a$from bc left join cl on cl.fam = bc.client_code left join lv on lv.fam = bc.client_code left join biz on biz.fam = bc.client_code left join f1c on f1c.fam = bc.client_code),$a$,
        $a$'coverage_6m', round(sum(active_with_crux_6m)::numeric / nullif(sum(verified_active - website_listed), 0), 4),
       'active_with_crux_6m_prev_month', sum(active_prev), 'coverage_6m_prev_month', round(sum(active_prev)::numeric / nullif(sum(verified_active - website_listed), 0), 4),
       'coverage_change_pts', round(100 * (sum(active_with_crux_6m) - sum(active_prev))::numeric / nullif(sum(verified_active - website_listed), 0), 1),$a$,
        $a$'active_with_crux_6m', a, 'coverage_6m', round(a::numeric / nullif(nm, 0), 4), 'coverage_6m_prev_month', round(ap::numeric / nullif(nm, 0), 4),
       'coverage_change_pts', round(100 * (a - ap)::numeric / nullif(nm, 0), 1))$a$,
        $a$count(*) filter (where last_m >= (select c from cut)) a, count(*) filter (where prev_last_m >= ((select c from cut) - interval '1 month')::date) ap,$a$,
        $a$other clients there have no team yet and are counted under the zone. Last month = the same count as at the end of the previous month (a Force1 case in the 6 months before it), on today''s branch list; change in points = coverage now minus last month. Coverage counts Force1 cases only: a client with business in the Zonal Tracker but no Force1 cases shows 0%, which means not measured, not no business (see coverage_note).')$a$]);

-- cached results of the changed functions are recomputed on the next request
delete from bi.api_cache where fn in ('lfl', 'branch_coverage') or (fn = 'drill_ops' and args->>'part' = 'coverage');
