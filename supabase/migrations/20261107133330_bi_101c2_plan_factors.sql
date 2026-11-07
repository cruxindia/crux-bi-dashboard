-- Applied to Supabase project via MCP on 20261107133330
-- Wave 101b: month factors computed once per call (bi.organic_si costs ~0.13 s per call; per-row use timed out).
create or replace function bi.plan_factors(p_ref date, p_from date, p_to date) returns table(month date, factor numeric, wd int, si numeric)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  with r as materialized (select x.m, x.r from bi.organic_ratio() x where x.r is not null),
  ms as (select g::date as mm from generate_series(least(p_ref, p_from), p_to, interval '1 month') g),
  s as materialized (select ms.mm, coalesce(round((select avg(r.r) from r where r.m in ((ms.mm - interval '12 months')::date, (ms.mm - interval '24 months')::date)), 4), 1) si,
               bi.workdays(ms.mm, (ms.mm + interval '1 month' - interval '1 day')::date) wd from ms)
  select s.mm, (s.wd * s.si) / nullif((select s0.wd * s0.si from s s0 where s0.mm = p_ref), 0), s.wd, s.si from s where s.mm >= p_from $f$;
revoke all on function bi.plan_factors(date, date, date) from public, anon, authenticated;

create or replace function bi.plan_compute(p jsonb default '{}'::jsonb)
returns table(k int, month date, factor numeric, zone_group text, location_id int, client_family text, pace numeric, organic numeric, target numeric)
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare v_h int := least(greatest(coalesce((p->>'horizon')::int, 12), 1), 24);
        v_c numeric := least(greatest(coalesce((p->>'capture')::numeric, 0.30), 0), 1);
        v_gmin numeric := coalesce((p->>'gmin')::numeric, 0.02); v_gmax numeric := coalesce((p->>'gmax')::numeric, 0.12);
        v_basis text := coalesce(nullif(p->>'basis', ''), 'seasonal');
        v_ref date := (select r.month from bi.potential_run r order by r.run_id desc limit 1);
        v_pace0 numeric; v_opp numeric; a_prev numeric; t_prev numeric; a numeric; t numeric; i int; cc numeric[] := '{}'; fs numeric[];
begin
  if v_gmax < v_gmin then v_gmax := v_gmin; end if;
  select array_agg(pf.factor order by pf.month) into fs from bi.plan_factors(v_ref, (v_ref + interval '1 month')::date, (v_ref + make_interval(months => v_h))::date) pf;
  select sum(x.pace0), sum(greatest(x.organic - x.pace0, 0)) into v_pace0, v_opp from bi.plan_cells() x;
  a_prev := v_pace0; t_prev := v_pace0;
  for i in 1 .. v_h loop
    a := v_pace0 + v_c * i::numeric / v_h * v_opp;
    if v_basis = 'nominal' then
      t := least(greatest(a * fs[i], t_prev * (1 + v_gmin)), t_prev * (1 + v_gmax)); a := t / fs[i];
    else
      a := least(greatest(a, a_prev * (1 + v_gmin)), a_prev * (1 + v_gmax)); t := a * fs[i];
    end if;
    cc := cc || ((a - v_pace0) / nullif(v_opp, 0));
    a_prev := a; t_prev := t;
  end loop;
  return query
    select g.i, (v_ref + make_interval(months => g.i))::date, fs[g.i], x.zone_group, x.location_id, x.client_family,
           x.pace0 * fs[g.i], x.organic * fs[g.i],
           (x.pace0 + coalesce(cc[g.i], 0) * greatest(x.organic - x.pace0, 0)) * fs[g.i]
      from generate_series(1, v_h) g(i) cross join bi.plan_cells() x;
end $f$;

do $m$
declare d text := pg_get_functiondef('bi.api_targets(date, jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, 'pt.month, bi.plan_month_factor(v_ref, pt.month),', 'pt.month, null::numeric,');
  if d = o then raise exception 'api_targets edit not applied'; end if;
  execute d;
end $m$;
