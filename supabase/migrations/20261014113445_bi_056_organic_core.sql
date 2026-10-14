-- Applied to Supabase project via MCP on 20261014113445
-- bi_056: Organic expectation (business-as-usual benchmark) — chosen by back-test (see docs/METRICS.md)
create or replace function bi.organic_ratio() returns table(m date, r numeric) language sql stable security definer set search_path to 'bi','public' as $fn$
  with lastc as (select (date_trunc('month', max(snapshot_date)) - interval '1 month')::date lc from bi.zt_snapshot),
  pan as (select mb.month m, sum(mb.cases)::numeric v from bi.v_month_business mb, lastc where mb.month between date '2024-04-01' and lastc.lc and mb.location_id is not null group by 1),
  w as (select pan.m, pan.v / bi.workdays(pan.m, (pan.m + interval '1 month - 1 day')::date) vw from pan)
  select w.m, case when count(*) over win = 12 then round(w.vw / nullif(avg(w.vw) over win, 0), 4) end r from w window win as (order by w.m rows between 5 preceding and 6 following)
$fn$;

create or replace function bi.organic_si(p_month date) returns numeric language sql stable security definer set search_path to 'bi','public' as $fn$
  select coalesce(round(avg(r), 4), 1) from bi.organic_ratio() where r is not null
     and m in ((date_trunc('month', p_month) - interval '12 months')::date, (date_trunc('month', p_month) - interval '24 months')::date)
$fn$;

create or replace function bi.organic_pairs(p_month date)
returns table(location_id int, client_code text, organic numeric, v1 numeric, v2 numeric, v3 numeric, wd1 int, wd2 int, wd3 int, wd int, si_t numeric, si1 numeric, si2 numeric, si3 numeric, d1 numeric, d2 numeric, d3 numeric)
language sql stable security definer set search_path to 'bi','public' as $fn$
  with t as (select date_trunc('month', p_month)::date t),
  mm as (select k, (t.t - make_interval(months => k))::date m, bi.workdays((t.t - make_interval(months => k))::date, ((t.t - make_interval(months => k)) + interval '1 month - 1 day')::date) wd,
                bi.organic_si((t.t - make_interval(months => k))::date) si from t, generate_series(0, 3) k),
  hist as (select mb.location_id, mb.client_code, mb.month, sum(mb.cases)::numeric v from bi.v_month_business mb, t
           where mb.month between (t.t - interval '3 months')::date and (t.t - interval '1 month')::date and mb.location_id is not null group by 1, 2, 3),
  pairs as (select distinct h.location_id, h.client_code from hist h
            union select z.location_id, z.client_code from bi.zt_row z, t where z.row_type = 'leaf' and z.location_id is not null
              and z.snapshot_date = (select max(snapshot_date) from bi.zt_snapshot where report_month = t.t)),
  x as (select p.location_id, p.client_code,
          coalesce((select v from hist h join mm on mm.k = 1 where h.location_id = p.location_id and h.client_code = p.client_code and h.month = mm.m), 0) v1,
          coalesce((select v from hist h join mm on mm.k = 2 where h.location_id = p.location_id and h.client_code = p.client_code and h.month = mm.m), 0) v2,
          coalesce((select v from hist h join mm on mm.k = 3 where h.location_id = p.location_id and h.client_code = p.client_code and h.month = mm.m), 0) v3
        from pairs p)
  select x.location_id, x.client_code,
         round((0.7 * x.v1 / m1.wd / m1.si + 0.2 * x.v2 / m2.wd / m2.si + 0.1 * x.v3 / m3.wd / m3.si) * m0.si * m0.wd, 1) organic,
         x.v1, x.v2, x.v3, m1.wd, m2.wd, m3.wd, m0.wd, m0.si, m1.si, m2.si, m3.si,
         round(x.v1 / m1.wd / m1.si, 3), round(x.v2 / m2.wd / m2.si, 3), round(x.v3 / m3.wd / m3.si, 3)
  from x, mm m0, mm m1, mm m2, mm m3 where m0.k = 0 and m1.k = 1 and m2.k = 2 and m3.k = 3
$fn$;

create or replace function bi.organic_share(p_month date, p_k int) returns numeric language sql stable security definer set search_path to 'bi','public' as $fn$
  with s as (select x.report_month, x.snapshot_date, sum(x.mtd_cases) mtd from bi.v_zt_leaf x where x.report_month < date_trunc('month', p_month)::date group by 1, 2),
  fin as (select month, sum(cases) final from bi.v_month_business where month < date_trunc('month', p_month)::date and location_id is not null group by 1),
  r as (select s.report_month, max(s.mtd) / nullif(max(fin.final), 0) frac from s join fin on fin.month = s.report_month
        where bi.workdays(s.report_month, s.snapshot_date) = p_k group by 1)
  select case when count(*) >= 2 then round(avg(frac), 4) end from r where frac > 0
$fn$;
