-- Applied to Supabase project via MCP on 20261108061633
-- wave 103e (8-Nov-2026): the usual share of a month reached by working day k is aligned on working days REMAINING (kk − k), not on the
-- absolute working day k. Months have 25–27 working days; on 30-Oct (k = 24 of 25, one working day left) the old rule averaged earlier
-- months at their 24th working day (two or three days left) and gave 0.903, projecting October 10.7% above the latest report; months that
-- had one working day left were at 0.952–0.963 (Jun–Sep), so the new share is 0.958. Backtest Jun–Sep (earlier months only): mean absolute
-- error 1.5% vs 2.7% in the last six working days, 3.2% vs 3.9% mid-month, 6.4% vs 7.0% in days 5–10. Falls back to the old rule when fewer
-- than two months match. Used by the Overview projection, BAU to date, Planning outlook, target-sheet expected closure, potential pace.
create or replace function bi.organic_share(p_month date, p_k integer)
returns numeric language sql stable security definer set search_path = bi, public as $f$
  with cur as (select bi.workdays(date_trunc('month', p_month)::date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date) kk),
  sn as (select z.report_month, z.snapshot_date, bi.workdays(z.report_month, (z.report_month + interval '1 month - 1 day')::date) - bi.workdays(z.report_month, z.snapshot_date) rem
           from bi.zt_snapshot z where z.report_month < date_trunc('month', p_month)::date and z.report_month >= (date_trunc('month', p_month) - interval '12 months')::date),
  fin as (select month, sum(cases) final from bi.v_month_business where month < date_trunc('month', p_month)::date and location_id is not null group by 1),
  s as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x join sn using (report_month, snapshot_date) cross join cur
         where sn.rem = cur.kk - p_k group by 1, 2),
  r as (select s.report_month, max(s.mtd) / nullif(max(fin.final), 0) frac from s join fin on fin.month = s.report_month group by 1),
  -- fallback: the earlier rule (same absolute working day)
  s0 as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x where x.report_month < date_trunc('month', p_month)::date group by 1, 2),
  r0 as (select s0.report_month, max(s0.mtd) / nullif(max(fin.final), 0) frac from s0 join fin on fin.month = s0.report_month
          where bi.workdays(s0.report_month, s0.snapshot_date) = p_k group by 1)
  select coalesce((select case when count(*) >= 2 then round(avg(frac), 8) end from r where frac > 0),
                  (select case when count(*) >= 2 then round(avg(frac), 8) end from r0 where frac > 0))
$f$;
comment on function bi.organic_share(date, integer) is 'wave 103e: usual share of a month reached with (working days in month − k) working days left; average of up to 12 earlier months; fallback = same absolute working day';
