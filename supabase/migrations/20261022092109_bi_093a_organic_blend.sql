-- Applied to Supabase project via MCP on 20261022092109
-- bi_093a (22-Oct-2026): organic expectation blends MoM, QoQ and YoY bases (request of 22-Oct 13:30 IST).
-- organic = 0.5 × MoM basis + 0.4 × QoQ basis + 0.1 × YoY basis; without a usable last-year month: 5/9 MoM + 4/9 QoQ.
--   MoM basis = last month's cases per working day, Pan India seasonal effect removed, × this month's seasonal effect × working days
--   QoQ basis = last three months' level (same de-seasonalising) × seasonal × working days × QoQ trend factor
--               (last quarter vs the quarter before, de-seasonalised, bounded 0.5–2 per quarter, applied as its monthly cube root; 1 when the earlier quarter has < 30 cases)
--   YoY basis = last three months' cases per working day × working days × the pair's own pattern for this calendar month last year
--               (same month last year per working day ÷ its five-month neighbourhood, bounded 0.67–1.5; needs ≥ 30 cases that month and ≥ 100 in the neighbourhood)
-- Weights chosen by back-test Dec-2025 → Sep-2026 (each month predicted from earlier months only): Pan India mean error 5.76 % (was 6.69 %),
-- location × client WAPE 21.25 % (was 21.46 %), bias −4.3 % (was −5.6 %). Higher YoY weights were worse (20 %: 5.82 % / 21.49 %; 30 %: 6.08 % / 21.93 %).
alter table bi.organic_store add column if not exists b_mom numeric, add column if not exists b_qoq numeric, add column if not exists b_yoy numeric,
  add column if not exists q_trend numeric, add column if not exists y_shape numeric;
comment on column bi.organic_store.b_mom is 'MoM basis (cases): last month per working day, de-seasonalised, × seasonal effect × working days';
comment on column bi.organic_store.b_qoq is 'QoQ basis (cases): last three months level, de-seasonalised, × seasonal × working days × q_trend';
comment on column bi.organic_store.b_yoy is 'YoY basis (cases): last three months per working day × working days × y_shape; null when no usable month last year';
comment on column bi.organic_store.q_trend is 'Monthly QoQ trend factor = (last quarter ÷ quarter before, de-seasonalised, bounded 0.5–2)^(1/3); 1 when the earlier quarter is under 30 cases';
comment on column bi.organic_store.y_shape is 'Own seasonal pattern: same month last year per working day ÷ its five-month neighbourhood, bounded 0.67–1.5';

create or replace function bi.organic_refresh()
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
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
  grid as (select p.location_id, p.client_code, months.m, coalesce(mb.v, 0) v, wd.wd, si.si from pairs p cross join months join wd on wd.m = months.m join si on si.m = months.m
           left join mb on mb.location_id = p.location_id and mb.client_code = p.client_code and mb.m = months.m),
  x as (select g.location_id, g.client_code, g.m, g.wd, g.si,
               lag(g.v, 1) over w v1, lag(g.v, 2) over w v2, lag(g.v, 3) over w v3, lag(g.v, 4) over w v4, lag(g.v, 5) over w v5, lag(g.v, 6) over w v6,
               lag(g.wd, 1) over w wd1, lag(g.wd, 2) over w wd2, lag(g.wd, 3) over w wd3, lag(g.wd, 4) over w wd4, lag(g.wd, 5) over w wd5, lag(g.wd, 6) over w wd6,
               lag(g.si, 1) over w si1, lag(g.si, 2) over w si2, lag(g.si, 3) over w si3, lag(g.si, 4) over w si4, lag(g.si, 5) over w si5, lag(g.si, 6) over w si6,
               lag(g.v, 12) over w v12, lag(g.wd, 12) over w wd12,
               sum(g.v) over (w rows between 14 preceding and 10 preceding) v10_14, sum(g.wd) over (w rows between 14 preceding and 10 preceding) wd10_14,
               count(*) over (w rows between 14 preceding and 10 preceding) n10_14
        from grid g window w as (partition by g.location_id, g.client_code order by g.m)),
  y as (select x.*,
               x.v1 / x.wd1 / x.si1 * x.si * x.wd b_mom,
               (x.v1 + x.v2 + x.v3) / (x.wd1 * x.si1 + x.wd2 * x.si2 + x.wd3 * x.si3) * x.si * x.wd b_q0,
               case when coalesce(x.v4 + x.v5 + x.v6, 0) >= 30
                    then power(least(greatest(((x.v1 + x.v2 + x.v3) / (x.wd1 * x.si1 + x.wd2 * x.si2 + x.wd3 * x.si3)) / ((x.v4 + x.v5 + x.v6) / (x.wd4 * x.si4 + x.wd5 * x.si5 + x.wd6 * x.si6)), 0.5), 2), 1.0 / 3)
                    else 1 end q_trend,
               case when x.v12 >= 30 and x.n10_14 = 5 and x.v10_14 >= 100 then least(greatest((x.v12 / x.wd12) / (x.v10_14 / x.wd10_14), 0.67), 1.5) end y_shape
        from x where x.m >= date '2024-07-01'),
  z as (select y.*, y.b_q0 * y.q_trend b_qoq, case when y.y_shape is not null then (y.v1 + y.v2 + y.v3) / (y.wd1 + y.wd2 + y.wd3) * y.wd * y.y_shape end b_yoy from y)
  insert into bi.organic_store(month, location_id, client_code, organic, v1, v2, v3, wd1, wd2, wd3, wd, si_t, si1, si2, si3, b_mom, b_qoq, b_yoy, q_trend, y_shape, computed_at)
  select z.m, z.location_id, z.client_code,
         round(case when z.b_yoy is not null then 0.5 * z.b_mom + 0.4 * z.b_qoq + 0.1 * z.b_yoy else (0.5 * z.b_mom + 0.4 * z.b_qoq) / 0.9 end, 1),
         z.v1, z.v2, z.v3, z.wd1, z.wd2, z.wd3, z.wd, z.si, z.si1, z.si2, z.si3,
         round(z.b_mom, 1), round(z.b_qoq, 1), round(z.b_yoy, 1), round(z.q_trend, 4), round(z.y_shape, 4), now()
  from z
  on conflict (month, location_id, client_code) do update set organic = excluded.organic, v1 = excluded.v1, v2 = excluded.v2, v3 = excluded.v3, wd1 = excluded.wd1, wd2 = excluded.wd2,
    wd3 = excluded.wd3, wd = excluded.wd, si_t = excluded.si_t, si1 = excluded.si1, si2 = excluded.si2, si3 = excluded.si3,
    b_mom = excluded.b_mom, b_qoq = excluded.b_qoq, b_yoy = excluded.b_yoy, q_trend = excluded.q_trend, y_shape = excluded.y_shape, computed_at = now()
  -- unchanged rows are not rewritten (keeps the table compact; computed_at = when the row last changed)
  where (organic_store.organic, organic_store.v1, organic_store.v2, organic_store.v3, organic_store.wd, organic_store.si_t, organic_store.b_mom, organic_store.b_qoq, organic_store.b_yoy, organic_store.q_trend, organic_store.y_shape)
        is distinct from (excluded.organic, excluded.v1, excluded.v2, excluded.v3, excluded.wd, excluded.si_t, excluded.b_mom, excluded.b_qoq, excluded.b_yoy, excluded.q_trend, excluded.y_shape);
  get diagnostics n = row_count;
  insert into bi.refresh_state(name, source_version, refreshed_at, rows, ms) values ('organic', v, now(), n, extract(milliseconds from clock_timestamp() - t0)::int)
  on conflict (name) do update set source_version = excluded.source_version, refreshed_at = excluded.refreshed_at, rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('rows_changed', n, 'version', v, 'ms', extract(milliseconds from clock_timestamp() - t0)::int);
end $function$;

-- independent single-month implementation (used by the acceptance test to check the stored figures)
create or replace function bi.organic_pairs(p_month date)
returns table (location_id integer, client_code text, organic numeric, v1 numeric, v2 numeric, v3 numeric, wd1 integer, wd2 integer, wd3 integer, wd integer,
               si_t numeric, si1 numeric, si2 numeric, si3 numeric, d1 numeric, d2 numeric, d3 numeric)
language sql stable security definer set search_path to 'bi', 'public' as $function$
  with t as (select date_trunc('month', p_month)::date t),
  mm as (select k, (t.t - make_interval(months => k))::date m,
                bi.workdays((t.t - make_interval(months => k))::date, ((t.t - make_interval(months => k)) + interval '1 month - 1 day')::date) wd,
                bi.organic_si((t.t - make_interval(months => k))::date) si
         from t, generate_series(0, 14) k),
  hist as (select mb.location_id, mb.client_code, mb.month, sum(mb.cases)::numeric v from bi.v_month_business mb, t
           where mb.month between greatest((t.t - interval '14 months')::date, date '2024-04-01') and (t.t - interval '1 month')::date and mb.location_id is not null group by 1, 2, 3),
  pairs as (select distinct h.location_id, h.client_code from hist h, t where h.month >= (t.t - interval '3 months')::date
            union select z.location_id, z.client_code from bi.zt_row z, t where z.row_type = 'leaf' and z.location_id is not null
              and z.snapshot_date = (select max(snapshot_date) from bi.zt_snapshot where report_month = t.t)),
  pv as (select p.location_id, p.client_code, mm.k, mm.m, mm.wd::numeric wd, mm.si, coalesce(h.v, 0) v
         from pairs p cross join mm left join hist h on h.location_id = p.location_id and h.client_code = p.client_code and h.month = mm.m),
  a as (select location_id, client_code,
               max(v) filter (where k = 1) v1, max(v) filter (where k = 2) v2, max(v) filter (where k = 3) v3,
               max(wd) filter (where k = 0) w0, max(wd) filter (where k = 1) w1, max(wd) filter (where k = 2) w2, max(wd) filter (where k = 3) w3,
               max(si) filter (where k = 0) s0, max(si) filter (where k = 1) s1, max(si) filter (where k = 2) s2, max(si) filter (where k = 3) s3,
               sum(v) filter (where k between 1 and 3) q1, sum(wd * si) filter (where k between 1 and 3) qd1, sum(wd) filter (where k between 1 and 3) qw1,
               sum(v) filter (where k between 4 and 6) q0, sum(wd * si) filter (where k between 4 and 6) qd0,
               max(v) filter (where k = 12) v12, max(wd) filter (where k = 12) w12,
               sum(v) filter (where k between 10 and 14) vn, sum(wd) filter (where k between 10 and 14) wn,
               bool_and(m >= date '2024-04-01') filter (where k between 10 and 14) full_n,
               bool_and(m >= date '2024-04-01') filter (where k between 4 and 6) full_q0
        from pv group by 1, 2),
  b as (select a.*,
               a.v1 / a.w1 / a.s1 * a.s0 * a.w0 bm,
               a.q1 / a.qd1 * a.s0 * a.w0 * (case when a.full_q0 and a.q0 >= 30 then power(least(greatest((a.q1 / a.qd1) / (a.q0 / a.qd0), 0.5), 2), 1.0 / 3) else 1 end) bq,
               case when a.full_n and a.v12 >= 30 and a.vn >= 100 then a.q1 / a.qw1 * a.w0 * least(greatest((a.v12 / a.w12) / (a.vn / a.wn), 0.67), 1.5) end byy
        from a)
  select b.location_id, b.client_code,
         round(case when b.byy is not null then 0.5 * b.bm + 0.4 * b.bq + 0.1 * b.byy else (0.5 * b.bm + 0.4 * b.bq) / 0.9 end, 1),
         b.v1, b.v2, b.v3, b.w1::int, b.w2::int, b.w3::int, b.w0::int, b.s0, b.s1, b.s2, b.s3,
         round(b.v1 / b.w1 / b.s1, 3), round(b.v2 / b.w2 / b.s2, 3), round(b.v3 / b.w3 / b.s3, 3)
  from b
$function$;

create or replace function bi.test_organic()
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare m date := (select max(report_month) from bi.zt_snapshot); s_store numeric; s_fn numeric; j jsonb; jz jsonb; zsum numeric; mtd numeric; ok boolean; ok_pairs boolean := true;
        r record; v numeric[]; w numeric[]; s numeric[]; bm numeric; bq numeric; by_ numeric; q1 numeric; q0 numeric; qtr numeric; shp numeric; exp_ numeric; checks jsonb := '[]';
begin
  perform bi.organic_refresh_if_stale();
  select sum(organic) into s_store from bi.organic_store where month = m;
  select sum(organic) into s_fn from bi.organic_pairs(m);
  -- three largest pairs recomputed one by one from the monthly tracker figures (third, scalar implementation of the documented formula)
  for r in select o.location_id, o.client_code, o.organic from bi.organic_store o where o.month = m order by o.organic desc nulls last limit 3 loop
    select array_agg(coalesce((select sum(mb.cases) from bi.v_month_business mb where mb.location_id = r.location_id and mb.client_code = r.client_code
                                and mb.month = (m - make_interval(months => k))::date), 0)::numeric order by k),
           array_agg(bi.workdays((m - make_interval(months => k))::date, ((m - make_interval(months => k)) + interval '1 month - 1 day')::date)::numeric order by k),
           array_agg(bi.organic_si((m - make_interval(months => k))::date) order by k)
      into v, w, s from generate_series(0, 14) k;   -- index i ↔ k = i − 1
    bm := v[2] / w[2] / s[2] * s[1] * w[1];
    q1 := (v[2] + v[3] + v[4]) / (w[2] * s[2] + w[3] * s[3] + w[4] * s[4]);
    q0 := case when v[5] + v[6] + v[7] >= 30 then (v[5] + v[6] + v[7]) / (w[5] * s[5] + w[6] * s[6] + w[7] * s[7]) end;
    qtr := case when q0 is not null then power(least(greatest(q1 / q0, 0.5), 2), 1.0 / 3) else 1 end;
    bq := q1 * s[1] * w[1] * qtr;
    shp := case when v[13] >= 30 and (v[11] + v[12] + v[13] + v[14] + v[15]) >= 100 and (m - interval '14 months')::date >= date '2024-04-01'
                then least(greatest((v[13] / w[13]) / ((v[11] + v[12] + v[13] + v[14] + v[15]) / (w[11] + w[12] + w[13] + w[14] + w[15])), 0.67), 1.5) end;
    by_ := case when shp is not null then (v[2] + v[3] + v[4]) / (w[2] + w[3] + w[4]) * w[1] * shp end;
    exp_ := case when by_ is not null then 0.5 * bm + 0.4 * bq + 0.1 * by_ else (0.5 * bm + 0.4 * bq) / 0.9 end;
    checks := checks || jsonb_build_object('location_id', r.location_id, 'client', r.client_code, 'store', r.organic, 'recomputed', round(exp_, 1),
                                            'mom', round(bm, 1), 'qoq', round(bq, 1), 'yoy', round(by_, 1), 'qoq_trend', round(qtr, 4), 'yoy_shape', round(shp, 4));
    if abs(round(exp_, 1) - r.organic) > 0.2 then ok_pairs := false; end if;
  end loop;
  j := bi.api_organic(m, '{}', 'total', 'cases'); jz := bi.api_organic(m, '{}', 'zone', 'cases');
  select sum((x->>'organic_month')::numeric) into zsum from jsonb_array_elements(jz->'rows') x;
  select sum(mtd_cases) into mtd from bi.v_zt_leaf where snapshot_date = (select max(snapshot_date) from bi.zt_snapshot where report_month = m);
  ok := abs(s_store - s_fn) / s_fn < 0.001 and ok_pairs
        and abs((j->'total'->>'organic_month')::numeric - s_store) <= 1 and abs(zsum - s_store) <= jsonb_array_length(jz->'rows')
        and (j->'total'->>'actual')::numeric = mtd
        and (j->'total'->>'effort_to_date')::numeric = (j->'total'->>'actual')::numeric - (j->'total'->>'organic_to_date')::numeric;
  return jsonb_build_object('passed', ok, 'month', m, 'store', round(s_store), 'function', round(s_fn), 'pairs_recomputed', checks, 'api_total', j->'total'->'organic_month',
    'zone_rows_sum', round(zsum), 'actual', j->'total'->'actual', 'mtd_check', mtd, 'effort', j->'total'->'effort_to_date');
end $function$;
