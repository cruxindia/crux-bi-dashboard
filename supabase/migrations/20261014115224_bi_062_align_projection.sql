-- Applied to Supabase project via MCP on 20261014115224
-- align: organic share unrounded (projection = forecast curve), potential "likely" uses the same averaging as the forecast curve (mean of share-to-date)
create or replace function bi.organic_share(p_month date, p_k int) returns numeric language sql stable security definer set search_path to 'bi','public' as $fn$
  with s as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x where x.report_month < date_trunc('month', p_month)::date group by 1, 2),
  fin as (select month, sum(cases) final from bi.v_month_business where month < date_trunc('month', p_month)::date and location_id is not null group by 1),
  r as (select s.report_month, max(s.mtd) / nullif(max(fin.final), 0) frac from s join fin on fin.month = s.report_month
        where bi.workdays(s.report_month, s.snapshot_date) = p_k group by 1)
  select case when count(*) >= 2 then round(avg(frac), 8) end from r where frac > 0
$fn$;

do $do$
declare d text := pg_get_functiondef('bi.api_potential(date,jsonb,text,text)'::regprocedure);
begin
  if position('1 / avg(1 / mlt)' in d) = 0 then
    d := replace(d, 'pstats as (select percentile_cont(0.5) within group (order by mlt)::numeric med,', 'pstats as (select 1 / avg(1 / mlt) med,');
    d := replace(d, 'gstats as (select g, percentile_cont(0.5) within group (order by mlt)::numeric med,', 'gstats as (select g, 1 / avg(1 / mlt) med,');
    d := replace(d, '(median of the past months with daily reports; low/high = the weakest and strongest of those months)', '(average share of the month normally done by this working day in past months with daily reports — the same basis as the Overview projection; low/high = the weakest and strongest of those months)');
    if position('1 / avg(1 / mlt)' in d) = 0 then raise exception 'api_potential patch failed'; end if;
    execute d;
  end if;
end $do$;
insert into bi.audit_log(actor,action,entity,detail) values ('migration','cache_bump','api_cache','{"reason":"bi_062 projection alignment"}');
