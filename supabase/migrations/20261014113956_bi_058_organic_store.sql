-- Applied to Supabase project via MCP on 20261014113956
create table if not exists bi.organic_store (
  month date not null, location_id int not null, client_code text not null, organic numeric,
  v1 numeric, v2 numeric, v3 numeric, wd1 int, wd2 int, wd3 int, wd int, si_t numeric, si1 numeric, si2 numeric, si3 numeric,
  computed_at timestamptz not null default now(), primary key (month, location_id, client_code));
alter table bi.organic_store enable row level security;
comment on table bi.organic_store is 'Organic (business-as-usual) expectation per month, location and client. Formula in bi.organic_refresh / docs/METRICS.md.';

create or replace function bi.organic_refresh() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare n int; cur date := (select max(report_month) from bi.zt_snapshot); v bigint := (select coalesce(max(id), 0) from bi.audit_log); t0 timestamptz := clock_timestamp();
begin
  with mb as (select month m, location_id, client_code, sum(cases)::numeric v from bi.v_month_business
              where month between date '2024-04-01' and (cur - interval '1 month')::date and location_id is not null group by 1, 2, 3),
  months as (select generate_series(date '2024-04-01', cur, interval '1 month')::date m),
  wd as (select m, bi.workdays(m, (m + interval '1 month - 1 day')::date) wd from months),
  pan as (select mb.m, sum(mb.v) v from mb group by 1),
  rr as (select pan.m, case when count(*) over w = 12 then (pan.v / wd.wd) / nullif(avg(pan.v / wd.wd) over w, 0) end r
         from pan join wd on wd.m = pan.m window w as (order by pan.m rows between 5 preceding and 6 following)),
  si as (select months.m, coalesce(round((select avg(rr.r) from rr where rr.r is not null and rr.m in ((months.m - interval '12 months')::date, (months.m - interval '24 months')::date)), 4), 1) si from months),
  pairs as (select distinct location_id, client_code from mb
            union select location_id, client_code from bi.zt_row where row_type = 'leaf' and location_id is not null and client_code is not null
              and snapshot_date = (select max(snapshot_date) from bi.zt_snapshot)),
  grid as (select p.location_id, p.client_code, months.m, coalesce(mb.v, 0) v from pairs p cross join months
           left join mb on mb.location_id = p.location_id and mb.client_code = p.client_code and mb.m = months.m),
  x as (select g.location_id, g.client_code, g.m, lag(g.v, 1) over w v1, lag(g.v, 2) over w v2, lag(g.v, 3) over w v3
        from grid g window w as (partition by g.location_id, g.client_code order by g.m)),
  y as (select x.*, w0.wd, w1.wd wd1, w2.wd wd2, w3.wd wd3, s0.si si_t, s1.si si1, s2.si si2, s3.si si3
        from x join wd w0 on w0.m = x.m join wd w1 on w1.m = (x.m - interval '1 month')::date join wd w2 on w2.m = (x.m - interval '2 months')::date
          join wd w3 on w3.m = (x.m - interval '3 months')::date
          join si s0 on s0.m = x.m join si s1 on s1.m = (x.m - interval '1 month')::date join si s2 on s2.m = (x.m - interval '2 months')::date join si s3 on s3.m = (x.m - interval '3 months')::date
        where x.m >= date '2024-07-01')
  insert into bi.organic_store(month, location_id, client_code, organic, v1, v2, v3, wd1, wd2, wd3, wd, si_t, si1, si2, si3, computed_at)
  select m, location_id, client_code, round((0.7 * v1 / wd1 / si1 + 0.2 * v2 / wd2 / si2 + 0.1 * v3 / wd3 / si3) * si_t * wd, 1), v1, v2, v3, wd1, wd2, wd3, wd, si_t, si1, si2, si3, now() from y
  on conflict (month, location_id, client_code) do update set organic = excluded.organic, v1 = excluded.v1, v2 = excluded.v2, v3 = excluded.v3, wd1 = excluded.wd1, wd2 = excluded.wd2,
    wd3 = excluded.wd3, wd = excluded.wd, si_t = excluded.si_t, si1 = excluded.si1, si2 = excluded.si2, si3 = excluded.si3, computed_at = now();
  get diagnostics n = row_count;
  insert into bi.refresh_state(name, source_version, refreshed_at, rows, ms) values ('organic', v, now(), n, extract(milliseconds from clock_timestamp() - t0)::int)
  on conflict (name) do update set source_version = excluded.source_version, refreshed_at = excluded.refreshed_at, rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('rows', n, 'version', v, 'ms', extract(milliseconds from clock_timestamp() - t0)::int);
end $fn$;

create or replace function bi.organic_refresh_if_stale() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare v bigint := (select coalesce(max(id), 0) from bi.audit_log);
begin
  if exists (select 1 from bi.refresh_state where name = 'organic' and source_version >= v)
     and exists (select 1 from bi.organic_store where month = (select max(report_month) from bi.zt_snapshot)) then
    return jsonb_build_object('stale', false);
  end if;
  return bi.organic_refresh();
end $fn$;

do $do$
begin
  if not exists (select 1 from cron.job where jobname = 'bi-organic-refresh') then
    perform cron.schedule('bi-organic-refresh', '*/10 * * * *', 'set statement_timeout = ''120s''; select bi.organic_refresh_if_stale()');
  end if;
end $do$;

create or replace function bi.organic_get(p_month date)
returns table(location_id int, client_code text, organic numeric, v1 numeric, v2 numeric, v3 numeric, wd1 int, wd2 int, wd3 int, wd int, si_t numeric, si1 numeric, si2 numeric, si3 numeric)
language sql stable security definer set search_path to 'bi','public' as $fn$
  select s.location_id, s.client_code, s.organic, s.v1, s.v2, s.v3, s.wd1, s.wd2, s.wd3, s.wd, s.si_t, s.si1, s.si2, s.si3 from bi.organic_store s where s.month = date_trunc('month', p_month)::date
$fn$;

do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.api_organic(date,jsonb,text,text)'::regprocedure);
  if position('organic_pairs(m)' in d) > 0 then d := replace(d, 'from bi.organic_pairs(m) o', 'from bi.organic_get(m) o'); execute d; end if;
  d := pg_get_functiondef('bi.api_organic_trend(jsonb,integer)'::regprocedure);
  if position('organic_pairs(ms.m)' in d) > 0 then d := replace(d, 'bi.organic_pairs(ms.m) op', 'bi.organic_get(ms.m) op'); execute d; end if;
end $do$;
