-- Applied to Supabase project via MCP on 20261107182530
-- wave 102k (7-Nov-2026, owner review of the November sheet): targets grounded in what each team x client actually does.
-- Capacity = best of last month / last 3 months average / BAU; ceiling = capacity x (1 + cap, default 50%). The previous target is a floor
-- only up to the ceiling; a pair with no business keeps its previous target unchanged; a pair with no business and no previous target gets
-- no target; cases use the row's own rate.
create or replace function bi.plan_cells3()
returns table(zone_group text, location_id integer, client_family text, pace0 numeric, organic numeric, t0 numeric, l3 numeric, cap numeric)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  -- plan_cells2 + the last 3 complete months average revenue and capacity = max(current pace, last 3 months average); roll-up locations left out
  with run as (select r.month from bi.potential_run r order by r.run_id desc limit 1),
  h as (select v.location_id, coalesce(cl.family, v.client_code) fam, sum(coalesce(v.revenue, 0)) / 3.0 l3
          from bi.v_month_business v left join bi.client cl on cl.code = v.client_code
         where v.location_id is not null and v.month between ((select month from run) - interval '3 months')::date and ((select month from run) - interval '1 month')::date
         group by 1, 2)
  select c2.zone_group, c2.location_id, c2.client_family, c2.pace0, c2.organic, c2.t0, coalesce(h.l3, 0), greatest(c2.pace0, coalesce(h.l3, 0))
    from bi.plan_cells2() c2 left join h on h.location_id = c2.location_id and h.fam = c2.client_family
    left join bi.location l on l.id = c2.location_id
   where c2.location_id is null or not coalesce(l.is_rollup, false)
$f$;

create or replace function bi.plan_compute(p jsonb default '{}'::jsonb)
returns table(k integer, month date, factor numeric, zone_group text, location_id integer, client_family text, pace numeric, organic numeric, target numeric)
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
#variable_conflict use_column
declare v_h int := least(greatest(coalesce((p->>'horizon')::int, 12), 1), 24);
        v_c numeric := least(greatest(coalesce((p->>'capture')::numeric, 0.30), 0), 1);
        v_gmin numeric := coalesce((p->>'gmin')::numeric, 0.02); v_gmax numeric := coalesce((p->>'gmax')::numeric, 0.12);
        v_cap numeric := greatest(coalesce((p->>'cap')::numeric, 0.5), 0);
        v_ref date := (select r.month from bi.potential_run r order by r.run_id desc limit 1);
        v_pace0 numeric; v_opp numeric; a_prev numeric; a numeric; i int; cc numeric[] := '{}'; fs numeric[]; dr numeric[]; sg boolean[];
begin
  -- 1. capture path on the seasonally adjusted level (PAN India), growth between gmin and gmax a month
  -- 2. per team x client: seasonal value = (pace + c_k x opportunity) x factor_k; floor = previous target x (1 + gmin) (month 1: the
  --    reference tracker target), strong-signal months excepted; both limited by the ceiling = capacity x (1 + cap) x factor_1 in month 1,
  --    then x (1 + gmax) x factor_k / factor_(k-1) a month. No capacity: previous target kept flat; no capacity and no target: 0.
  if v_gmax < v_gmin then v_gmax := v_gmin; end if;
  select array_agg(pf.factor order by pf.month) into fs from bi.plan_factors(v_ref, (v_ref + interval '1 month')::date, (v_ref + make_interval(months => v_h))::date) pf;
  select array_agg(s.allowed_drop order by s.month), array_agg(s.strong order by s.month) into dr, sg
    from bi.plan_signals((v_ref + interval '1 month')::date, (v_ref + make_interval(months => v_h))::date) s;
  select sum(x.pace0), sum(greatest(x.organic - x.pace0, 0)) into v_pace0, v_opp from bi.plan_cells3() x;
  a_prev := v_pace0;
  for i in 1 .. v_h loop
    a := least(greatest(v_pace0 + v_c * i::numeric / v_h * v_opp, a_prev * (1 + v_gmin)), a_prev * (1 + v_gmax));
    cc := cc || ((a - v_pace0) / nullif(v_opp, 0));
    a_prev := a;
  end loop;
  return query
  with recursive c as (select * from bi.plan_cells3()),
  r as (
    select 1 as i, c.zone_group zg, c.location_id lid, c.client_family fam, c.pace0 p0, c.organic org, c.cap capc,
           c.cap * (1 + v_cap) * fs[1] u,
           case when c.cap <= 0 then c.t0
                else least(c.cap * (1 + v_cap) * fs[1],
                           greatest((c.pace0 + coalesce(cc[1], 0) * greatest(c.organic - c.pace0, 0)) * fs[1],
                                    c.t0 * case when sg[1] then 1 - dr[1] else 1 + v_gmin end)) end t
      from c
    union all
    select r.i + 1, r.zg, r.lid, r.fam, r.p0, r.org, r.capc,
           r.u * (1 + v_gmax) * fs[r.i + 1] / fs[r.i],
           case when r.capc <= 0 then r.t
                else least(r.u * (1 + v_gmax) * fs[r.i + 1] / fs[r.i],
                           greatest((r.p0 + coalesce(cc[r.i + 1], 0) * greatest(r.org - r.p0, 0)) * fs[r.i + 1],
                                    r.t * case when sg[r.i + 1] then 1 - dr[r.i + 1] else 1 + v_gmin end)) end
      from r where r.i < v_h)
  select r.i, (v_ref + make_interval(months => r.i))::date, fs[r.i], r.zg, r.lid, r.fam, r.p0 * fs[r.i], r.org * fs[r.i], r.t from r;
end $f$;
revoke all on function bi.plan_cells3() from public, anon, authenticated;

create or replace function bi.api_target_sheet(p_month date, f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
-- One row per team (location) x client code for target month M:
--   last month (M-1) = actual if complete, expected closure (actual so far / usual share of the month) if running, pace forecast if not started;
--   last 3 complete months average; BAU (organic) for M; potential for M; previous month's target; plan for M
--   (saved plan, else suggested target); quarter catch-up = the quarter's shortfall so far (plan - actual/outlook of its earlier months),
--   shared over the quarter's remaining months by plan.
-- wave 102k (owner review of the Nov sheet): capacity C = max(last month, last 3 months average, BAU); ceiling U = C x (1 + cap).
-- Target = base + catch-up; base = max(min(plan, U), min(previous target x (1+gmin) [strong-signal month: x (1 - allowed fall)], U),
--   last month x (1+gmin), BAU x (1+gmin)); catch-up added only up to min(U, potential).
-- No business in 3 months but a previous target: the previous target is kept, unchanged. No business and no previous target: no target
--   (listed under opportunities). Cases use the row's own rate: actual, else its tracker target rate, else the code's rate elsewhere, else the family's.
declare v_l date; v_share numeric; v_asof date; v_m date := date_trunc('month', p_month)::date; v_p date; v_q0 date; v_qend date;
        v_first_inc date; v_c1 date; v_c3 date; v_basis text; v_gmin numeric := coalesce((p->>'gmin')::numeric, 0.02);
        v_cu numeric := least(greatest(coalesce((p->>'catchup')::numeric, 1), 0), 1); v_cap numeric := greatest(coalesce((p->>'cap_over_last')::numeric, 0.5), 0);
        v_sig boolean; v_drop numeric; v_ver bigint; v_inact text[]; v_fm numeric; v_fl1 numeric; v_lo date; r jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  select x.month, coalesce((x.inputs->>'share_to_date')::numeric, 1), x.as_of, array(select jsonb_array_elements_text(coalesce(x.inputs->'inactive_clients', '[]'::jsonb)))
    into v_l, v_share, v_asof, v_inact from bi.potential_run x order by x.run_id desc limit 1;
  if v_m is null or v_m <= v_l or v_m > (v_l + interval '12 months')::date then
    return jsonb_build_object('error', format('Choose a target month from %s to %s (the latest tracker month is %s).', to_char(v_l + interval '1 month', 'Mon-YY'), to_char(v_l + interval '12 months', 'Mon-YY'), to_char(v_l, 'Mon-YY')));
  end if;
  v_p := (v_m - interval '1 month')::date;
  v_first_inc := case when v_share < 1 then v_l else (v_l + interval '1 month')::date end;
  v_c3 := (v_first_inc - interval '1 month')::date; v_c1 := (v_first_inc - interval '3 months')::date;
  v_q0 := (date_trunc('quarter', v_m - interval '3 months') + interval '3 months')::date; v_qend := (v_q0 + interval '2 months')::date;
  v_lo := least(v_c1, v_q0, v_p);
  v_basis := case when v_p < v_l then 'actual' when v_p = v_l then case when v_share < 1 then 'expected closure' else 'actual' end else 'forecast at current pace' end;
  select s.strong, s.allowed_drop into v_sig, v_drop from bi.plan_signals(v_m, v_m) s;
  select id into v_ver from bi.plan_version order by id desc limit 1;
  select pf.factor into v_fm from bi.plan_factors(v_l, v_m, v_m) pf;
  select pf.factor into v_fl1 from bi.plan_factors(v_l, (v_l + interval '1 month')::date, (v_l + interval '1 month')::date) pf;

  with
  fac as materialized (select pf.month, pf.factor from bi.plan_factors(v_l, (v_l + interval '1 month')::date, greatest(v_qend, v_m)) pf),
  vb as materialized (
    select v.month, v.location_id, v.client_code, coalesce(c.family, v.client_code) fam, sum(coalesce(v.cases, 0)) cases, sum(coalesce(v.revenue, 0)) rev,
           sum(coalesce(v.target_cases, 0)) tc, sum(coalesce(v.revenue_target, 0)) tr
      from bi.v_month_business v left join bi.client c on c.code = v.client_code
     where v.location_id is not null and v.month between v_lo and v_l
       and coalesce(c.family, v.client_code) <> all (v_inact)
       and bi.loc_ok(v.location_id, null, f) and (f->>'client_family' is null or coalesce(c.family, v.client_code) = f->>'client_family')
     group by 1, 2, 3, 4),
  sg as materialized (select c.month, c.location_id, c.client_family fam, sum(c.target) t from bi.plan_compute('{}'::jsonb) c
                       where c.location_id is not null and (c.month between v_q0 and v_qend or c.month in (v_m, v_p)) group by 1, 2, 3),
  sv as materialized (select pt.month, pt.location_id, pt.client_family fam, sum(pt.target) t from bi.plan_target pt
                       where pt.version_id = v_ver and pt.location_id is not null and (pt.month between v_q0 and v_qend or pt.month in (v_m, v_p)) group by 1, 2, 3),
  codes as materialized (select distinct vb.location_id, vb.client_code, vb.fam from vb join bi.location lr on lr.id = vb.location_id
                          where not coalesce(lr.is_rollup, false) and ((vb.month between v_c1 and v_l and vb.cases > 0) or (vb.month in (v_l, v_p) and vb.tc > 0))),
  fcell as materialized (
    select x.location_id, x.fam from (
      select location_id, fam from codes
      union select s.location_id, s.fam from sg s where s.month = v_m and s.t > 0
      union select s.location_id, s.fam from sv s where s.month = v_m and s.t > 0) x
     where x.fam <> all (v_inact) and bi.loc_ok(x.location_id, null, f) and (f->>'client_family' is null or x.fam = f->>'client_family')
       and not coalesce((select lr.is_rollup from bi.location lr where lr.id = x.location_id), false)),
  -- code rows (plan-only cells get one row under the family name)
  crow as materialized (select location_id, client_code, fam from codes
                         union select c.location_id, c.fam, c.fam from fcell c where not exists (select 1 from codes k where k.location_id = c.location_id and k.fam = c.fam)),
  cstat as materialized (
    select cr.location_id, cr.client_code, cr.fam,
           coalesce(sum(vb.rev) filter (where vb.month between v_c1 and v_c3), 0) / 3.0 r3, coalesce(sum(vb.cases) filter (where vb.month between v_c1 and v_c3), 0) / 3.0 c3,
           coalesce(sum(vb.rev) filter (where vb.month = v_l), 0) rl, coalesce(sum(vb.cases) filter (where vb.month = v_l), 0) cl,
           coalesce(sum(vb.rev) filter (where vb.month = v_p), 0) rp, coalesce(sum(vb.cases) filter (where vb.month = v_p), 0) cp,
           sum(vb.tr) filter (where vb.month = v_p) trp, sum(vb.tc) filter (where vb.month = v_p) tcp,
           coalesce(sum(vb.tr) filter (where vb.month = v_l), 0) trl,
           sum(vb.rev) filter (where vb.month between v_c1 and v_l and vb.cases > 0) / nullif(sum(vb.cases) filter (where vb.month between v_c1 and v_l and vb.cases > 0), 0) rate
      from crow cr left join vb on vb.location_id = cr.location_id and vb.client_code = cr.client_code
     group by 1, 2, 3),
  frate as (select fam, sum(rev) / nullif(sum(cases), 0) r from vb where month between v_c1 and v_l and cases > 0 group by 1),
  -- the code's tracker target rate (target revenue / target cases, latest month with a target) and the code's own rate elsewhere in India
  trate as (select distinct on (location_id, client_code) location_id, client_code, tr / nullif(tc, 0) r from vb where tc > 0 and tr > 0 order by location_id, client_code, month desc),
  crate as (select v.client_code, sum(v.revenue) / nullif(sum(v.cases), 0) r from bi.v_month_business v
             where v.month between v_c1 and v_l and v.cases > 0 group by 1),
  -- weight of each code inside its team x family (last 3 months revenue, else last tracker target, else equal)
  w as materialized (select s.*, coalesce(s.r3 / nullif(sum(s.r3) over (partition by s.location_id, s.fam), 0),
                                         s.trl / nullif(sum(s.trl) over (partition by s.location_id, s.fam), 0),
                                         1.0 / count(*) over (partition by s.location_id, s.fam)) wt
                       from cstat s),
  -- team x family monthly plan and outlook for the quarter (and the previous month)
  fm as (select g::date as month from generate_series(least(v_q0, v_p), greatest(v_qend, v_m), interval '1 month') g),
  fact as materialized (select location_id, fam, month, sum(rev) rev, sum(tr) tr from vb group by 1, 2, 3),
  fpace as materialized (select location_id, fam, sum(rev) / case when v_share < 1 then v_share else 1 end p0 from vb where month = v_l group by 1, 2),
  fplan as materialized (
    select c.location_id, c.fam, m.month,
           coalesce(svv.t, case when m.month <= v_l then nullif(a.tr, 0) end, sgg.t, 0) plan,
           case when m.month < v_l then coalesce(a.rev, 0) when m.month = v_l then coalesce(a.rev, 0) / v_share else coalesce(fp.p0, 0) * coalesce(fc.factor, 1) end outlook
      from fcell c cross join fm m
      left join sv svv on svv.location_id = c.location_id and svv.fam = c.fam and svv.month = m.month
      left join sg sgg on sgg.location_id = c.location_id and sgg.fam = c.fam and sgg.month = m.month
      left join fact a on a.location_id = c.location_id and a.fam = c.fam and a.month = m.month
      left join fpace fp on fp.location_id = c.location_id and fp.fam = c.fam
      left join fac fc on fc.month = m.month),
  fq as materialized (
    select location_id, fam,
           max(plan) filter (where month = v_m) plan_m, max(plan) filter (where month = v_p) plan_p,
           coalesce(sum(plan - outlook) filter (where month >= v_q0 and month < v_m), 0) sf,
           sum(plan) filter (where month >= v_m and month <= v_qend) rem
      from fplan group by 1, 2),
  -- BAU (organic) cases for M: next month directly; later months carried from next month by working days and seasonality
  bau as materialized (select o.location_id, o.client_code, o.organic * coalesce(v_fm / nullif(v_fl1, 0), 1) bc
                         from bi.organic_pairs((v_l + interval '1 month')::date) o),
  pot as materialized (select pc.location_id, pc.client_family fam, sum(pc.revenue) * coalesce(v_fm, 1) pr, sum(pc.cases) * coalesce(v_fm, 1) pcs
                         from bi.potential_cell pc where pc.run_id = (select max(run_id) from bi.potential_run) and pc.location_id is not null group by 1, 2),
  rows0 as (
    select w.location_id, l.label location, l.zone_group, w.fam, w.client_code, coalesce(cl.label, w.client_code) client,
           coalesce(w.rate, tra.r, cra.r, fr.r) rate, case when w.rate is not null then 'actual' when tra.r is not null then 'tracker target' when cra.r is not null then 'code elsewhere' else 'client family' end rate_src, w.wt,
           -- last month (M-1)
           case when v_p < v_l then w.cp when v_p = v_l then w.cl / v_share else w.cl / v_share * coalesce((select factor from fac where month = v_p), 1) end lm_cases,
           case when v_p < v_l then w.rp when v_p = v_l then w.rl / v_share else w.rl / v_share * coalesce((select factor from fac where month = v_p), 1) end lm_rev,
           w.c3 l3_cases, w.r3 l3_rev,
           coalesce(b.bc, 0) bau_cases, coalesce(b.bc, 0) * coalesce(w.rate, tra.r, cra.r, fr.r, 0) bau_rev,
           coalesce(pt.pcs, 0) * w.wt pot_cases, coalesce(pt.pr, 0) * w.wt pot_rev,
           case when v_p <= v_l and w.trp is not null and w.trp > 0 and svp.t is null then w.trp else coalesce(q.plan_p, 0) * w.wt end prev_rev,
           case when v_p <= v_l and w.tcp is not null and w.tcp > 0 and svp.t is null then w.tcp end prev_cases_tracker,
           coalesce(q.plan_m, 0) * w.wt plan_rev,
           greatest(q.sf, 0) * coalesce(q.plan_m / nullif(q.rem, 0), 1) * w.wt cu_rev
      from w left join bi.location l on l.id = w.location_id left join bi.client cl on cl.code = w.client_code
      left join frate fr on fr.fam = w.fam
      left join trate tra on tra.location_id = w.location_id and tra.client_code = w.client_code
      left join crate cra on cra.client_code = w.client_code
      left join bau b on b.location_id = w.location_id and b.client_code = w.client_code
      left join pot pt on pt.location_id = w.location_id and pt.fam = w.fam
      left join fq q on q.location_id = w.location_id and q.fam = w.fam
      left join sv svp on svp.location_id = w.location_id and svp.fam = w.fam and svp.month = v_p),
  rows1 as (
    select r0.*, greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) cap0,
           greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) * (1 + v_cap) u,
           r0.prev_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end pfl
      from rows0 r0),
  rows1b as (
    select r1.*,
           case when r1.cap0 <= 0 then coalesce(r1.prev_rev, 0)
                else greatest(least(r1.plan_rev, r1.u), least(r1.pfl, r1.u), r1.lm_rev * (1 + v_gmin), r1.bau_rev * (1 + v_gmin)) end base_rev,
           case when r1.cap0 <= 0 then coalesce(r1.prev_rev, 0) else least(r1.plan_rev, r1.u) end plan_c
      from rows1 r1),
  rows2 as (
    select r1.*,
           r1.base_rev + case when r1.cap0 > 0 then least(r1.cu_rev * v_cu, greatest(least(r1.u, case when r1.pot_rev > 0 then greatest(r1.pot_rev, r1.base_rev) else r1.u end) - r1.base_rev, 0)) else 0 end tgt_rev,
           case when r1.cap0 <= 0 then 'no business in 3 months: previous target kept, no increase'
                when r1.base_rev = least(r1.plan_rev, r1.u) then case when r1.plan_rev > r1.u then 'plan, capped at ' || round((1 + v_cap) * 100) || '% of what the team does' else 'plan' end
                when r1.base_rev = least(r1.pfl, r1.u) then case when r1.pfl > r1.u then 'previous target capped at ' || round((1 + v_cap) * 100) || '% of what the team does' when v_sig then 'previous target less the allowed seasonal fall' else 'previous month''s target + ' || round(v_gmin * 100, 1) || '%' end
                when r1.base_rev = r1.lm_rev * (1 + v_gmin) then 'last month + ' || round(v_gmin * 100, 1) || '%'
                else 'BAU + ' || round(v_gmin * 100, 1) || '%' end base_rule
      from rows1b r1),
  rows3 as (
    select r2.*, case when r2.cap0 <= 0 and r2.prev_cases_tracker is not null then r2.prev_cases_tracker else ceil(r2.tgt_rev / nullif(r2.rate, 0)) end tgt_cases,
           concat_ws('; ', 'base: ' || r2.base_rule,
             case when r2.cu_rev > 0 and r2.tgt_rev > r2.base_rev + 1 then 'quarter catch-up ' || bi.fmt_inr(r2.tgt_rev - r2.base_rev) end,
             case when r2.cap0 > 0 and r2.cu_rev * v_cu > r2.tgt_rev - r2.base_rev + 1 then 'rest of the catch-up stopped at the ceiling' end,
             case when v_sig then 'strong seasonal signal for ' || to_char(v_m, 'Mon') end,
             case when r2.rate_src <> 'actual' then 'cases at the ' || r2.rate_src || ' rate' end,
             case when r2.rate is null then 'no rate: cases not computed' end) note
      from rows2 r2 where r2.cap0 > 0 or coalesce(r2.prev_rev, 0) > 0),
  opp as (select r2.* from rows2 r2 where r2.cap0 <= 0 and coalesce(r2.prev_rev, 0) <= 0 and (r2.plan_rev > 0 or r2.pot_rev > 0))
  select jsonb_build_object(
    'month', v_m, 'previous_month', v_p, 'previous_basis', v_basis, 'data_month', v_l, 'data_as_of', v_asof, 'share_to_date', v_share,
    'last3', jsonb_build_array(v_c1, (v_c1 + interval '1 month')::date, v_c3), 'quarter_from', v_q0, 'quarter_to', v_qend,
    'quarter_label', 'Q' || (case when extract(month from v_q0) between 4 and 6 then 1 when extract(month from v_q0) between 7 and 9 then 2 when extract(month from v_q0) between 10 and 12 then 3 else 4 end)
                     || ' FY' || to_char(case when extract(month from v_q0) >= 4 then v_q0 + interval '1 year' else v_q0 end, 'YY'),
    'plan_version', v_ver, 'strong_signal', coalesce(v_sig, false), 'allowed_drop', v_drop, 'excluded_clients', to_jsonb(v_inact),
    'params', jsonb_build_object('gmin', v_gmin, 'catchup', v_cu, 'cap_over_last', v_cap),
    'quarter', (select jsonb_build_object('plan_before', round(sum(plan) filter (where month >= v_q0 and month < v_m)), 'outlook_before', round(sum(outlook) filter (where month >= v_q0 and month < v_m)),
                       'shortfall_before', round(sum(plan - outlook) filter (where month >= v_q0 and month < v_m)), 'plan_rest', round(sum(plan) filter (where month >= v_m and month <= v_qend)))
                  from fplan),
    'totals', (select jsonb_build_object('rows', count(*), 'lm_cases', round(sum(lm_cases)), 'lm_rev', round(sum(lm_rev)), 'l3_cases', round(sum(l3_cases)), 'l3_rev', round(sum(l3_rev)),
                       'bau_cases', round(sum(bau_cases)), 'bau_rev', round(sum(bau_rev)), 'pot_cases', round(sum(pot_cases)), 'pot_rev', round(sum(pot_rev)),
                       'prev_rev', round(sum(prev_rev)), 'plan_rev', round(sum(plan_rev)), 'base_rev', round(sum(base_rev)), 'catchup_rev', round(sum(tgt_rev - base_rev)), 'cu_wanted', round(sum(cu_rev)),
                       'tgt_rev', round(sum(tgt_rev)), 'tgt_cases', sum(tgt_cases), 'cap_rev', round(sum(u)), 'plan_uncapped', round(sum(plan_rev)), 'plan_capped', round(sum(plan_c)),
                       'dormant_rows', count(*) filter (where cap0 <= 0), 'capped_rows', count(*) filter (where cap0 > 0 and (plan_rev > u or pfl > u))) from rows3),
    'opportunities', (select jsonb_build_object('rows', count(*), 'pot_rev', round(sum(pot_rev)), 'plan_rev', round(sum(plan_rev)),
                       'list', coalesce(jsonb_agg(jsonb_build_object('zone_group', zone_group, 'location', location, 'client', client, 'client_family', fam, 'pot_rev', round(pot_rev), 'pot_cases', round(pot_cases)) order by pot_rev desc) filter (where pot_rev > 0), '[]'::jsonb)) from opp),
    'bridge', (select jsonb_build_array(
                  jsonb_build_object('label', 'Last month (' || v_basis || ')', 'value', round(sum(lm_rev)), 'kind', 'total'),
                  jsonb_build_object('label', 'BAU change', 'value', round(sum(bau_rev - lm_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Plan above BAU (capped)', 'value', round(sum(plan_c - bau_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Floors (previous target / last month / BAU + ' || round(v_gmin * 100, 1) || '%)', 'value', round(sum(base_rev - plan_c)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Quarter catch-up', 'value', round(sum(tgt_rev - base_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Target ' || to_char(v_m, 'Mon-YY'), 'value', round(sum(tgt_rev)), 'kind', 'total')) from rows3),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', zone_group, 'location_id', location_id, 'location', coalesce(location, 'No team yet'), 'client_code', client_code, 'client', client, 'client_family', fam,
                  'rate', round(rate, 1), 'rate_source', rate_src, 'cap_rev', round(u), 'lm_cases', round(lm_cases), 'lm_rev', round(lm_rev), 'l3_cases', round(l3_cases, 1), 'l3_rev', round(l3_rev),
                  'bau_cases', round(bau_cases), 'bau_rev', round(bau_rev), 'pot_cases', round(pot_cases), 'pot_rev', round(pot_rev),
                  'prev_rev', round(prev_rev), 'prev_cases', coalesce(prev_cases_tracker, ceil(prev_rev / nullif(rate, 0))), 'plan_rev', round(plan_rev), 'base_rev', round(base_rev),
                  'catchup_rev', round(tgt_rev - base_rev), 'tgt_rev', round(tgt_rev), 'tgt_cases', tgt_cases,
                  'vs_last', round(tgt_rev / nullif(lm_rev, 0) - 1, 4), 'vs_l3', round(tgt_rev / nullif(l3_rev, 0) - 1, 4), 'note', note)
               order by zone_group nulls last, location, client_code), '[]'::jsonb) from rows3),
    'method', 'Target for ' || to_char(v_m, 'Mon-YY') || ' per team x client code. Last month (' || to_char(v_p, 'Mon-YY') || ') = ' ||
        case v_basis when 'actual' then 'actual (complete month)' when 'expected closure' then 'expected closure: actual to ' || to_char(v_asof, 'DD-Mon') || ' ÷ ' || round(v_share * 100, 1) || '% (usual share of a month reached by that working day)'
             else 'forecast at the current pace (' || to_char(v_l, 'Mon-YY') || ' projected, with working days and seasonality), because no tracker for that month has arrived yet' end
      || '. Last 3 months = ' || to_char(v_c1, 'Mon') || '–' || to_char(v_c3, 'Mon-YY') || ' (complete months). BAU (organic) = the business-as-usual model for ' || to_char((v_l + interval '1 month')::date, 'Mon-YY')
      || case when v_m > (v_l + interval '1 month')::date then ', carried to ' || to_char(v_m, 'Mon-YY') || ' with working days and seasonality' else '' end
      || '. Potential = all client branches of clients active in India (team x client, split over codes by last 3 months revenue). Plan = '
      || case when v_ver is null then 'the suggested target (no plan saved)' else 'saved plan version ' || v_ver || ', else the suggested target' end
      || '. Capacity = the best of last month, the last 3 months average and BAU; ceiling = capacity + ' || round(v_cap * 100) || '%. Base = the highest of: plan (up to the ceiling); previous month''s target + ' || round(v_gmin * 100, 1) || '%' || case when v_sig then ' (strong seasonal signal: may fall by up to ' || round(v_drop * 100, 1) || '%)' else '' end
      || ' (up to the ceiling); last month + ' || round(v_gmin * 100, 1) || '%; BAU + ' || round(v_gmin * 100, 1) || '%. A team x client with no business in 3 months keeps its previous target unchanged; one with no business and no previous target gets no target (listed as a new-business opportunity). Quarter catch-up = ' || round(v_cu * 100) || '% of the quarter''s shortfall so far (plan − actual / outlook of its earlier months), shared over the quarter''s remaining months by plan, added only up to the ceiling and potential. Target cases = target revenue ÷ the row''s own rate (actual last 3 months; else its tracker target rate; else the same client code elsewhere; else the client family), rounded up. Clients with no business anywhere in India in the last three months are excluded: '
      || coalesce(array_to_string(v_inact, ', '), 'none') || '. Sources: bi.v_month_business, bi.organic_pairs, bi.potential_cell, bi.plan_compute / bi.plan_target, bi.plan_signals.')
    into r;
  return r;
end $f$;
revoke all on function bi.api_target_sheet(date, jsonb, jsonb) from public, anon, authenticated;
