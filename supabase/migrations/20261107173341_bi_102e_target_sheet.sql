-- Applied to Supabase project via MCP on 20261107173341
-- wave 102e (7-Nov-2026): target sheet for any coming month (owner: download December's target on the 1st or mid-November)
-- 1. BAU for a coming month projects the running tracker month to month end (it was read as month-to-date); BAU of the
--    current month is unchanged (its window ends with the last complete month)
do $m$
declare d text := pg_get_functiondef('bi.organic_pairs(date)'::regprocedure); o text := d;
begin
  d := replace(d, $a$  hist as (select mb.location_id, mb.client_code, mb.month, sum(mb.cases)::numeric v from bi.v_month_business mb, t$a$,
                  $a$  cur as materialized (select x.m, case when y.a is not null and y.a < (x.m + interval '1 month' - interval '1 day')::date
                                       then (select case when s > 0.2 and s <= 1 then s else 1 end from (select bi.organic_share(x.m, bi.workdays(x.m, y.a)) s) z) else 1 end sh
                          from (select max(v.month) m from bi.v_month_business v where coalesce(v.revenue, 0) > 0) x,
                               lateral (select max(v2.as_of) a from bi.v_month_business v2 where v2.month = x.m) y),
  hist as (select mb.location_id, mb.client_code, mb.month, sum(mb.cases)::numeric / case when mb.month = (select m from cur) then coalesce((select sh from cur), 1) else 1 end v from bi.v_month_business mb, t$a$);
  if d = o then raise exception 'organic_pairs: anchor not found'; end if;
  execute d;
end $m$;

-- 2. the sheet
create or replace function bi.api_target_sheet(p_month date, f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
-- One row per team (location) x client code for target month M:
--   last month (M-1) = actual if complete, expected closure (actual so far / usual share of the month) if running, pace forecast if not started;
--   last 3 complete months average; BAU (organic) for M; potential for M; previous month's target; plan for M
--   (saved plan, else suggested target); quarter catch-up = the quarter's shortfall so far (plan - actual/outlook of its earlier months),
--   shared over the quarter's remaining months by plan.
-- Target = base + catch-up, where base = max(plan, previous target x (1+gmin) [a strong-signal month: x (1 - allowed fall)],
--   last month x (1+gmin), BAU x (1+gmin)); the catch-up is added only up to min(potential, last month x (1 + cap)).
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
  codes as materialized (select distinct location_id, client_code, fam from vb where (month between v_c1 and v_l and cases > 0) or (month in (v_l, v_p) and tc > 0)),
  fcell as materialized (
    select x.location_id, x.fam from (
      select location_id, fam from codes
      union select s.location_id, s.fam from sg s where s.month = v_m and s.t > 0
      union select s.location_id, s.fam from sv s where s.month = v_m and s.t > 0) x
     where x.fam <> all (v_inact) and bi.loc_ok(x.location_id, null, f) and (f->>'client_family' is null or x.fam = f->>'client_family')),
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
           coalesce(w.rate, fr.r) rate, w.wt,
           -- last month (M-1)
           case when v_p < v_l then w.cp when v_p = v_l then w.cl / v_share else w.cl / v_share * coalesce((select factor from fac where month = v_p), 1) end lm_cases,
           case when v_p < v_l then w.rp when v_p = v_l then w.rl / v_share else w.rl / v_share * coalesce((select factor from fac where month = v_p), 1) end lm_rev,
           w.c3 l3_cases, w.r3 l3_rev,
           coalesce(b.bc, 0) bau_cases, coalesce(b.bc, 0) * coalesce(w.rate, fr.r, 0) bau_rev,
           coalesce(pt.pcs, 0) * w.wt pot_cases, coalesce(pt.pr, 0) * w.wt pot_rev,
           case when v_p <= v_l and w.trp is not null and w.trp > 0 and svp.t is null then w.trp else coalesce(q.plan_p, 0) * w.wt end prev_rev,
           case when v_p <= v_l and w.tcp is not null and w.tcp > 0 and svp.t is null then w.tcp end prev_cases_tracker,
           coalesce(q.plan_m, 0) * w.wt plan_rev,
           greatest(q.sf, 0) * coalesce(q.plan_m / nullif(q.rem, 0), 1) * w.wt cu_rev
      from w left join bi.location l on l.id = w.location_id left join bi.client cl on cl.code = w.client_code
      left join frate fr on fr.fam = w.fam
      left join bau b on b.location_id = w.location_id and b.client_code = w.client_code
      left join pot pt on pt.location_id = w.location_id and pt.fam = w.fam
      left join fq q on q.location_id = w.location_id and q.fam = w.fam
      left join sv svp on svp.location_id = w.location_id and svp.fam = w.fam and svp.month = v_p),
  rows1 as (
    select r0.*,
           greatest(r0.plan_rev, r0.prev_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end, r0.lm_rev * (1 + v_gmin), r0.bau_rev * (1 + v_gmin)) base_rev,
           least(r0.pot_rev, case when r0.lm_rev > 0 then r0.lm_rev * (1 + v_cap) else r0.pot_rev end) cap_rev
      from rows0 r0),
  rows2 as (
    select r1.*, r1.base_rev + least(r1.cu_rev * v_cu, greatest(r1.cap_rev - r1.base_rev, 0)) tgt_rev,
           case greatest(r1.plan_rev, r1.prev_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end, r1.lm_rev * (1 + v_gmin), r1.bau_rev * (1 + v_gmin))
             when r1.plan_rev then 'plan'
             when r1.prev_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end then case when v_sig then 'previous target less the allowed seasonal fall' else 'previous month''s target + ' || round(v_gmin * 100, 1) || '%' end
             when r1.lm_rev * (1 + v_gmin) then 'last month + ' || round(v_gmin * 100, 1) || '%'
             else 'BAU + ' || round(v_gmin * 100, 1) || '%' end base_rule
      from rows1 r1),
  rows3 as (
    select r2.*, ceil(r2.tgt_rev / nullif(r2.rate, 0)) tgt_cases,
           concat_ws('; ', 'base: ' || r2.base_rule,
             case when r2.cu_rev > 0 and r2.tgt_rev > r2.base_rev + 1 then 'quarter catch-up ' || bi.fmt_inr(r2.tgt_rev - r2.base_rev) end,
             case when r2.cu_rev * v_cu > r2.tgt_rev - r2.base_rev + 1 then 'catch-up capped at ' || case when r2.cap_rev = r2.pot_rev then 'potential' else 'last month + ' || round(v_cap * 100) || '%' end end,
             case when v_sig then 'strong seasonal signal for ' || to_char(v_m, 'Mon') end,
             case when r2.rate is null then 'no rate: cases not computed' end) note
      from rows2 r2 where r2.tgt_rev > 0 or r2.lm_rev > 0 or r2.l3_rev > 0)
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
                       'tgt_rev', round(sum(tgt_rev)), 'tgt_cases', sum(tgt_cases)) from rows3),
    'bridge', (select jsonb_build_array(
                  jsonb_build_object('label', 'Last month (' || v_basis || ')', 'value', round(sum(lm_rev)), 'kind', 'total'),
                  jsonb_build_object('label', 'BAU change', 'value', round(sum(bau_rev - lm_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Plan above BAU', 'value', round(sum(plan_rev - bau_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Floors (previous target / last month / BAU + ' || round(v_gmin * 100, 1) || '%)', 'value', round(sum(base_rev - plan_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Quarter catch-up', 'value', round(sum(tgt_rev - base_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Target ' || to_char(v_m, 'Mon-YY'), 'value', round(sum(tgt_rev)), 'kind', 'total')) from rows3),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', zone_group, 'location_id', location_id, 'location', coalesce(location, 'No team yet'), 'client_code', client_code, 'client', client, 'client_family', fam,
                  'rate', round(rate, 1), 'lm_cases', round(lm_cases), 'lm_rev', round(lm_rev), 'l3_cases', round(l3_cases, 1), 'l3_rev', round(l3_rev),
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
      || '. Base = the highest of: plan; previous month''s target + ' || round(v_gmin * 100, 1) || '%' || case when v_sig then ' (strong seasonal signal: may fall by up to ' || round(v_drop * 100, 1) || '%)' else '' end
      || '; last month + ' || round(v_gmin * 100, 1) || '%; BAU + ' || round(v_gmin * 100, 1) || '%. Quarter catch-up = ' || round(v_cu * 100) || '% of the quarter''s shortfall so far (plan − actual / outlook of its earlier months), shared over the quarter''s remaining months by plan, added only up to the lower of potential and last month + '
      || round(v_cap * 100) || '%. Target cases = target revenue ÷ the team x client rate (last 3 months), rounded up. Clients with no business anywhere in India in the last three months are excluded: '
      || coalesce(array_to_string(v_inact, ', '), 'none') || '. Sources: bi.v_month_business, bi.organic_pairs, bi.potential_cell, bi.plan_compute / bi.plan_target, bi.plan_signals.')
    into r;
  return r;
end $f$;
revoke all on function bi.api_target_sheet(date, jsonb, jsonb) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('bi.call_compute(text, jsonb)'::regprocedure);
begin
  if position('''target_sheet''' in d) = 0 then
    if position('when ''organic'' then' in d) = 0 then raise exception 'call_compute anchor not found'; end if;
    d := replace(d, 'when ''organic'' then', 'when ''target_sheet'' then bi.api_target_sheet(m, f, coalesce(p_args->''p'', ''{}''::jsonb))
      when ''organic'' then');
    execute d;
  end if;
end $m$;
