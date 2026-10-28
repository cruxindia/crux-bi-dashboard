-- Applied to Supabase project via MCP on 20261022113038
-- bi_094b (22-Oct-2026): branch-manager performance — current month first.
-- Business (Zonal Tracker, operations): expected revenue and cases month to date vs target, pace, projection, same working day last month,
-- organic to date. Finance (billing & collection, their own dates): invoices of the last completely billed month and of the month still
-- being billed, receipts of the current and previous receipt month, outstanding. Zone-billed invoices / receipts / outstanding and
-- families split between managers are allocated to location × client by tracker expected revenue (flagged).
-- Hand-overs: before vs after each change of manager, vs organic and vs the rest of the business. Mapped responsibility, not proof of cause.
create or replace function bi.api_bm(p_month date, f jsonb, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare
  v_last date := (select max(snapshot_date) from bi.zt_snapshot);
  v_m date := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date;
  v_asof date; v_partial boolean; v_k int; v_kk int; v_cm date; v_spm date; v_share numeric; v_at date;
  v_bb jsonb := bi.fin_billing_basis(); v_bc date; v_bp date; v_thru date; v_rm date; v_rmp date; v_co bigint[]; v_os bigint; v_osasof date;
  v_kr int; v_kkr int; v_wfrom date; v_mgr text := nullif(p->>'manager', ''); v_any boolean; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  v_any := f <> '{}'::jsonb;
  v_asof := (select max(snapshot_date) from bi.zt_snapshot where report_month = v_m);
  v_partial := v_asof is not null and v_m >= date_trunc('month', v_last)::date;
  v_kk := bi.workdays(v_m, (v_m + interval '1 month - 1 day')::date);
  v_k := case when v_partial then bi.workdays(v_m, v_asof) else v_kk end;
  v_cm := case when v_partial then (v_m - interval '1 month')::date else v_m end;
  v_at := case when v_partial then v_asof else (v_m + interval '1 month - 1 day')::date end;
  if v_partial then
    v_spm := (select max(snapshot_date) from bi.zt_snapshot where report_month = (v_m - interval '1 month')::date
                and bi.workdays((v_m - interval '1 month')::date, snapshot_date) <= v_k);
    v_share := coalesce(bi.organic_share(v_m, v_k), round(v_k::numeric / v_kk, 4));
  else
    v_share := 1;
  end if;
  v_bc := (v_bb->>'last_complete')::date;
  v_bp := case when (v_bc + interval '1 month')::date < date_trunc('month', coalesce(v_asof, v_last))::date then (v_bc + interval '1 month')::date end;
  v_thru := (v_bb->>'receipts_through')::date;
  v_rm := date_trunc('month', v_thru)::date; v_rmp := (v_rm - interval '1 month')::date;
  v_kr := bi.workdays(v_rm, v_thru); v_kkr := bi.workdays(v_rmp, (v_rm - interval '1 day')::date);
  select array_agg(id) into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  select id, as_of into v_os, v_osasof from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  v_co := coalesce(v_co, '{}'::bigint[]);
  v_wfrom := least(coalesce(v_bc, v_cm) - interval '5 months', v_rmp - interval '3 months', v_cm - interval '6 months')::date;

  with
  loc as materialized (select l.id location_id, l.label, l.recon_unit from bi.location l where not coalesce(l.is_rollup, false)),
  cl as materialized (select c.code, coalesce(c.family, c.code) fam, c.label from bi.client c),
  -- ---------- business: current month (to date) and the same working day last month, at location × client ----------
  cur as materialized (
    select z.location_id, z.client_code, sum(z.mtd_cases) cases, sum(z.revenue_actual) rev, sum(z.target_cases) tc, sum(z.revenue_target) tr, max(z.rate) rate
      from bi.v_zt_leaf z join loc on loc.location_id = z.location_id
     where v_partial and z.snapshot_date = v_asof and bi.loc_ok(z.location_id, loc.recon_unit, f, z.snapshot_date) and bi.fam_ok(z.client_code, f)
     group by 1, 2
    union all
    select v.location_id, v.client_code, sum(v.cases), sum(v.revenue), sum(v.target_cases), sum(v.revenue_target), sum(v.revenue) / nullif(sum(v.cases), 0)
      from bi.v_month_business v join loc on loc.location_id = v.location_id
     where not v_partial and v.month = v_m and bi.loc_ok(v.location_id, loc.recon_unit, f, v.month) and bi.fam_ok(v.client_code, f)
     group by 1, 2),
  prv as materialized (
    select z.location_id, z.client_code, sum(z.mtd_cases) cases, sum(z.revenue_actual) rev
      from bi.v_zt_leaf z join loc on loc.location_id = z.location_id
     where v_partial and v_spm is not null and z.snapshot_date = v_spm and bi.loc_ok(z.location_id, loc.recon_unit, f, z.snapshot_date) and bi.fam_ok(z.client_code, f)
     group by 1, 2
    union all
    select v.location_id, v.client_code, sum(v.cases), sum(v.revenue)
      from bi.v_month_business v join loc on loc.location_id = v.location_id
     where not v_partial and v.month = (v_m - interval '1 month')::date and bi.loc_ok(v.location_id, loc.recon_unit, f, v.month) and bi.fam_ok(v.client_code, f)
     group by 1, 2),
  org as materialized (
    select o.location_id, o.client_code, sum(o.organic) organic from bi.organic_store o join loc on loc.location_id = o.location_id
     where o.month = v_m and bi.loc_ok(o.location_id, loc.recon_unit, f, o.month) and bi.fam_ok(o.client_code, f) group by 1, 2),
  -- monthly history used for completed months, finance weights and hand-overs
  hm as materialized (
    select v.month, v.location_id, v.client_code, sum(v.cases) cases, sum(v.revenue) rev, sum(v.target_cases) tc, sum(v.revenue_target) tr
      from bi.v_month_business v join loc on loc.location_id = v.location_id
     where v.month between least(v_wfrom, (select coalesce(min(m.valid_from), v_wfrom) from bi.branch_manager m where m.active) - interval '3 months')::date and v_cm
     group by 1, 2, 3),
  hmf as materialized (select h.* from hm h join loc on loc.location_id = h.location_id where bi.loc_ok(h.location_id, loc.recon_unit, f, h.month) and bi.fam_ok(h.client_code, f)),
  keys as (select location_id, client_code from cur union select location_id, client_code from prv union select location_id, client_code from org
           union select location_id, client_code from hmf where month in (v_cm, (v_cm - interval '1 month')::date)),
  km as materialized (select k.location_id, k.client_code, bi.branch_manager_code_at(k.location_id, k.client_code, v_at) mgr from keys k),
  b1 as materialized (
    select km.location_id, km.client_code, coalesce(km.mgr, '(not mapped)') mgr, c.cases c1, c.rev r1, c.tc, c.tr, c.rate, pv.cases c0, pv.rev r0,
           o.organic * v_share otd, o.organic * v_share * coalesce(c.rate, c.rev / nullif(c.cases, 0)) ortd, o.organic om,
           h1.rev cm_r1, h0.rev cm_r0, h1.cases cm_c1, h0.cases cm_c0
      from km left join cur c on c.location_id = km.location_id and c.client_code = km.client_code
      left join prv pv on pv.location_id = km.location_id and pv.client_code = km.client_code
      left join org o on o.location_id = km.location_id and o.client_code = km.client_code
      left join hmf h1 on h1.month = v_cm and h1.location_id = km.location_id and h1.client_code = km.client_code
      left join hmf h0 on h0.month = (v_cm - interval '1 month')::date and h0.location_id = km.location_id and h0.client_code = km.client_code),
  -- ---------- finance: pool by billing unit × family × month, allocate to member location × client by tracker expected revenue ----------
  um as materialized (select * from bi.fin_unit_map()),
  mem as materialized (select u.unit_id, u.location_id from um u join loc on loc.location_id = u.location_id
                        where (u.zone_level and u.is_member) or (not u.zone_level and u.unit_id = u.location_id)),
  src as materialized (
    select 'billed'::text kind, i.inv_month m, coalesce(u.unit_id, i.location_id) unit_id, coalesce(u.zone_level, false) zl, i.family, sum(i.basic) amt,
           i.inv_month w0, i.inv_month w1, (i.inv_month + interval '1 month - 1 day')::date at_
      from bi.fin_inv_month i left join um u on u.location_id = i.location_id
     where i.inv_month in (v_bc, v_bp) group by 1, 2, 3, 4, 5, 7, 8, 9
    union all
    select 'collected', r.rcpt_month, coalesce(u.unit_id, r.location_id), coalesce(u.zone_level, false), r.family, sum(r.amount),
           (r.rcpt_month - interval '3 months')::date, (r.rcpt_month - interval '1 month')::date, least(v_thru, (r.rcpt_month + interval '1 month - 1 day')::date)
      from bi.fin_rcpt_agg r left join um u on u.location_id = r.location_id
     where r.upload_id = any (v_co) and r.rcpt_month in (v_rm, v_rmp) and r.n > 0 group by 1, 2, 3, 4, 5, 7, 8, 9
    union all
    select 'outstanding', v_osasof, coalesce(u.unit_id, o.location_id), coalesce(u.zone_level, false), o.family, sum(o.os),
           (coalesce(v_bc, v_cm) - interval '5 months')::date, coalesce(v_bc, v_cm), v_at
      from bi.fin_os_agg o left join um u on u.location_id = o.location_id
     where o.upload_id = v_os and o.n > 0 group by 1, 2, 3, 4, 5, 7, 8, 9),
  wt as materialized (
    select s.kind, s.m, s.unit_id, s.family, h.location_id, h.client_code, sum(coalesce(nullif(h.rev, 0), h.cases)) w
      from src s join mem on mem.unit_id = s.unit_id
      join hm h on h.location_id = mem.location_id and h.month between s.w0 and s.w1
      join cl on cl.code = h.client_code and cl.fam = s.family
     group by 1, 2, 3, 4, 5, 6 having sum(coalesce(nullif(h.rev, 0), h.cases)) > 0),
  al as materialized (
    select s.kind, s.m, w.location_id, w.client_code, s.amt * w.w / sum(w.w) over (partition by s.kind, s.m, s.unit_id, s.family) amt,
           s.zl allocated, s.at_
      from src s join wt w on w.kind = s.kind and w.m = s.m and w.unit_id = s.unit_id and w.family = s.family),
  una as (select s.kind, s.m, sum(s.amt) amt from src s where not exists (select 1 from wt w where w.kind = s.kind and w.m = s.m and w.unit_id = s.unit_id and w.family = s.family) group by 1, 2),
  alf as materialized (
    select a.*, coalesce(bi.branch_manager_code_at(a.location_id, a.client_code, a.at_), '(not mapped)') mgr
      from al a join loc on loc.location_id = a.location_id
     where bi.loc_ok(a.location_id, loc.recon_unit, f, a.at_) and bi.fam_ok(a.client_code, f)),
  -- expected revenue of the billing months, by the manager of that month
  exb as materialized (
    select h.month m, coalesce(bi.branch_manager_code_at(h.location_id, h.client_code, (h.month + interval '1 month - 1 day')::date), '(not mapped)') mgr, sum(h.rev) rev
      from hmf h where h.month in (v_bc, v_bp) group by 1, 2),
  fin as (
    select mgr,
           sum(amt) filter (where kind = 'billed' and m = v_bc) bc, sum(amt) filter (where kind = 'billed' and m = v_bc and allocated) bc_al,
           sum(amt) filter (where kind = 'billed' and m = v_bp) bp,
           sum(amt) filter (where kind = 'collected' and m = v_rm) rc1, sum(amt) filter (where kind = 'collected' and m = v_rmp) rc0,
           sum(amt) filter (where kind = 'collected' and allocated) rc_al,
           sum(amt) filter (where kind = 'outstanding') os, sum(amt) filter (where kind = 'outstanding' and allocated) os_al
      from alf group by 1),
  -- ---------- per manager ----------
  mg as materialized (
    select b.mgr, sum(b.c1) c1, sum(b.r1) r1, sum(b.tc) tc, sum(b.tr) tr, sum(b.c0) c0, sum(b.r0) r0, sum(b.otd) otd, sum(b.ortd) ortd, sum(b.om) om,
           sum(b.r1) filter (where b.otd is not null) r1c, sum(b.c1) filter (where b.otd is not null) c1c,
           sum(b.cm_r1) cm_r1, sum(b.cm_r0) cm_r0, sum(b.cm_c1) cm_c1, sum(b.cm_c0) cm_c0,
           count(distinct b.location_id) filter (where coalesce(b.c1, 0) > 0 or coalesce(b.tc, 0) > 0) nloc,
           count(distinct b.client_code) filter (where coalesce(b.c1, 0) > 0 or coalesce(b.tc, 0) > 0) ncli,
           (select jsonb_agg(distinct l.label) from loc l where l.location_id in (select b2.location_id from b1 b2 where b2.mgr = b.mgr and (coalesce(b2.c1, 0) > 0 or coalesce(b2.tc, 0) > 0 or coalesce(b2.cm_c1, 0) > 0))) locs
      from b1 b group by 1),
  -- ---------- hand-overs ----------
  ev0 as materialized (
    select m.location_id, m.client_family, m.client_code, m.valid_from d, m.manager new_mgr, pm.manager prev_mgr
      from bi.branch_manager m
      join lateral (select p2.manager from bi.branch_manager p2 where p2.active and p2.location_id = m.location_id and p2.client_family is not distinct from m.client_family
                      and p2.client_code is not distinct from m.client_code and p2.valid_to = m.valid_from - 1 order by p2.id desc limit 1) pm on true
     where m.active and m.valid_from is not null and pm.manager <> m.manager),
  evk as materialized (
    select distinct e.d, e.prev_mgr, e.new_mgr, k.location_id, k.client_code
      from ev0 e join (select distinct h.location_id, h.client_code from hm h) k on k.location_id = e.location_id
     where bi.branch_manager_code_at(k.location_id, k.client_code, e.d) = e.new_mgr and bi.branch_manager_code_at(k.location_id, k.client_code, e.d - 1) = e.prev_mgr),
  pan as materialized (select h.month, sum(h.cases) cases, sum(h.rev) rev from hm h group by 1),
  evw as materialized (
    select e.d, e.prev_mgr, e.new_mgr, g::date as month, bi.workdays(g::date, (g + interval '1 month - 1 day')::date) wd
      from (select distinct d, prev_mgr, new_mgr from evk) e,
           generate_series(greatest((e.d - interval '3 months')::date, date '2024-04-01'), least((e.d + interval '2 months')::date, v_cm), interval '1 month') g),
  evm as materialized (
    select w.d, w.prev_mgr, w.new_mgr, w.month, max(w.wd) wd, coalesce(sum(h.cases), 0) cases, coalesce(sum(h.rev), 0) rev, sum(o.organic) org
      from evw w join evk e on e.d = w.d and e.prev_mgr = w.prev_mgr and e.new_mgr = w.new_mgr
      left join hm h on h.month = w.month and h.location_id = e.location_id and h.client_code = e.client_code
      left join bi.organic_store o on o.month = w.month and o.location_id = e.location_id and o.client_code = e.client_code
     group by 1, 2, 3, 4),
  evs as materialized (
    select e.d, e.prev_mgr, e.new_mgr,
           sum(e.rev) filter (where e.month < e.d) rb, sum(e.rev) filter (where e.month >= e.d) ra,
           sum(e.cases) filter (where e.month < e.d) cb, sum(e.cases) filter (where e.month >= e.d) ca,
           sum(e.org) filter (where e.month < e.d) ob, sum(e.org) filter (where e.month >= e.d) oa,
           sum(e.wd) filter (where e.month < e.d) wb, sum(e.wd) filter (where e.month >= e.d) wa,
           sum(pn.rev) filter (where e.month < e.d) pb, sum(pn.rev) filter (where e.month >= e.d) pa,
           jsonb_agg(to_char(e.month, 'Mon-YY') order by e.month) filter (where e.month < e.d) mb_, jsonb_agg(to_char(e.month, 'Mon-YY') order by e.month) filter (where e.month >= e.d) ma_
      from evm e join pan pn on pn.month = e.month group by 1, 2, 3),
  evo as (
    select s.*, (select jsonb_agg(distinct l.label) from evk k join loc l on l.location_id = k.location_id where k.d = s.d and k.prev_mgr = s.prev_mgr and k.new_mgr = s.new_mgr) locs,
           (select count(*) from evk k where k.d = s.d and k.prev_mgr = s.prev_mgr and k.new_mgr = s.new_mgr) nkeys,
           (select jsonb_agg(distinct coalesce(c.fam, '')) from evk k join cl c on c.code = k.client_code where k.d = s.d and k.prev_mgr = s.prev_mgr and k.new_mgr = s.new_mgr) fams
      from evs s)
  select jsonb_build_object(
    'month', v_m, 'as_of', v_asof, 'partial', v_partial, 'workdays_elapsed', v_k, 'workdays_in_month', v_kk, 'share_of_month_done', v_share,
    'previous_month_snapshot', v_spm, 'completed_month', v_cm, 'filters', f,
    'finance', jsonb_build_object('last_complete_billing_month', v_bc, 'billing_in_progress_month', v_bp, 'billing_rule', v_bb->>'rule', 'outstanding_as_of', v_osasof,
        'receipts_through', v_thru, 'receipt_month', v_rm, 'receipt_workdays', v_kr, 'previous_receipt_month', v_rmp, 'previous_receipt_workdays', v_kkr,
        'unallocated', (select coalesce(jsonb_object_agg(kind || '_' || to_char(m, 'YYYY_MM'), round(amt)), '{}') from una where not v_any)),
    'total', (select jsonb_build_object(
        'expected_revenue', round(sum(r1)), 'revenue_target', round(sum(tr)), 'revenue_attainment', round(sum(r1) / nullif(sum(tr), 0), 4),
        'revenue_pace_target', round(sum(tr) * v_share), 'projected_revenue', case when v_share > 0 then round(sum(r1) / v_share) end,
        'expected_revenue_prev_same_day', round(sum(r0)), 'expected_revenue_change_pct', bi.pct_chg(sum(r1), sum(r0), 25000),
        'cases', sum(c1), 'case_target', sum(tc), 'cases_prev_same_day', sum(c0), 'cases_change_pct', bi.pct_chg(sum(c1), sum(c0), 30),
        'organic_cases_to_date', round(sum(otd)), 'organic_revenue_to_date', round(sum(ortd)),
        'effort_revenue', round(sum(r1c) - sum(ortd)), 'effort_pct', round((sum(c1c) - sum(otd)) / nullif(sum(otd), 0), 4),
        'completed_month_revenue', round(sum(cm_r1)), 'completed_month_prev_revenue', round(sum(cm_r0)), 'completed_month_change_pct', bi.pct_chg(sum(cm_r1), sum(cm_r0), 25000),
        'billed_complete', coalesce((select round(sum(amt)) from alf where kind = 'billed' and m = v_bc), 0) + case when v_any then 0 else coalesce((select round(amt) from una where kind = 'billed' and m = v_bc), 0) end,
        'expected_complete', (select round(sum(rev)) from exb where m = v_bc),
        'billed_in_progress', coalesce((select round(sum(amt)) from alf where kind = 'billed' and m = v_bp), 0) + case when v_any then 0 else coalesce((select round(amt) from una where kind = 'billed' and m = v_bp), 0) end,
        'expected_in_progress', (select round(sum(rev)) from exb where m = v_bp),
        'collected_current', coalesce((select round(sum(amt)) from alf where kind = 'collected' and m = v_rm), 0) + case when v_any then 0 else coalesce((select round(amt) from una where kind = 'collected' and m = v_rm), 0) end,
        'collected_previous', coalesce((select round(sum(amt)) from alf where kind = 'collected' and m = v_rmp), 0) + case when v_any then 0 else coalesce((select round(amt) from una where kind = 'collected' and m = v_rmp), 0) end,
        'outstanding', coalesce((select round(sum(amt)) from alf where kind = 'outstanding'), 0) + case when v_any then 0 else coalesce((select round(sum(amt)) from una where kind = 'outstanding'), 0) end)
      from mg),
    'managers', (select coalesce(jsonb_agg(jsonb_build_object(
        'manager', g.mgr, 'locations', g.locs, 'n_locations', g.nloc, 'n_clients', g.ncli,
        'expected_revenue', round(g.r1), 'revenue_target', round(g.tr), 'revenue_attainment', round(g.r1 / nullif(g.tr, 0), 4),
        'pace_gap', round(g.r1 - g.tr * v_share), 'pace_ratio', round(g.r1 / nullif(g.tr * v_share, 0), 4),
        'projected_revenue', case when v_share > 0 then round(g.r1 / v_share) end, 'projected_attainment', case when v_share > 0 then round(g.r1 / v_share / nullif(g.tr, 0), 4) end,
        'expected_revenue_prev_same_day', round(g.r0), 'revenue_change', round(g.r1 - g.r0), 'revenue_change_pct', bi.pct_chg(g.r1, g.r0, 25000),
        'cases', g.c1, 'case_target', g.tc, 'cases_prev_same_day', g.c0, 'cases_change_pct', bi.pct_chg(g.c1, g.c0, 30),
        'organic_cases_to_date', round(g.otd), 'organic_revenue_to_date', round(g.ortd), 'effort_revenue', round(g.r1c - g.ortd),
        'effort_pct', round((g.c1c - g.otd) / nullif(g.otd, 0), 4),
        'completed_month_revenue', round(g.cm_r1), 'completed_month_prev_revenue', round(g.cm_r0), 'completed_month_change_pct', bi.pct_chg(g.cm_r1, g.cm_r0, 25000),
        'billed_complete', round(fi.bc), 'expected_complete', round(xc.rev), 'billing_ratio', round(fi.bc / nullif(xc.rev, 0), 4), 'billed_complete_allocated', round(fi.bc_al),
        'billed_in_progress', round(fi.bp), 'expected_in_progress', round(xp.rev), 'billing_progress_ratio', round(fi.bp / nullif(xp.rev, 0), 4),
        'collected_current', round(fi.rc1), 'collected_previous', round(fi.rc0), 'collected_allocated', round(fi.rc_al),
        'collected_pace_change_pct', case when v_kr > 0 and v_kkr > 0 and fi.rc0 > 0 then round((fi.rc1 / v_kr) / (fi.rc0 / v_kkr) - 1, 4) end,
        'outstanding', round(fi.os), 'outstanding_allocated', round(fi.os_al),
        'since', (select min(m.valid_from) from bi.branch_manager m where m.active and m.manager = g.mgr and (m.valid_to is null or m.valid_to >= v_at)),
        'start_dates_known', not exists (select 1 from bi.branch_manager m where m.active and m.manager = g.mgr and m.valid_from is null and (m.valid_to is null or m.valid_to >= v_at)),
        'handovers_in', (select count(*) from evs e where e.new_mgr = g.mgr), 'handovers_out', (select count(*) from evs e where e.prev_mgr = g.mgr))
        order by g.r1 desc nulls last), '[]')
      from mg g left join fin fi on fi.mgr = g.mgr left join exb xc on xc.m = v_bc and xc.mgr = g.mgr left join exb xp on xp.m = v_bp and xp.mgr = g.mgr
      where coalesce(g.r1, 0) > 0 or coalesce(g.tr, 0) > 0 or coalesce(g.cm_r1, 0) > 0),
    'handovers', (select coalesce(jsonb_agg(jsonb_build_object(
        'date', e.d, 'from', e.prev_mgr, 'to', e.new_mgr, 'locations', e.locs, 'client_families', e.fams, 'rows', e.nkeys,
        'months_before', e.mb_, 'months_after', e.ma_,
        'revenue_per_workday_before', round(e.rb / nullif(e.wb, 0)), 'revenue_per_workday_after', round(e.ra / nullif(e.wa, 0)),
        'revenue_shift_pct', case when e.rb > 0 and e.wa > 0 then round((e.ra / e.wa) / (e.rb / e.wb) - 1, 4) end,
        'cases_per_workday_before', round(e.cb / nullif(e.wb, 0), 1), 'cases_per_workday_after', round(e.ca / nullif(e.wa, 0), 1),
        'cases_shift_pct', case when e.cb > 0 and e.wa > 0 then round((e.ca / e.wa) / (e.cb / e.wb) - 1, 4) end,
        'effort_before_pct', round((e.cb - e.ob) / nullif(e.ob, 0), 4), 'effort_after_pct', round((e.ca - e.oa) / nullif(e.oa, 0), 4),
        'rest_of_business_shift_pct', case when (e.pb - e.rb) > 0 and e.wa > 0 then round(((e.pa - e.ra) / e.wa) / ((e.pb - e.rb) / e.wb) - 1, 4) end,
        'relative_shift_pct', case when e.rb > 0 and e.wa > 0 and (e.pb - e.rb) > 0 and (e.pa - e.ra) > 0
                                   then round(((e.ra / e.wa) / (e.rb / e.wb)) / (((e.pa - e.ra) / e.wa) / ((e.pb - e.rb) / e.wb)) - 1, 4) end,
        'status', case when e.ma_ is null then 'too recent — no completed month since the change'
                       when e.mb_ is null then 'no history before the change'
                       when jsonb_array_length(e.ma_) < 3 then 'early read — ' || jsonb_array_length(e.ma_) || ' completed month(s) since the change' end)
        order by e.d desc, e.new_mgr), '[]') from evo e
      where v_mgr is null or e.prev_mgr = v_mgr or e.new_mgr = v_mgr),
    'portfolio', case when v_mgr is not null then (select coalesce(jsonb_agg(x order by (x->>'expected_revenue')::numeric desc nulls last), '[]') from (
        select jsonb_build_object('location', l.label, 'location_id', b.location_id, 'client', coalesce(c.fam, b.client_code),
               'client_label', string_agg(distinct coalesce(cc.label, b.client_code), ', '),
               'expected_revenue', round(sum(b.r1)), 'revenue_target', round(sum(b.tr)), 'revenue_attainment', round(sum(b.r1) / nullif(sum(b.tr), 0), 4),
               'pace_ratio', round(sum(b.r1) / nullif(sum(b.tr) * v_share, 0), 4),
               'expected_revenue_prev_same_day', round(sum(b.r0)), 'revenue_change_pct', bi.pct_chg(sum(b.r1), sum(b.r0), 25000),
               'cases', sum(b.c1), 'case_target', sum(b.tc), 'cases_prev_same_day', sum(b.c0),
               'organic_cases_to_date', round(sum(b.otd)), 'effort_pct', round((sum(b.c1) filter (where b.otd is not null) - sum(b.otd)) / nullif(sum(b.otd), 0), 4),
               'completed_month_revenue', round(sum(b.cm_r1)), 'completed_month_prev_revenue', round(sum(b.cm_r0))) x
          from b1 b join loc l on l.location_id = b.location_id left join cl c on c.code = b.client_code left join bi.client cc on cc.code = b.client_code
         where b.mgr = v_mgr and (coalesce(b.r1, 0) > 0 or coalesce(b.tr, 0) > 0 or coalesce(b.cm_r1, 0) > 0 or coalesce(b.r0, 0) > 0)
         group by l.label, b.location_id, coalesce(c.fam, b.client_code)) q) end,
    'trend', case when v_mgr is not null then (select coalesce(jsonb_agg(jsonb_build_object('month', t.month, 'expected_revenue', round(t.rev), 'revenue_target', round(t.tr), 'cases', t.cases) order by t.month), '[]') from (
        select h.month, sum(h.rev) rev, sum(h.tr) tr, sum(h.cases) cases from hmf h
         where h.month between (v_cm - interval '5 months')::date and v_cm
           and bi.branch_manager_code_at(h.location_id, h.client_code, (h.month + interval '1 month - 1 day')::date) = v_mgr group by 1) t) end,
    'method', jsonb_build_object(
      'business', 'Expected revenue = Zonal Tracker cases × agreed rate (operations), month to date to the latest daily report; target and pace from the tracker targets; projection = so far ÷ the share of a month normally done by this working day; compared with the same working day last month. Each location × client is counted under the branch manager mapped on the report date (client row > client-family row > location row).',
      'organic', 'Organic to date = the location × client organic expectation for the month (50 % MoM, 40 % QoQ, 10 % YoY) × the share of the month done; effort = actual − organic. In ₹ the organic cases are valued at each row''s tracker rate.',
      'finance', 'Billing and collection are a separate department with their own dates: billed = invoices (ex-GST) of the last completely billed month and of the month still being billed; collected = receipts (incl. GST) of the receipt month to the latest receipt date, pace = per working day vs the previous receipt month; outstanding = latest outstanding workbook. Zone-billed invoices, receipts and outstanding are allocated to the zone''s locations × clients in proportion to tracker expected revenue (marked "allocated" — estimates); a location''s invoices for a client family are split across its clients the same way when they have different managers.',
      'handover', 'For each change of manager: the same location × clients, expected revenue and cases per working day in up to 3 completed months before vs up to 3 completed months from the change; effort vs organic before and after; the rest of the business over the same months. Relative shift = own change ÷ rest-of-business change − 1. It shows what changed after the hand-over, not who caused it.',
      'responsibility', 'Branch managers are mapped responsibility (Admin → Master data & mapping), not proof of who caused a result.')
  ) into res;
  return res;
end $function$;
