-- Applied to Supabase project via MCP on 20261118083644
-- wave 111a (14-Nov-2026): one "likely month end" everywhere.
-- Before: Business tracker / drill-downs used per-group revenue multipliers (₹1.649 cr on 14-Nov), Management summary / Root cause /
-- branch managers / plan used the usual share of the month done by this working day (₹1.663 cr), and the plan read that share rounded
-- to 4 decimals (₹575 off). Now every page and Ask Crux use: likely = so far ÷ usual share of the month done
-- by this working day (bi.organic_share: past 12 months, same number of working days left); range = so far ÷ highest / lowest share.
-- Because the share is the same for every group, zone, team and client likely values add up exactly to the total.
-- backups of replaced function definitions (for rollback; not exposed to the API)
create table if not exists bi.fn_backup (id bigserial primary key, fn text not null, def text not null, wave text, saved_at timestamptz default now());
revoke all on bi.fn_backup from anon, authenticated;

create or replace function bi.month_share3(p_month date, p_k integer) returns jsonb language sql stable set search_path to 'bi', 'public' as $f$
  with cur as (select bi.workdays(date_trunc('month', p_month)::date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date) kk),
  sn as (select z.report_month, z.snapshot_date, bi.workdays(z.report_month, (z.report_month + interval '1 month - 1 day')::date) - bi.workdays(z.report_month, z.snapshot_date) rem
           from bi.zt_snapshot z where z.report_month < date_trunc('month', p_month)::date and z.report_month >= (date_trunc('month', p_month) - interval '12 months')::date),
  fin as (select month, sum(cases) final from bi.v_month_business where month < date_trunc('month', p_month)::date and location_id is not null group by 1),
  s as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x join sn using (report_month, snapshot_date) cross join cur
         where sn.rem = cur.kk - p_k group by 1, 2),
  r as (select s.report_month, max(s.mtd) / nullif(max(fin.final), 0) frac from s join fin on fin.month = s.report_month group by 1),
  s0 as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x where x.report_month < date_trunc('month', p_month)::date group by 1, 2),
  r0 as (select s0.report_month, max(s0.mtd) / nullif(max(fin.final), 0) frac from s0 join fin on fin.month = s0.report_month
          where bi.workdays(s0.report_month, s0.snapshot_date) = p_k group by 1),
  a as (select 'same working days left' rule, count(*) n, round(avg(frac), 8) av, round(min(frac), 8) lo, round(max(frac), 8) hi from r where frac > 0),
  b as (select 'same working day' rule, count(*) n, round(avg(frac), 8) av, round(min(frac), 8) lo, round(max(frac), 8) hi from r0 where frac > 0)
  select case when (select n from a) >= 2 then (select jsonb_build_object('avg', av, 'lo', lo, 'hi', hi, 'n', n, 'rule', rule) from a)
              when (select n from b) >= 2 then (select jsonb_build_object('avg', av, 'lo', lo, 'hi', hi, 'n', n, 'rule', rule) from b) end
$f$;
comment on function bi.month_share3(date, integer) is 'wave 111: usual share of a month done by working day p_k (avg = bi.organic_share) with its lowest and highest month; one rule for every likely month end.';

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

-- api_potential (and api_drill_ops, which reads it): likely / low / high from the month share
select pg_temp.patch('bi.api_potential(date,jsonb,text,text)'::regprocedure, array[
  'case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then gs.med else ps.med end mmed,',
  'case when rem = 0 then 1 when (msx.ms->>''avg'') is not null then 1 / (msx.ms->>''avg'')::numeric else case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then gs.med else ps.med end end mmed,   -- wave 111: month share',
  'case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then gs.lo else ps.lo end mlo,',
  'case when rem = 0 then 1 when (msx.ms->>''hi'') is not null then 1 / (msx.ms->>''hi'')::numeric else case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then gs.lo else ps.lo end end mlo,',
  'case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then gs.hi else ps.hi end mhi,',
  'case when rem = 0 then 1 when (msx.ms->>''lo'') is not null then 1 / (msx.ms->>''lo'')::numeric else case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then gs.hi else ps.hi end end mhi,',
  'case when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then ''own'' else ''pan'' end basis, coalesce(gs.n, 0) months_used,',
  'case when rem = 0 then ''complete'' when (msx.ms->>''avg'') is not null then ''month share'' when gs.n >= 2 and c.mtd >= case when meas = ''cases'' then 30 else 7500 end then ''own'' else ''pan'' end basis, coalesce((msx.ms->>''n'')::int, gs.n, 0) months_used,',
  'from cur c left join gstats gs on gs.g = c.g cross join pstats ps',
  'from cur c left join gstats gs on gs.g = c.g cross join pstats ps cross join (select bi.month_share3(m, k) ms) msx',
  '''likely'', ''Likely month end = business so far × how much a month usually grows from this working day to month end (average share of the month normally done by this working day in past months with daily reports — the same basis as the Overview projection; low/high = the weakest and strongest of those months).'',
      ''basis'', ''Own = this row''''s own past months; Pan India = the overall pattern, used when the row has fewer than 2 past months or very small numbers.'',',
  '''likely'', ''Likely month end = business so far ÷ the usual share of a month done by this working day: the average over past months with daily reports and the same number of working days left (the same rule on every page and in Ask Crux, so zones, teams and clients add up to the total); low/high = so far ÷ the highest / lowest of those months.'',
      ''basis'', ''Month share = the rule above; Complete = the month is over (likely = actual); Own / Pan India = older per-row rule, used only when fewer than 2 past months exist.'','
], array[1,1,1,1,1,1]);

-- api_plan: the live share at full precision (it read the nightly value rounded to 4 decimals)
select pg_temp.patch('bi.api_plan(date,jsonb,jsonb)'::regprocedure, array[
  'from bi.potential_run x order by x.run_id desc limit 1;',
  'from bi.potential_run x order by x.run_id desc limit 1;
  if v_share is not null and v_share < 1 and v_asof is not null then v_share := coalesce(bi.organic_share(v_ref, bi.workdays(v_ref, v_asof)), v_share); end if;   -- wave 111: same share as every page'
], array[1]);

-- nightly potential run: keep the share at full precision for every reader (targets, target sheet, growth, split, plan admin, Ask Crux)
select pg_temp.patch('bi.potential_refresh()'::regprocedure, array[
  '''share_to_date'', round(v_share, 4)', '''share_to_date'', round(v_share, 8)'
], array[1]);
update bi.potential_run r set inputs = jsonb_set(r.inputs, '{share_to_date}', to_jsonb(coalesce(bi.organic_share(r.month, bi.workdays(r.month, r.as_of)), (r.inputs->>'share_to_date')::numeric)))
 where r.run_id = (select max(run_id) from bi.potential_run) and (r.inputs->>'share_to_date')::numeric < 1;
delete from bi.api_cache where fn in ('potential','drill_ops','plan','targets','target_sheet','growth','split','organic','market_potential','bm','tracker_sheet');
