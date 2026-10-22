-- Applied to Supabase project via MCP on 20261022092430
-- independent single-month implementation (used by the acceptance test to check the stored figures); seasonal lookups computed once
create or replace function bi.organic_pairs(p_month date)
returns table (location_id integer, client_code text, organic numeric, v1 numeric, v2 numeric, v3 numeric, wd1 integer, wd2 integer, wd3 integer, wd integer,
               si_t numeric, si1 numeric, si2 numeric, si3 numeric, d1 numeric, d2 numeric, d3 numeric)
language sql stable security definer set search_path to 'bi', 'public' as $function$
  with t as (select date_trunc('month', p_month)::date t),
  mm as materialized (select k, (t.t - make_interval(months => k))::date m,
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
  select array_agg(bi.workdays((m - make_interval(months => k))::date, ((m - make_interval(months => k)) + interval '1 month - 1 day')::date)::numeric order by k),
         array_agg(bi.organic_si((m - make_interval(months => k))::date) order by k)
    into w, s from generate_series(0, 14) k;   -- index i ↔ k = i − 1
  for r in select o.location_id, o.client_code, o.organic from bi.organic_store o where o.month = m order by o.organic desc nulls last limit 3 loop
    select array_agg(coalesce((select sum(mb.cases) from bi.v_month_business mb where mb.location_id = r.location_id and mb.client_code = r.client_code
                                and mb.month = (m - make_interval(months => k))::date), 0)::numeric order by k)
      into v from generate_series(0, 14) k;
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
