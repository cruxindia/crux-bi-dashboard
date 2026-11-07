-- Applied to Supabase project via MCP on 20261107172630
-- wave 102b (7-Nov-2026, owner): a month's target is never below the previous month's target (+ minimum growth), the first month
-- starting from the reference month's tracker target; the only exception is a month that fell 5% or more against the month before
-- in every year on record (strong seasonal signal), which may fall by at most the smallest fall on record.
create or replace function bi.plan_signals(p_from date, p_to date)
returns table(month date, strong boolean, allowed_drop numeric, falls jsonb)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  -- complete months only (the latest tracker month is still running), PAN India expected revenue
  with dm as (select max(v.month) m from bi.v_month_business v where coalesce(v.revenue, 0) > 0),
  h as (select v.month, sum(v.revenue) rev from bi.v_month_business v where v.month < (select m from dm) group by 1),
  ch as (select extract(month from h.month)::int mm, extract(year from h.month)::int yy, h.rev / nullif(p.rev, 0) - 1 chg
           from h join h p on p.month = (h.month - interval '1 month')::date),
  agg as (select mm, count(*) n, bool_and(chg <= -0.05) all_fell, min(abs(chg)) smallest,
                 jsonb_agg(jsonb_build_object('year', yy, 'change', round(chg, 4)) order by yy) falls
            from ch group by mm)
  select g::date, coalesce(a.n >= 2 and a.all_fell, false), case when a.n >= 2 and a.all_fell then round(a.smallest, 4) else 0 end, a.falls
    from generate_series(date_trunc('month', p_from)::date, date_trunc('month', p_to)::date, interval '1 month') g
    left join agg a on a.mm = extract(month from g)::int
$f$;

create or replace function bi.plan_cells2()
returns table(zone_group text, location_id integer, client_family text, pace0 numeric, organic numeric, t0 numeric)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  -- cells of the latest potential run plus team x client pairs with a tracker target in the reference month;
  -- t0 = the reference month's tracker revenue target, never below the pair's current (projected) business
  with run as (select r.run_id, r.month, r.inputs from bi.potential_run r order by r.run_id desc limit 1),
  pc as (select c.zone_group, c.location_id, c.client_family, coalesce(sum(c.revenue) filter (where c.layer = 'current'), 0) pace0, coalesce(sum(c.revenue), 0) organic
           from bi.potential_cell c where c.run_id = (select run_id from run) group by 1, 2, 3),
  tg as (select v.location_id, coalesce(cl.family, v.client_code) client_family, sum(coalesce(v.revenue_target, 0)) t
           from bi.v_month_business v left join bi.client cl on cl.code = v.client_code
          where v.month = (select month from run) and v.location_id is not null
            and coalesce(cl.family, v.client_code) not in (select jsonb_array_elements_text(coalesce((select inputs->'inactive_clients' from run), '[]'::jsonb)))
          group by 1, 2 having sum(coalesce(v.revenue_target, 0)) > 0)
  select coalesce(pc.zone_group, l.zone_group), coalesce(pc.location_id, tg.location_id), coalesce(pc.client_family, tg.client_family),
         coalesce(pc.pace0, 0), greatest(coalesce(pc.organic, 0), coalesce(pc.pace0, 0)), greatest(coalesce(tg.t, 0), coalesce(pc.pace0, 0))
    from pc full join tg on tg.location_id = pc.location_id and tg.client_family = pc.client_family
    left join bi.location l on l.id = coalesce(pc.location_id, tg.location_id)
$f$;

create or replace function bi.plan_compute(p jsonb default '{}'::jsonb)
returns table(k integer, month date, factor numeric, zone_group text, location_id integer, client_family text, pace numeric, organic numeric, target numeric)
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
#variable_conflict use_column
declare v_h int := least(greatest(coalesce((p->>'horizon')::int, 12), 1), 24);
        v_c numeric := least(greatest(coalesce((p->>'capture')::numeric, 0.30), 0), 1);
        v_gmin numeric := coalesce((p->>'gmin')::numeric, 0.02); v_gmax numeric := coalesce((p->>'gmax')::numeric, 0.12);
        v_ref date := (select r.month from bi.potential_run r order by r.run_id desc limit 1);
        v_pace0 numeric; v_opp numeric; a_prev numeric; a numeric; i int; cc numeric[] := '{}'; fs numeric[]; dr numeric[]; sg boolean[];
begin
  -- 1. the capture path on the seasonally adjusted level (PAN India): pace + c x opportunity, growth between gmin and gmax a month
  -- 2. per team x client: seasonal target = (pace + c_k x opportunity) x month factor, but never below the previous month's
  --    target x (1 + gmin) (month 1: the reference month's tracker target), except a strong-signal month (plan_signals)
  if v_gmax < v_gmin then v_gmax := v_gmin; end if;
  select array_agg(pf.factor order by pf.month) into fs from bi.plan_factors(v_ref, (v_ref + interval '1 month')::date, (v_ref + make_interval(months => v_h))::date) pf;
  select array_agg(s.allowed_drop order by s.month), array_agg(s.strong order by s.month) into dr, sg
    from bi.plan_signals((v_ref + interval '1 month')::date, (v_ref + make_interval(months => v_h))::date) s;
  select sum(x.pace0), sum(greatest(x.organic - x.pace0, 0)) into v_pace0, v_opp from bi.plan_cells2() x;
  a_prev := v_pace0;
  for i in 1 .. v_h loop
    a := least(greatest(v_pace0 + v_c * i::numeric / v_h * v_opp, a_prev * (1 + v_gmin)), a_prev * (1 + v_gmax));
    cc := cc || ((a - v_pace0) / nullif(v_opp, 0));
    a_prev := a;
  end loop;
  return query
  with recursive c as (select * from bi.plan_cells2()),
  r as (
    select 1 as i, c.zone_group zg, c.location_id lid, c.client_family fam, c.pace0 p0, c.organic org,
           greatest((c.pace0 + coalesce(cc[1], 0) * greatest(c.organic - c.pace0, 0)) * fs[1],
                    c.t0 * case when sg[1] then 1 - dr[1] else 1 + v_gmin end) t
      from c
    union all
    select r.i + 1, r.zg, r.lid, r.fam, r.p0, r.org,
           greatest((r.p0 + coalesce(cc[r.i + 1], 0) * greatest(r.org - r.p0, 0)) * fs[r.i + 1],
                    r.t * case when sg[r.i + 1] then 1 - dr[r.i + 1] else 1 + v_gmin end)
      from r where r.i < v_h)
  select r.i, (v_ref + make_interval(months => r.i))::date, fs[r.i], r.zg, r.lid, r.fam, r.p0 * fs[r.i], r.org * fs[r.i], r.t from r;
end $f$;

revoke all on function bi.plan_signals(date, date), bi.plan_cells2() from public, anon, authenticated;
