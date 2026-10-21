-- Applied to Supabase project via MCP on 20261021182605
create or replace function bi.api_growth(p_month date, f jsonb, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
declare
  v_last date := (select max(snapshot_date) from bi.zt_snapshot);
  v_m date := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date;
  v_asof date; v_partial boolean; v_k int; v_kk int; v_cm date; v_cq date; v_qcur date; v_nq int;
  v_spm date; v_spy date; v_spq date; v_share numeric; v_cut date; v_dstart date;
  v_minc numeric := 30; v_minr numeric := 25000; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  v_asof := (select max(snapshot_date) from bi.zt_snapshot where report_month = v_m);
  v_partial := v_asof is not null and v_m >= date_trunc('month', v_last)::date;
  v_kk := bi.workdays(v_m, (v_m + interval '1 month - 1 day')::date);
  v_k := case when v_partial then bi.workdays(v_m, v_asof) else v_kk end;
  v_cm := case when v_partial then (v_m - interval '1 month')::date else v_m end;
  v_cq := case when v_cm = (bi.fy_qstart(v_cm) + interval '2 months')::date then bi.fy_qstart(v_cm)
               else (bi.fy_qstart(v_cm) - interval '3 months')::date end;
  v_qcur := bi.fy_qstart(v_m);
  v_nq := ((extract(year from v_m)::int - extract(year from v_qcur)::int) * 12 + extract(month from v_m)::int - extract(month from v_qcur)::int);
  if v_partial then
    v_spm := (select max(snapshot_date) from bi.zt_snapshot where report_month = (v_m - interval '1 month')::date and bi.workdays((v_m - interval '1 month')::date, snapshot_date) <= v_k);
    v_spy := (select max(snapshot_date) from bi.zt_snapshot where report_month = (v_m - interval '12 months')::date and bi.workdays((v_m - interval '12 months')::date, snapshot_date) <= v_k);
    v_spq := (select max(snapshot_date) from bi.zt_snapshot where report_month = (v_m - interval '3 months')::date and bi.workdays((v_m - interval '3 months')::date, snapshot_date) <= v_k);
    v_share := coalesce(bi.organic_share(v_m, v_k), round(v_k::numeric / v_kk, 4));
  end if;
  v_cut := (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date;
  v_dstart := (select min(received_month) from bi.case_store);

  with
  spec as (
    select 'mom'::text pid, 'cur'::text side, v_cm mon, null::date snap
    union all select 'mom', 'prev', (v_cm - interval '1 month')::date, null
    union all select 'yoy', 'cur', v_cm, null
    union all select 'yoy', 'prev', (v_cm - interval '12 months')::date, null
    union all select 'qoq', 'cur', (v_cq + g * interval '1 month')::date, null from generate_series(0, 2) g
    union all select 'qoq', 'prev', (v_cq - interval '3 months' + g * interval '1 month')::date, null from generate_series(0, 2) g
    union all select 'qyoy', 'cur', (v_cq + g * interval '1 month')::date, null from generate_series(0, 2) g
    union all select 'qyoy', 'prev', (v_cq - interval '12 months' + g * interval '1 month')::date, null from generate_series(0, 2) g
    union all select 'mtd', 'cur', null, v_asof where v_partial
    union all select 'mtd', 'prev', null, v_spm where v_partial and v_spm is not null
    union all select 'mtd_yoy', 'cur', null, v_asof where v_partial
    union all select 'mtd_yoy', 'prev', null, v_spy where v_partial and v_spy is not null
    union all select 'qtd', 'cur', (v_qcur + g * interval '1 month')::date, null from generate_series(0, v_nq - 1) g where v_qcur > v_cq
    union all select 'qtd', 'cur', case when v_partial then null else v_m end, case when v_partial then v_asof end where v_qcur > v_cq
    union all select 'qtd', 'prev', (v_qcur - interval '3 months' + g * interval '1 month')::date, null from generate_series(0, v_nq - 1) g where v_qcur > v_cq
    union all select 'qtd', 'prev', case when v_partial then null else (v_m - interval '3 months')::date end, case when v_partial then v_spq end
      where v_qcur > v_cq and (not v_partial or v_spq is not null)),
  loc as materialized (select l.id location_id, l.label, l.recon_unit, l.region from bi.location l where not coalesce(l.is_rollup, false)),
  mb as materialized (
    select v.month, v.location_id, coalesce(c.family, v.client_code) fam, sum(v.cases) cases, sum(v.revenue) revenue,
           count(*) filter (where v.revenue is null and coalesce(v.cases, 0) > 0) rev_missing, sum(v.target_cases) tgt, sum(v.revenue_target) rtgt
    from bi.v_month_business v join loc on loc.location_id = v.location_id left join bi.client c on c.code = v.client_code
    where v.month in (select s.mon from spec s where s.mon is not null)
      and bi.loc_ok(v.location_id, loc.recon_unit, f, v.month) and bi.fam_ok(v.client_code, f)
    group by 1, 2, 3),
  sn as materialized (
    select z.snapshot_date d, z.location_id, coalesce(c.family, z.client_code) fam, sum(z.mtd_cases) cases, sum(z.revenue_actual) revenue,
           sum(z.target_cases) tgt, sum(z.revenue_target) rtgt
    from bi.v_zt_leaf z join loc on loc.location_id = z.location_id left join bi.client c on c.code = z.client_code
    where z.snapshot_date in (select s.snap from spec s where s.snap is not null)
      and bi.loc_ok(z.location_id, loc.recon_unit, f, z.snapshot_date) and bi.fam_ok(z.client_code, f)
    group by 1, 2, 3),
  have as (select distinct month mon from bi.zt_month_history union select distinct report_month from bi.zt_snapshot),
  vals as materialized (
    select s.pid, s.side, x.location_id, x.fam, x.cases, x.revenue, x.tgt, x.rtgt, x.rev_missing, s.mon, s.snap
      from spec s join mb x on s.mon is not null and x.month = s.mon
    union all
    select s.pid, s.side, z.location_id, z.fam, z.cases, z.revenue, z.tgt, z.rtgt, 0, s.mon, s.snap
      from spec s join sn z on s.snap is not null and z.d = s.snap),
  sides as materialized (
    select s.pid, s.side,
           jsonb_agg(case when s.mon is not null then to_char(s.mon, 'Mon-YY') else 'to ' || to_char(s.snap, 'DD-Mon-YY') end order by coalesce(s.mon, s.snap)) parts,
           sum(case when s.mon is not null then bi.workdays(s.mon, (s.mon + interval '1 month - 1 day')::date) else bi.workdays(date_trunc('month', s.snap)::date, s.snap) end) wd,
           count(*) filter (where s.mon is not null and s.mon not in (select mon from have)) missing,
           count(*) n
    from spec s group by 1, 2),
  tg as materialized (
    select pid, side, sum(tgt) t, sum(rtgt) rt, count(distinct coalesce(mon, snap)) filter (where tgt is not null) ntg, sum(rev_missing) rm
    from vals group by 1, 2),
  pp as materialized (
    select pid, location_id, fam,
           sum(cases) filter (where side = 'cur') c1, sum(cases) filter (where side = 'prev') c0,
           sum(revenue) filter (where side = 'cur') r1, sum(revenue) filter (where side = 'prev') r0
    from vals group by 1, 2, 3),
  tot as materialized (
    select pid, sum(c1) c1, sum(c0) c0, sum(r1) r1, sum(r0) r0,
           sum(c1) filter (where c0 > 0 and c1 > 0) lc1, sum(c0) filter (where c0 > 0 and c1 > 0) lc0,
           sum(r1) filter (where r0 > 0 and r1 > 0) lr1, sum(r0) filter (where r0 > 0 and r1 > 0) lr0,
           coalesce(sum(c1) filter (where coalesce(c0, 0) = 0 and c1 > 0), 0) new_c, count(*) filter (where coalesce(c0, 0) = 0 and c1 > 0) new_n,
           coalesce(sum(c0) filter (where coalesce(c1, 0) = 0 and c0 > 0), 0) lost_c, count(*) filter (where coalesce(c1, 0) = 0 and c0 > 0) lost_n,
           count(*) filter (where c1 > 0) pairs1, count(*) filter (where c0 > 0) pairs0,
           count(distinct location_id) filter (where c1 > 0) locs1, count(distinct location_id) filter (where c0 > 0) locs0
    from pp group by pid),
  card as materialized (
    select t.pid,
      jsonb_build_object('id', t.pid,
        'current', jsonb_build_object('label', sc.parts, 'cases', t.c1, 'revenue', round(t.r1), 'working_days', sc.wd, 'missing_months', sc.missing,
                                      'target_cases', case when tc.ntg = sc.n then tc.t end, 'attainment', case when tc.ntg = sc.n then round(t.c1 / nullif(tc.t, 0), 4) end,
                                      'revenue_target', case when tc.ntg = sc.n then round(tc.rt) end, 'revenue_attainment', case when tc.ntg = sc.n then round(t.r1 / nullif(tc.rt, 0), 4) end,
                                      'rows_without_revenue', tc.rm, 'pairs', t.pairs1, 'locations', t.locs1),
        'previous', jsonb_build_object('label', sp.parts, 'cases', t.c0, 'revenue', round(t.r0), 'working_days', sp.wd, 'missing_months', sp.missing,
                                      'target_cases', case when tp.ntg = sp.n then tp.t end, 'attainment', case when tp.ntg = sp.n then round(t.c0 / nullif(tp.t, 0), 4) end,
                                      'revenue_target', case when tp.ntg = sp.n then round(tp.rt) end, 'revenue_attainment', case when tp.ntg = sp.n then round(t.r0 / nullif(tp.rt, 0), 4) end,
                                      'rows_without_revenue', tp.rm, 'pairs', t.pairs0, 'locations', t.locs0),
        'cases_change', t.c1 - t.c0, 'cases_pct', bi.pct_chg(t.c1, t.c0, v_minc),
        'revenue_change', round(t.r1 - t.r0), 'revenue_pct', bi.pct_chg(t.r1, t.r0, v_minr),
        'per_working_day_pct', bi.pct_chg(t.c1 / nullif(sc.wd, 0), t.c0 / nullif(sp.wd, 0), 0.0001),
        'like_for_like', jsonb_build_object('cases_current', t.lc1, 'cases_previous', t.lc0, 'cases_pct', bi.pct_chg(t.lc1, t.lc0, v_minc),
                                            'revenue_current', round(t.lr1), 'revenue_previous', round(t.lr0), 'revenue_pct', bi.pct_chg(t.lr1, t.lr0, v_minr)),
        'structure', jsonb_build_object('new_pairs', t.new_n, 'new_pair_cases', t.new_c, 'lost_pairs', t.lost_n, 'lost_pair_cases', t.lost_c),
        'complete', coalesce(sc.missing, 0) = 0 and coalesce(sp.missing, 0) = 0 and t.c0 is not null and t.c1 is not null) j
    from tot t join sides sc on sc.pid = t.pid and sc.side = 'cur' left join sides sp on sp.pid = t.pid and sp.side = 'prev'
      left join tg tc on tc.pid = t.pid and tc.side = 'cur' left join tg tp on tp.pid = t.pid and tp.side = 'prev'),
  org as materialized (
    select o.location_id, coalesce(c.family, o.client_code) fam, round(sum(o.organic) filter (where o.month = v_cm)) org_cm, sum(o.organic) filter (where o.month = v_m) org_m
    from bi.organic_store o join loc on loc.location_id = o.location_id left join bi.client c on c.code = o.client_code
    where o.month in (v_cm, v_m) and bi.loc_ok(o.location_id, loc.recon_unit, f, o.month) and bi.fam_ok(o.client_code, f) group by 1, 2),
  bt0 as materialized (
    select coalesce(o.month, a.month) mon, coalesce(o.location_id, a.location_id) location_id, coalesce(o.client_code, a.client_code) client_code,
           coalesce(o.organic, 0) org, coalesce(a.cases, 0) act
    from (select o2.* from bi.organic_store o2 where o2.month between (v_cm - interval '9 months')::date and v_cm) o
    full join (select a2.month, a2.location_id, a2.client_code, sum(a2.cases) cases from bi.v_month_business a2
               where a2.month between (v_cm - interval '9 months')::date and v_cm group by 1, 2, 3) a
      on a.month = o.month and a.location_id = o.location_id and a.client_code = o.client_code),
  bt as materialized (
    select b.mon, sum(b.org) org, sum(b.act) act, sum(abs(b.act - b.org)) abs_err
    from bt0 b join loc on loc.location_id = b.location_id
    where bi.loc_ok(b.location_id, loc.recon_unit, f, b.mon) and bi.fam_ok(b.client_code, f)
      and b.mon in (select distinct month from bi.organic_store) group by 1),
  br as materialized (
    select v.location_id, v.fam, count(*) verified, count(*) filter (where not v.website) matchable,
           count(*) filter (where not v.website and a.last_m >= v_cut) active6,
           count(*) filter (where not v.website and a.first_m >= (v_m - interval '2 months')::date and a.first_m >= (v_dstart + interval '3 months')::date) recent,
           count(*) filter (where not v.website and a.n is not null and a.last_m < v_cut) dormant,
           count(*) filter (where not v.website and a.n is null) never
    from bi.branch_cov_mv v left join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm and not v.website
    where v.status = 'active' and v.vs in ('source_verified', 'admin_upload') and v.location_id is not null group by 1, 2),
  peer as materialized (
    select v.location_id, v.fam, percentile_cont(0.5) within group (order by a.n3 / 3.0) med, count(*) peers
    from bi.branch_cov_mv v join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm
    where v.status = 'active' and v.vs in ('source_verified', 'admin_upload') and not v.website and a.n3 > 0 and v.location_id is not null
    group by 1, 2 having count(*) >= 5),
  fu as materialized (
    select u.recon_unit, u.client_family fam,
           round(sum(u.matched_cases) filter (where u.month = v_cm and u.case_data_available) / nullif(sum(u.tracker_cases) filter (where u.month = v_cm and u.case_data_available), 0), 4) use1,
           round(sum(u.matched_cases) filter (where u.month = (v_cm - interval '1 month')::date and u.case_data_available) / nullif(sum(u.tracker_cases) filter (where u.month = (v_cm - interval '1 month')::date and u.case_data_available), 0), 4) use0
    from bi.v_force_usage u where u.month in (v_cm, (v_cm - interval '1 month')::date) group by 1, 2),
  tat as materialized (
    select c.location_id, c.client_family fam,
           round((percentile_cont(0.5) within group (order by c.raw_tat_hours) filter (where c.received_month = v_cm and c.tat_flag = 'valid'))::numeric, 1) med1,
           round((percentile_cont(0.5) within group (order by c.raw_tat_hours) filter (where c.received_month = (v_cm - interval '1 month')::date and c.tat_flag = 'valid'))::numeric, 1) med0,
           round(avg(case when c.sla_met then 1.0 when c.sla_met = false then 0 end) filter (where c.received_month = v_cm), 4) sla1,
           round(avg(case when c.sla_met then 1.0 when c.sla_met = false then 0 end) filter (where c.received_month = (v_cm - interval '1 month')::date), 4) sla0,
           count(*) filter (where c.received_month = v_cm) n1
    from bi.v_case c where c.received_month in (v_cm, (v_cm - interval '1 month')::date) and c.location_id is not null group by 1, 2),
  keys as materialized (select distinct location_id, fam from pp where coalesce(c1, 0) > 0 or coalesce(c0, 0) > 0),
  pr as materialized (
    select k.location_id, k.fam, loc.label loc_label, loc.recon_unit, loc.region,
           coalesce(fr.display_name, cl.label, k.fam) fam_label,
           bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm + interval '1 month - 1 day')::date) owner,
           bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm - interval '1 day')::date) owner_prev,
           (select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(k.location_id, 'zone_group', (v_cm + interval '1 month - 1 day')::date)) zone,
           exists (select 1 from bi.location_mapping_history h where h.active and h.location_id = k.location_id and h.valid_from > (v_cm - interval '12 months')::date) mapping_changed,
           mo.c1 mom_c1, mo.c0 mom_c0, mo.r1 mom_r1, mo.r0 mom_r0, yo.c1 yoy_c1, yo.c0 yoy_c0, yo.r1 yoy_r1, yo.r0 yoy_r0,
           qo.c1 qoq_c1, qo.c0 qoq_c0, qo.r1 qoq_r1, qo.r0 qoq_r0, mt.c1 mtd_c1, mt.c0 mtd_c0, mt.r1 mtd_r1, mt.r0 mtd_r0,
           (select sum(z.tgt) from sn z where z.d = v_asof and z.location_id = k.location_id and z.fam = k.fam) tgt_m,
           og.org_cm, og.org_m, b.verified, b.matchable, b.active6, b.recent, b.dormant, b.never, pe.med peer_med, pe.peers,
           round(b.never * pe.med) opp_cases, fu.use1, fu.use0, ta.med1, ta.med0, ta.sla1, ta.sla0, ta.n1,
           (select to_char(max(r.last_verified_at), 'YYYY-MM-DD') from bi.client_family_research r where r.family = k.fam) verified_on
    from keys k join loc on loc.location_id = k.location_id
      left join bi.client cl on cl.code = k.fam left join bi.client_family_research fr on fr.family = k.fam
      left join pp mo on mo.pid = 'mom' and mo.location_id = k.location_id and mo.fam = k.fam
      left join pp yo on yo.pid = 'yoy' and yo.location_id = k.location_id and yo.fam = k.fam
      left join pp qo on qo.pid = 'qoq' and qo.location_id = k.location_id and qo.fam = k.fam
      left join pp mt on mt.pid = 'mtd' and mt.location_id = k.location_id and mt.fam = k.fam
      left join org og on og.location_id = k.location_id and og.fam = k.fam
      left join br b on b.location_id = k.location_id and b.fam = k.fam
      left join peer pe on pe.location_id = k.location_id and pe.fam = k.fam
      left join fu on fu.recon_unit = loc.recon_unit and fu.fam = k.fam
      left join tat ta on ta.location_id = k.location_id and ta.fam = k.fam),
  net as materialized (select sum(coalesce(mom_c1, 0) - coalesce(mom_c0, 0)) mom, sum(coalesce(qoq_c1, 0) - coalesce(qoq_c0, 0)) qoq, sum(coalesce(yoy_c1, 0) - coalesce(yoy_c0, 0)) yoy,
                 sum(greatest(coalesce(mom_c1, 0) - coalesce(mom_c0, 0), 0)) mom_gain, sum(least(coalesce(mom_c1, 0) - coalesce(mom_c0, 0), 0)) mom_loss from pr),
  rows as materialized (
    select pr.*,
      case when coalesce(mom_c0, 0) = 0 and mom_c1 > 0 then 'new' when coalesce(mom_c1, 0) = 0 and mom_c0 > 0 then 'lost'
           when mom_c0 < v_minc then 'small_base' end mom_flag,
      case when coalesce(org_cm, 0) <= 0 then null when (coalesce(mom_c1, 0) - org_cm) / org_cm > 0.05 then 'above'
           when (coalesce(mom_c1, 0) - org_cm) / org_cm < -0.05 then 'below' else 'in_line' end org_status,
      case when pr.med0 is null or pr.med1 is null or pr.n1 < 20 then null else pr.med1 > pr.med0 * 1.10 end tat_worse
    from pr),
  prio as materialized (
    select r.location_id, r.fam,
           r.opp_cases, bi.pct_chg(r.mom_c1, r.org_cm, v_minc) effort_pct,
           (coalesce(r.tat_worse, false) = false and coalesce(r.sla1, 1) >= 0.8) ops_ok
    from rows r where coalesce(r.opp_cases, 0) > 0 and coalesce(r.mom_c1, 0) >= v_minc)
  select jsonb_build_object(
    'month', v_m, 'as_of', v_asof, 'partial', v_partial, 'completed_month', v_cm, 'completed_quarter', v_cq, 'completed_quarter_label', bi.fy_qlabel(v_cq),
    'current_quarter', v_qcur, 'current_quarter_label', bi.fy_qlabel(v_qcur), 'workdays_elapsed', v_k, 'workdays_in_month', v_kk,
    'comparison_snapshots', jsonb_build_object('previous_month', v_spm, 'previous_year', v_spy, 'previous_quarter', v_spq,
        'previous_month_workday', case when v_spm is not null then bi.workdays(date_trunc('month', v_spm)::date, v_spm) end,
        'previous_year_workday', case when v_spy is not null then bi.workdays(date_trunc('month', v_spy)::date, v_spy) end,
        'previous_quarter_workday', case when v_spq is not null then bi.workdays(date_trunc('month', v_spq)::date, v_spq) end),
    'filters', f, 'min_base', jsonb_build_object('cases', v_minc, 'revenue', v_minr),
    'cards', (select coalesce(jsonb_object_agg(pid, j), '{}') from card),
    'unavailable', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('id', 'mtd', 'reason', 'No report in the previous month up to the same working day') x where v_partial and v_spm is null
        union all select jsonb_build_object('id', 'mtd_yoy', 'reason', 'No daily report for ' || to_char(v_m - interval '12 months', 'Mon-YYYY') || ' (daily reports start ' || to_char((select min(report_month) from bi.zt_snapshot), 'Mon-YYYY') || '); only full months can be compared year on year') where v_partial and v_spy is null
        union all select jsonb_build_object('id', 'qtd', 'reason', 'No report in ' || to_char(v_m - interval '3 months', 'Mon-YYYY') || ' up to the same working day') where v_partial and v_qcur > v_cq and v_spq is null) q),
    'organic', jsonb_build_object('share_to_date', v_share,
        'validation', (select jsonb_build_object('months', count(*), 'from', min(mon), 'to', max(mon),
                         'pan_mape', round(avg(abs(act - org) / nullif(act, 0)), 4), 'pair_wape', round(sum(abs_err) / nullif(sum(act), 0), 4),
                         'by_month', jsonb_agg(jsonb_build_object('month', mon, 'actual', round(act), 'organic', round(org), 'error_pct', round((act - org) / nullif(act, 0), 4)) order by mon))
                       from bt where act > 0)),
    'net', (select to_jsonb(net) from net),
    'pairs', (select coalesce(jsonb_agg(jsonb_build_object(
        'location_id', r.location_id, 'location', r.loc_label, 'zone', r.zone, 'region', r.region, 'unit', r.recon_unit, 'client', r.fam, 'client_label', r.fam_label,
        'owner', r.owner, 'owner_changed', r.owner is distinct from r.owner_prev, 'mapping_changed', r.mapping_changed,
        'cases', r.mom_c1, 'revenue', round(r.mom_r1),
        'mom', jsonb_build_object('prev', r.mom_c0, 'chg', coalesce(r.mom_c1, 0) - coalesce(r.mom_c0, 0), 'pct', bi.pct_chg(r.mom_c1, r.mom_c0, v_minc),
                                  'rev_prev', round(r.mom_r0), 'rev_chg', round(coalesce(r.mom_r1, 0) - coalesce(r.mom_r0, 0)), 'rev_pct', bi.pct_chg(r.mom_r1, r.mom_r0, v_minr), 'flag', r.mom_flag,
                                  'share_of_net', round((coalesce(r.mom_c1, 0) - coalesce(r.mom_c0, 0)) / nullif(abs((select mom from net)), 0), 4)),
        'qoq', jsonb_build_object('cur', r.qoq_c1, 'prev', r.qoq_c0, 'chg', coalesce(r.qoq_c1, 0) - coalesce(r.qoq_c0, 0), 'pct', bi.pct_chg(r.qoq_c1, r.qoq_c0, v_minc * 3),
                                  'rev_cur', round(r.qoq_r1), 'rev_prev', round(r.qoq_r0), 'rev_pct', bi.pct_chg(r.qoq_r1, r.qoq_r0, v_minr * 3),
                                  'share_of_net', round((coalesce(r.qoq_c1, 0) - coalesce(r.qoq_c0, 0)) / nullif(abs((select qoq from net)), 0), 4)),
        'yoy', jsonb_build_object('prev', r.yoy_c0, 'chg', coalesce(r.yoy_c1, 0) - coalesce(r.yoy_c0, 0), 'pct', bi.pct_chg(r.yoy_c1, r.yoy_c0, v_minc),
                                  'rev_prev', round(r.yoy_r0), 'rev_pct', bi.pct_chg(r.yoy_r1, r.yoy_r0, v_minr), 'new', coalesce(r.yoy_c0, 0) = 0 and coalesce(r.yoy_c1, 0) > 0),
        'mtd', case when v_partial then jsonb_build_object('cur', r.mtd_c1, 'prev', r.mtd_c0, 'chg', coalesce(r.mtd_c1, 0) - coalesce(r.mtd_c0, 0), 'pct', bi.pct_chg(r.mtd_c1, r.mtd_c0, v_minc),
                                  'rev_cur', round(r.mtd_r1), 'rev_prev', round(r.mtd_r0), 'rev_pct', bi.pct_chg(r.mtd_r1, r.mtd_r0, v_minr),
                                  'target', r.tgt_m, 'attainment', round(r.mtd_c1 / nullif(r.tgt_m, 0), 4),
                                  'organic_to_date', round(r.org_m * v_share), 'effort', coalesce(r.mtd_c1, 0) - round(r.org_m * v_share),
                                  'projected', round(r.mtd_c1 / nullif(v_share, 0)), 'projected_attainment', round(r.mtd_c1 / nullif(v_share, 0) / nullif(r.tgt_m, 0), 4)) end,
        'organic', jsonb_build_object('expected', round(r.org_cm), 'effort', round(coalesce(r.mom_c1, 0) - r.org_cm), 'effort_pct', bi.pct_chg(r.mom_c1, r.org_cm, v_minc), 'status', r.org_status),
        'branches', case when r.verified is not null then jsonb_build_object('verified', r.verified, 'matchable', r.matchable, 'active_6m', r.active6, 'coverage', round(r.active6::numeric / nullif(r.matchable, 0), 4),
                                  'recently_activated', r.recent, 'dormant', r.dormant, 'never_activated', r.never, 'peer_median', round(r.peer_med::numeric, 1), 'peers', r.peers,
                                  'indicative_cases_per_month', r.opp_cases, 'verified_on', r.verified_on) end,
        'force1', jsonb_build_object('utilisation', r.use1, 'prev', r.use0, 'unit_level', true),
        'tat', jsonb_build_object('median_hours', r.med1, 'prev_median_hours', r.med0, 'sla', r.sla1, 'prev_sla', r.sla0, 'cases', r.n1, 'worse', r.tat_worse),
        'confidence', (select coalesce(jsonb_agg(w), '[]') from (
            select 'small base (' || coalesce(r.mom_c0, 0) || ' cases last month)' w where coalesce(r.mom_c0, 0) between 1 and v_minc - 1
            union all select 'new this month' where coalesce(r.mom_c0, 0) = 0 and coalesce(r.mom_c1, 0) > 0
            union all select 'no business last year (new pair)' where coalesce(r.yoy_c0, 0) = 0 and coalesce(r.yoy_c1, 0) > 0
            union all select 'location attributes changed in the last 12 months' where r.mapping_changed
            union all select 'owner changed this month' where r.owner is distinct from r.owner_prev
            union all select 'no organic estimate (under 3 months of history)' where r.org_cm is null and coalesce(r.mom_c1, 0) > 0) z),
        'priority', (select jsonb_build_object('score', round((pz.opp_cases * (1 + greatest(-0.5, least(0.5, coalesce(pz.effort_pct, 0)))) * case when pz.ops_ok then 1 else 0.5 end)::numeric),
                                               'opportunity', pz.opp_cases, 'effort_pct', pz.effort_pct, 'ops_ok', pz.ops_ok)
                     from prio pz where pz.location_id = r.location_id and pz.fam = r.fam))
        order by abs(coalesce(r.mom_c1, 0) - coalesce(r.mom_c0, 0)) desc), '[]') from rows r),
    'method', jsonb_build_object(
      'periods', 'Months are calendar months; quarters are Indian financial-year quarters (Q1 Apr–Jun, Q2 Jul–Sep, Q3 Oct–Dec, Q4 Jan–Mar). Completed month = the selected month once it has ended, otherwise the month before. Completed quarter = the latest quarter whose three months have all ended. Quarter totals are the sum of the three monthly totals, never an average of monthly growth rates.',
      'to_date', 'Month to date compares the latest report with the previous month''s report on the same working day (Monday–Saturday). Quarter to date adds the completed months of the current quarter to the month to date and compares with the same months and working day of the previous quarter. Partial periods are always labelled.',
      'like_for_like', 'Like for like keeps only location × client pairs with business in both periods; the rest of the change comes from new or lost pairs (for example a location that started reporting).',
      'small_base', 'A change % is not shown when the earlier period has fewer than 30 cases (90 for a quarter) or less than ₹25,000 revenue (₹75,000 for a quarter); the absolute change is always shown.',
      'working_days', 'Per working day compares cases per working day, removing differences in the number of Monday–Saturday days.',
      'organic', 'Organic expectation = the existing business-as-usual model (Growth & trends → Organic vs actual): weighted recent three months per working day, seasonally adjusted. Effort = actual − organic. It is an estimate, not an observed fact or proof of cause.',
      'contribution', 'Share of net change = this pair''s change ÷ the absolute net change of the selection (positive and negative shares add up to ±100%).',
      'branches', 'Branch figures come from the verified client branch master (RBI IFSC directory for banks, official locators for other lenders) matched to Force1 cases by branch code. Indicative cases per month = never-activated branches × the median monthly cases of at least five active peer branches of the same client in the same location — a sizing aid, not a forecast.',
      'force1', 'Force1 utilisation is measured per location group (unit) and client, so locations that share a unit show the same value.',
      'owner', 'Owner = the stakeholder mapped to the location for the period (effective-dated). It is mapped responsibility, not proof of who caused a change.',
      'priority', 'Priority = indicative cases from never-activated branches × (1 + effort above organic, capped at ±50%) × 0.5 when TAT worsened by more than 10% or SLA met is below 80%. A ranking aid for where to look first.',
      'workforce', 'Workforce capacity is not shown: the HR workforce master has not been uploaded (Admin workspace → HR / workforce master data).'))
  into res;
  return res;
end $fn$;
