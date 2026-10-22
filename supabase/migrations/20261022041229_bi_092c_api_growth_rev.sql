-- Applied to Supabase project via MCP on 20261022041229
create or replace function bi.fin_org_validation(f jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
declare b jsonb := bi.fin_billing_basis(); v_fc date; v_lc date; v_ms date[]; res jsonb;
begin
  v_fc := (b->>'first_complete')::date; v_lc := (b->>'last_complete')::date;
  if v_fc is null or v_lc is null then return jsonb_build_object('months', 0, 'reason', 'No finance workbooks imported'); end if;
  select array_agg(g::date order by g) into v_ms from generate_series((v_fc + interval '2 months')::date, v_lc, interval '1 month') g;
  if v_ms is null then return jsonb_build_object('months', 0, 'reason', 'Fewer than three completely billed months'); end if;
  with o as materialized (select * from bi.fin_org_rev(v_ms, f)),
       a as materialized (select * from bi.fin_rev_facts(v_fc, v_lc, f) x where x.unit_ok),
       j as (select o.month, o.basis, o.org_billed, a.billed act, a.cases, o.rpc,
                    (select a2.billed from a a2 where a2.unit_id = o.unit_id and a2.fam = o.fam and a2.month = (o.month - interval '1 month')::date) last_b
             from o join a on a.unit_id = o.unit_id and a.fam = o.fam and a.month = o.month),
       m as (select j.month, sum(j.act) act, sum(j.act) filter (where j.org_billed is not null) act_cov, sum(j.org_billed) org,
                    sum(coalesce(j.last_b, 0)) filter (where j.org_billed is not null) naive,
                    sum(abs(coalesce(j.act, 0) - j.org_billed)) filter (where j.org_billed is not null) err,
                    sum(abs(coalesce(j.act, 0) - coalesce(j.last_b, 0))) filter (where j.org_billed is not null) err_naive,
                    sum(abs(coalesce(j.act, 0) - j.cases * j.rpc)) filter (where j.org_billed is not null and j.cases is not null) err_rate,
                    count(*) filter (where j.basis = 'pair') n_pair, count(*) filter (where j.basis = 'family') n_family
             from j group by 1)
  select jsonb_build_object('months', count(*), 'from', min(m.month), 'to', max(m.month),
     'pan_mape', round(avg(abs(m.act_cov - m.org) / nullif(m.act_cov, 0)), 4),
     'pair_wape', round(sum(m.err) / nullif(sum(m.act_cov), 0), 4),
     'bias', round(sum(m.org - m.act_cov) / nullif(sum(m.act_cov), 0), 4),
     'coverage', round(sum(m.act_cov) / nullif(sum(m.act), 0), 4),
     'naive_last_month', jsonb_build_object('pan_mape', round(avg(abs(m.act_cov - m.naive) / nullif(m.act_cov, 0)), 4), 'pair_wape', round(sum(m.err_naive) / nullif(sum(m.act_cov), 0), 4)),
     'rate_only_pair_wape', round(sum(m.err_rate) / nullif(sum(m.act_cov), 0), 4),
     'by_month', jsonb_agg(jsonb_build_object('month', m.month, 'actual', round(m.act_cov), 'organic', round(m.org), 'error_pct', round((m.act_cov - m.org) / nullif(m.act_cov, 0), 4),
                                              'pair_basis', m.n_pair, 'family_basis', m.n_family) order by m.month))
  into res from m where m.act_cov > 0;
  return res;
end $fn$;

create or replace function bi.api_growth_rev(p_month date, f jsonb, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
declare
  b jsonb := bi.fin_billing_basis();
  v_last date := (select max(snapshot_date) from bi.zt_snapshot);
  v_m date := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date;
  v_fc date; v_lc date; v_cm date; v_bm date; v_bq date; v_qs date; v_nq int; v_fy date; v_at date; v_from date; v_cut date; v_dstart date;
  v_minr numeric := 25000; v_grp text; v_ms date[]; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  v_grp := case when p->>'group' in ('client', 'unit', 'zone', 'stakeholder', 'region') then p->>'group' else 'pair' end;
  v_fc := (b->>'first_complete')::date; v_lc := (b->>'last_complete')::date;
  if v_fc is null or v_lc is null then
    return jsonb_build_object('available', false, 'measure', 'revenue',
      'reason', 'Actual invoiced revenue needs the outstanding and collection workbooks (Admin → Uploads). None is complete yet.');
  end if;
  v_cm := case when v_m >= date_trunc('month', v_last)::date then (v_m - interval '1 month')::date else v_m end;
  v_bm := least(v_cm, v_lc);
  v_at := (v_bm + interval '1 month - 1 day')::date;
  v_qs := bi.fy_qstart(v_bm);
  v_bq := case when v_bm = (v_qs + interval '2 months')::date then v_qs else (v_qs - interval '3 months')::date end;
  v_nq := (extract(year from v_bm)::int * 12 + extract(month from v_bm)::int) - (extract(year from v_qs)::int * 12 + extract(month from v_qs)::int) + 1;
  v_fy := bi.fin_fy(v_bm);
  v_from := least((v_bm - interval '12 months')::date, (v_bq - interval '12 months')::date, (v_fy - interval '12 months')::date, (v_cm - interval '11 months')::date);
  v_cut := (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date;
  v_dstart := (select min(received_month) from bi.case_store);
  select array_agg(distinct g::date) into v_ms from generate_series(v_from, v_m, interval '1 month') g;

  with
  spec as materialized (
    select 'mom'::text pid, 'cur'::text side, v_bm mon
    union all select 'mom', 'prev', (v_bm - interval '1 month')::date
    union all select 'qoq', 'cur', (v_bq + g * interval '1 month')::date from generate_series(0, 2) g
    union all select 'qoq', 'prev', (v_bq - interval '3 months' + g * interval '1 month')::date from generate_series(0, 2) g
    union all select 'qtd', 'cur', (v_qs + g * interval '1 month')::date from generate_series(0, v_nq - 1) g where v_nq < 3
    union all select 'qtd', 'prev', (v_qs - interval '3 months' + g * interval '1 month')::date from generate_series(0, v_nq - 1) g where v_nq < 3
    union all select 'yoy', 'cur', v_bm
    union all select 'yoy', 'prev', (v_bm - interval '12 months')::date
    union all select 'qyoy', 'cur', (v_bq + g * interval '1 month')::date from generate_series(0, 2) g
    union all select 'qyoy', 'prev', (v_bq - interval '12 months' + g * interval '1 month')::date from generate_series(0, 2) g
    union all select 'ytd', 'cur', g::date from generate_series(v_fy, v_bm, interval '1 month') g
    union all select 'ytd', 'prev', (g - interval '12 months')::date from generate_series(v_fy, v_bm, interval '1 month') g),
  sides as materialized (
    select s.pid, s.side, count(*) nm,
           jsonb_agg(to_char(s.mon, 'Mon-YY') order by s.mon) parts,
           bool_and(bi.fin_month_status(s.mon, b) = 'complete') complete,
           jsonb_agg(to_char(s.mon, 'Mon-YY') order by s.mon) filter (where bi.fin_month_status(s.mon, b) <> 'complete') not_complete
    from spec s group by 1, 2),
  avail as materialized (
    select c.pid, c.complete and p0.complete ok, c.parts cur_parts, p0.parts prev_parts, c.nm,
           coalesce(c.not_complete, '[]'::jsonb) || coalesce(p0.not_complete, '[]'::jsonb) missing
    from sides c join sides p0 on p0.pid = c.pid and p0.side = 'prev' where c.side = 'cur'),
  fx as materialized (select * from bi.fin_rev_facts(v_from, v_m, f, v_at)),
  ox as materialized (select * from bi.fin_org_rev(v_ms, f, v_at)),
  um as materialized (select * from bi.fin_unit_map()),
  ua as materialized (
    select u.unit_id, max(u.unit_label) label, bool_or(u.zone_level) zl, count(*) filter (where u.is_member) members,
           string_agg(distinct bi.loc_attr_at(u.location_id, 'stakeholder', v_at), ', ') filter (where u.is_member) owners,
           string_agg(distinct bi.loc_attr_at(u.location_id, 'stakeholder', (v_bm - interval '1 day')::date), ', ') filter (where u.is_member) owners_prev,
           coalesce(string_agg(distinct (select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(u.location_id, 'zone_group', v_at)), ', ') filter (where u.is_member),
                    max((select zg.label from bi.zone_group zg where zg.code = l.rollup_zone)) filter (where not u.is_member)) zone,
           string_agg(distinct l.region, ', ') filter (where u.is_member) region,
           string_agg(l.label, ', ' order by l.label) filter (where u.is_member) member_labels,
           array_agg(u.location_id) filter (where u.is_member) locs,
           array_agg(distinct l.recon_unit) filter (where u.is_member and l.recon_unit is not null) units
    from um u left join bi.location l on l.id = u.location_id group by 1),
  pp as materialized (
    select s.pid, x.unit_id, x.fam,
           sum(x.billed) filter (where s.side = 'cur') a1, sum(x.billed) filter (where s.side = 'prev') a0,
           sum(x.expected) filter (where s.side = 'cur') e1, sum(x.expected) filter (where s.side = 'prev') e0,
           sum(x.cases) filter (where s.side = 'cur') c1, sum(x.cases) filter (where s.side = 'prev') c0,
           sum(o.org_billed) filter (where s.side = 'cur') o1, sum(o.org_billed) filter (where s.side = 'prev') o0,
           count(o.org_billed) filter (where s.side = 'cur') no1, count(o.org_billed) filter (where s.side = 'prev') no0,
           sum(o.org_expected) filter (where s.side = 'cur') oe1, sum(o.org_expected) filter (where s.side = 'prev') oe0,
           sum(x.settled) filter (where s.side = 'cur') s1, sum(x.open_b) filter (where s.side = 'cur') op1,
           sum(x.collected) filter (where s.side = 'cur') col1, sum(x.inv_n) filter (where s.side = 'cur') n1,
           sum(x.tds_l) filter (where s.side = 'cur') tds1
    from spec s join fx x on x.month = s.mon and x.unit_ok
    left join ox o on o.unit_id = x.unit_id and o.fam = x.fam and o.month = x.month
    group by 1, 2, 3),
  pp2 as materialized (
    select pp.*, a.ok, (pp.no1 = sc.nm and pp.no0 = sp.nm) cov
    from pp join avail a on a.pid = pp.pid join sides sc on sc.pid = pp.pid and sc.side = 'cur' join sides sp on sp.pid = pp.pid and sp.side = 'prev'),
  tot as materialized (
    select pid, sum(a1) a1, sum(a0) a0, sum(e1) e1, sum(e0) e0, sum(c1) c1, sum(c0) c0,
           sum(coalesce(a1, 0)) filter (where cov) a1c, sum(coalesce(a0, 0)) filter (where cov) a0c, sum(o1) filter (where cov) o1c, sum(o0) filter (where cov) o0c,
           sum(e1) filter (where cov) e1c, sum(e0) filter (where cov) e0c, sum(oe1) filter (where cov) oe1c, sum(oe0) filter (where cov) oe0c,
           sum(a1) filter (where a1 > 0 and a0 > 0) l1, sum(a0) filter (where a1 > 0 and a0 > 0) l0,
           count(*) filter (where coalesce(a0, 0) = 0 and a1 > 0) new_n, coalesce(sum(a1) filter (where coalesce(a0, 0) = 0 and a1 > 0), 0) new_a,
           count(*) filter (where coalesce(a1, 0) = 0 and a0 > 0) lost_n, coalesce(sum(a0) filter (where coalesce(a1, 0) = 0 and a0 > 0), 0) lost_a,
           count(*) filter (where coalesce(a1, 0) = 0 and coalesce(e1, 0) > 0) unbilled_n, coalesce(sum(e1) filter (where coalesce(a1, 0) = 0 and coalesce(e1, 0) > 0), 0) unbilled_e,
           sum(s1) s1, sum(op1) op1, sum(col1) col1, sum(n1) n1, sum(tds1) tds1, count(*) filter (where a1 > 0) pairs1, count(*) filter (where a0 > 0) pairs0
    from pp2 group by 1),
  card as materialized (
    select a.pid, case when a.ok then jsonb_build_object('id', a.pid, 'available', true, 'measure', 'revenue',
        'current', jsonb_build_object('label', a.cur_parts, 'billed', round(t.a1), 'expected', round(t.e1), 'cases', t.c1, 'invoices', t.n1,
                     'billed_per_case', round(t.a1 / nullif(t.c1, 0), 1), 'expected_per_case', round(t.e1 / nullif(t.c1, 0), 1),
                     'billing_coverage', round(t.a1 / nullif(t.e1, 0), 4), 'pairs', t.pairs1),
        'previous', jsonb_build_object('label', a.prev_parts, 'billed', round(t.a0), 'expected', round(t.e0), 'cases', t.c0,
                     'billed_per_case', round(t.a0 / nullif(t.c0, 0), 1), 'expected_per_case', round(t.e0 / nullif(t.c0, 0), 1),
                     'billing_coverage', round(t.a0 / nullif(t.e0, 0), 4), 'pairs', t.pairs0),
        'billed_change', round(coalesce(t.a1, 0) - coalesce(t.a0, 0)), 'billed_pct', bi.pct_chg(t.a1, t.a0, v_minr * a.nm),
        'expected_change', round(coalesce(t.e1, 0) - coalesce(t.e0, 0)), 'expected_pct', bi.pct_chg(t.e1, t.e0, v_minr * a.nm),
        'cases_change', coalesce(t.c1, 0) - coalesce(t.c0, 0), 'cases_pct', bi.pct_chg(t.c1, t.c0, 30 * a.nm),
        'billing_gap', round(coalesce(t.a1, 0) - coalesce(t.e1, 0)), 'billing_gap_pct', round((t.a1 - t.e1) / nullif(t.e1, 0), 4),
        'organic', jsonb_build_object(
            'covered_share', round(t.a1c / nullif(t.a1, 0), 4), 'covered_share_prev', round(t.a0c / nullif(t.a0, 0), 4),
            'actual_current', round(t.a1c), 'actual_previous', round(t.a0c), 'organic_current', round(t.o1c), 'organic_previous', round(t.o0c),
            'actual_growth', round(t.a1c - t.a0c), 'actual_growth_pct', bi.pct_chg(t.a1c, t.a0c, v_minr * a.nm),
            'organic_growth', round(t.o1c - t.o0c), 'organic_growth_pct', bi.pct_chg(t.o1c, t.o0c, v_minr * a.nm),
            'beyond_organic', round((t.a1c - t.a0c) - (t.o1c - t.o0c)),
            'beyond_organic_pct', round(((t.a1c - t.a0c) - (t.o1c - t.o0c)) / nullif(t.a0c, 0), 4),
            'effort_current', round(t.a1c - t.o1c), 'effort_previous', round(t.a0c - t.o0c),
            'effort_current_pct', bi.pct_chg(t.a1c, t.o1c, v_minr * a.nm), 'effort_previous_pct', bi.pct_chg(t.a0c, t.o0c, v_minr * a.nm),
            'effort_change', round((t.a1c - t.o1c) - (t.a0c - t.o0c)),
            'expected_min_organic_current', round(t.oe1c), 'expected_min_organic_previous', round(t.oe0c),
            'expected_min_current', round(t.e1c), 'expected_min_previous', round(t.e0c)),
        'like_for_like', jsonb_build_object('billed_current', round(t.l1), 'billed_previous', round(t.l0), 'billed_pct', bi.pct_chg(t.l1, t.l0, v_minr * a.nm)),
        'structure', jsonb_build_object('new_pairs', t.new_n, 'new_pair_billed', round(t.new_a), 'lost_pairs', t.lost_n, 'lost_pair_billed', round(t.lost_a),
                                        'not_billed_pairs', t.unbilled_n, 'not_billed_expected', round(t.unbilled_e)),
        'settlement', jsonb_build_object('invoiced', round(t.a1), 'settled', round(t.s1), 'open', round(t.op1), 'realisation', round(t.s1 / nullif(t.a1, 0), 4),
                                         'cash_allocated', round(t.col1), 'tds_in_ledger', round(t.tds1)),
        'complete', true)
      else jsonb_build_object('id', a.pid, 'available', false, 'measure', 'revenue',
        'reason', 'Not completely billed in the finance workbooks: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(a.missing) x) ||
                  '. Actual invoices are complete from ' || to_char(v_fc, 'Mon-YYYY') || ' to ' || to_char(v_lc, 'Mon-YYYY') ||
                  case when a.pid in ('yoy', 'qyoy', 'ytd') then '; a year-on-year comparison of invoices needs ' || to_char(v_fc + interval '12 months', 'Mon-YYYY') || ' onwards.' else '.' end,
        'current', jsonb_build_object('label', a.cur_parts), 'previous', jsonb_build_object('label', a.prev_parts),
        'benchmark', jsonb_build_object('note', 'Expected minimum revenue (Zonal Tracker) for the same periods — a benchmark, not invoiced revenue',
             'expected_current', round(t.e1), 'expected_previous', round(t.e0), 'expected_change', round(coalesce(t.e1, 0) - coalesce(t.e0, 0)),
             'expected_pct', bi.pct_chg(t.e1, t.e0, v_minr * a.nm), 'cases_current', t.c1, 'cases_previous', t.c0,
             'organic_expected_current', round(t.oe1c), 'organic_expected_previous', round(t.oe0c)))
      end j
    from avail a left join tot t on t.pid = a.pid),
  br as materialized (
    select um.unit_id, v.fam, count(*) verified, count(*) filter (where not v.website) matchable,
           count(*) filter (where not v.website and a.last_m >= v_cut) active6,
           count(*) filter (where not v.website and a.n is null) never
    from bi.branch_cov_mv v join um on um.location_id = v.location_id and um.is_member
    left join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm and not v.website
    where v.status = 'active' and v.vs in ('source_verified', 'admin_upload') group by 1, 2),
  peer as materialized (
    select v.location_id, v.fam, percentile_cont(0.5) within group (order by a.n3 / 3.0) med
    from bi.branch_cov_mv v join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm
    where v.status = 'active' and v.vs in ('source_verified', 'admin_upload') and not v.website and a.n3 > 0 and v.location_id is not null
    group by 1, 2 having count(*) >= 5),
  opp as materialized (
    select um.unit_id, v.fam, round(sum(pe.med)) opp
    from bi.branch_cov_mv v join um on um.location_id = v.location_id and um.is_member
    join peer pe on pe.location_id = v.location_id and pe.fam = v.fam
    left join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm
    where v.status = 'active' and v.vs in ('source_verified', 'admin_upload') and not v.website and a.n is null group by 1, 2),
  fu as materialized (
    select ua.unit_id, u.client_family fam,
           round(sum(u.matched_cases) filter (where u.case_data_available) / nullif(sum(u.tracker_cases) filter (where u.case_data_available), 0), 4) use1
    from ua join bi.v_force_usage u on u.recon_unit = any (ua.units) and u.month = v_bm group by 1, 2),
  tat as materialized (
    select um.unit_id, c.client_family fam,
           round((percentile_cont(0.5) within group (order by c.raw_tat_hours) filter (where c.tat_flag = 'valid'))::numeric, 1) med1,
           round(avg(case when c.sla_met then 1.0 when c.sla_met = false then 0 end), 4) sla1, count(*) n1
    from bi.v_case c join um on um.location_id = c.location_id and um.is_member where c.received_month = v_bm group by 1, 2),
  pr as materialized (
    select k.unit_id, k.fam, ua.label, ua.zl, ua.members, ua.owners, ua.owners_prev, ua.zone, ua.region, ua.member_labels,
           coalesce(fr.display_name, cl.label, k.fam) fam_label,
           max(k.a1) filter (where k.pid = 'mom') m_a1, max(k.a0) filter (where k.pid = 'mom') m_a0,
           max(k.e1) filter (where k.pid = 'mom') m_e1, max(k.e0) filter (where k.pid = 'mom') m_e0,
           max(k.c1) filter (where k.pid = 'mom') m_c1, max(k.c0) filter (where k.pid = 'mom') m_c0,
           max(k.s1) filter (where k.pid = 'mom') m_s1, max(k.op1) filter (where k.pid = 'mom') m_op1, max(k.col1) filter (where k.pid = 'mom') m_col1,
           jsonb_object_agg(k.pid, jsonb_build_object('cur', round(k.a1), 'prev', round(k.a0), 'chg', round(coalesce(k.a1, 0) - coalesce(k.a0, 0)),
               'pct', bi.pct_chg(k.a1, k.a0, v_minr * (select nm from avail where avail.pid = k.pid)),
               'exp_cur', round(k.e1), 'exp_prev', round(k.e0), 'exp_chg', round(coalesce(k.e1, 0) - coalesce(k.e0, 0)),
               'cases_cur', k.c1, 'cases_prev', k.c0,
               'org_cur', case when k.cov then round(k.o1) end, 'org_prev', case when k.cov then round(k.o0) end,
               'org_growth', case when k.cov then round(k.o1 - k.o0) end,
               'beyond', case when k.cov then round((coalesce(k.a1, 0) - coalesce(k.a0, 0)) - (k.o1 - k.o0)) end,
               'effort_cur', case when k.cov then round(coalesce(k.a1, 0) - k.o1) end, 'effort_prev', case when k.cov then round(coalesce(k.a0, 0) - k.o0) end,
               'effort_pct', case when k.cov then bi.pct_chg(k.a1, k.o1, v_minr) end))
             filter (where k.ok) per
    from pp2 k join ua on ua.unit_id = k.unit_id
      left join bi.client cl on cl.code = k.fam left join bi.client_family_research fr on fr.family = k.fam
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11),
  orgm as materialized (select o.unit_id, o.fam, o.basis, o.rpc, o.ref_months, o.ref_from, o.ref_to from ox o where o.month = v_bm),
  net as materialized (select sum(coalesce(m_a1, 0) - coalesce(m_a0, 0)) mom from pr),
  rows as materialized (
    select pr.*, om.basis org_basis, om.rpc org_rpc, om.ref_months, om.ref_from, om.ref_to,
           b2.verified, b2.matchable, b2.active6, b2.never, op.opp, fu.use1, ta.med1, ta.sla1, ta.n1
    from pr left join orgm om on om.unit_id = pr.unit_id and om.fam = pr.fam
      left join br b2 on b2.unit_id = pr.unit_id and b2.fam = pr.fam left join opp op on op.unit_id = pr.unit_id and op.fam = pr.fam
      left join fu on fu.unit_id = pr.unit_id and fu.fam = pr.fam left join tat ta on ta.unit_id = pr.unit_id and ta.fam = pr.fam
    where coalesce(pr.m_a1, 0) <> 0 or coalesce(pr.m_a0, 0) <> 0 or coalesce(pr.m_e1, 0) <> 0 or coalesce(pr.m_e0, 0) <> 0),
  grp as materialized (
    select case v_grp when 'client' then r.fam_label when 'unit' then r.label when 'zone' then coalesce(r.zone, '(no zone)')
                      when 'stakeholder' then coalesce(r.owners, '(not mapped)') when 'region' then coalesce(r.region, '(none)') end g,
           k.pid, sum(k.a1) a1, sum(k.a0) a0, sum(k.e1) e1, sum(k.e0) e0, sum(k.c1) c1, sum(k.c0) c0,
           sum(coalesce(k.a1, 0)) filter (where k.cov) a1c, sum(coalesce(k.a0, 0)) filter (where k.cov) a0c, sum(k.o1) filter (where k.cov) o1c, sum(k.o0) filter (where k.cov) o0c,
           count(*) n
    from rows r join pp2 k on k.unit_id = r.unit_id and k.fam = r.fam and k.ok
    where v_grp <> 'pair' group by 1, 2),
  trend as materialized (
    select g::date mon, bi.fin_month_status(g::date, b) st,
           (select sum(x.billed) from fx x where x.month = g::date and x.unit_ok) billed,
           (select sum(x.expected) from fx x where x.month = g::date and x.unit_ok) expected,
           (select sum(x.cases) from fx x where x.month = g::date and x.unit_ok) cases,
           (select sum(o.org_billed) from ox o where o.month = g::date) org_billed,
           (select count(*) filter (where o.org_billed is not null) from ox o where o.month = g::date) org_n,
           (select sum(o.org_expected) from ox o where o.month = g::date) org_expected,
           (select sum(x.settled) from fx x where x.month = g::date and x.unit_ok) settled,
           (select sum(x.collected) from fx x where x.month = g::date and x.unit_ok) collected
    from generate_series((v_cm - interval '11 months')::date, v_m, interval '1 month') g),
  split as materialized (
    select ua.label, round(sum(x.expected) filter (where x.month = v_bm)) expected, round(sum(x.billed) filter (where x.month = v_bm)) billed
    from fx x join ua on ua.unit_id = x.unit_id where x.unit_split group by 1)
  select jsonb_build_object(
    'available', true, 'measure', 'revenue', 'month', v_m, 'completed_month', v_cm, 'billing_month', v_bm,
    'billing_quarter', v_bq, 'billing_quarter_label', bi.fy_qlabel(v_bq), 'running_quarter_label', bi.fy_qlabel(v_qs),
    'billing', b, 'filters', f, 'group', v_grp, 'min_base', jsonb_build_object('revenue_per_month', v_minr),
    'cards', (select coalesce(jsonb_object_agg(pid, j), '{}') from card),
    'unavailable', (select coalesce(jsonb_agg(jsonb_build_object('id', c.pid, 'reason', c.j->>'reason')), '[]') from card c where not (c.j->>'available')::boolean)
                   || jsonb_build_array(jsonb_build_object('id', 'mtd', 'reason', 'Invoices for a month are raised at its end, so actual invoiced revenue has no month-to-date figure. Month to date is shown in Cases and as expected minimum revenue.')),
    'in_progress', (select coalesce(jsonb_agg(jsonb_build_object('month', t.mon, 'status', t.st, 'billed_so_far', round(t.billed), 'expected', round(t.expected),
                       'coverage', round(t.billed / nullif(t.expected, 0), 4),
                       'note', case when t.st = 'partial' then 'Invoices for ' || to_char(t.mon, 'Mon-YYYY') || ' are still being added: the snapshot (' || to_char((b->>'as_of')::date, 'DD-Mon') ||
                                    ') is less than ' || (b->>'complete_days') || ' days after the month end.' else 'Month not yet billed.' end) order by t.mon), '[]')
                   from trend t where t.mon > v_bm),
    'trend', (select jsonb_agg(jsonb_build_object('month', t.mon, 'status', t.st,
                 'billed', case when t.st in ('complete', 'partial') then round(t.billed) end, 'identified_incomplete', case when t.st = 'incomplete' then round(t.billed) end,
                 'expected', round(t.expected), 'cases', t.cases, 'organic_billed', case when t.org_n > 0 then round(t.org_billed) end, 'organic_expected', round(t.org_expected),
                 'billed_per_case', case when t.st = 'complete' then round(t.billed / nullif(t.cases, 0), 1) end,
                 'coverage', case when t.st in ('complete', 'partial') then round(t.billed / nullif(t.expected, 0), 4) end,
                 'realisation', case when t.st = 'complete' then round(t.settled / nullif(t.billed, 0), 4) end, 'cash_allocated', round(t.collected)) order by t.mon) from trend t),
    'organic', jsonb_build_object('validation', bi.fin_org_validation(f)),
    'net', (select jsonb_build_object('mom', round(mom)) from net),
    'not_in_totals', (select coalesce(jsonb_agg(jsonb_build_object('unit', s.label, 'expected', s.expected, 'billed', s.billed)), '[]') from split s),
    'groups', case when v_grp <> 'pair' then (select coalesce(jsonb_agg(jsonb_build_object('group', g.g, 'id', g.pid, 'cur', round(g.a1), 'prev', round(g.a0),
                  'chg', round(coalesce(g.a1, 0) - coalesce(g.a0, 0)), 'pct', bi.pct_chg(g.a1, g.a0, v_minr), 'exp_cur', round(g.e1), 'exp_prev', round(g.e0),
                  'cases_cur', g.c1, 'cases_prev', g.c0, 'org_cur', round(g.o1c), 'org_prev', round(g.o0c),
                  'beyond', round((g.a1c - g.a0c) - (g.o1c - g.o0c)), 'effort_cur', round(g.a1c - g.o1c), 'effort_prev', round(g.a0c - g.o0c),
                  'covered_cur', round(g.a1c), 'covered_prev', round(g.a0c), 'pairs', g.n) order by g.pid, coalesce(g.a1, 0) - coalesce(g.a0, 0) desc), '[]') from grp g) end,
    'pairs', (select coalesce(jsonb_agg(jsonb_build_object(
        'unit_id', r.unit_id, 'location', r.label, 'location_id', case when r.members = 1 then r.unit_id end, 'zone_level', r.zl, 'members', r.members, 'member_locations', r.member_labels,
        'zone', r.zone, 'region', r.region, 'client', r.fam, 'client_label', r.fam_label,
        'owner', r.owners, 'owner_changed', r.owners is distinct from r.owners_prev, 'owner_shared', position(',' in coalesce(r.owners, '')) > 0,
        'billed', round(r.m_a1), 'expected', round(r.m_e1), 'cases', r.m_c1,
        'billed_per_case', round(r.m_a1 / nullif(r.m_c1, 0), 1), 'expected_per_case', round(r.m_e1 / nullif(r.m_c1, 0), 1),
        'billing_coverage', round(r.m_a1 / nullif(r.m_e1, 0), 4),
        'settlement', jsonb_build_object('settled', round(r.m_s1), 'open', round(r.m_op1), 'realisation', round(r.m_s1 / nullif(r.m_a1, 0), 4), 'cash_allocated', round(r.m_col1)),
        'periods', r.per,
        'mom', r.per->'mom', 'qoq', r.per->'qoq', 'qtd', r.per->'qtd', 'yoy', r.per->'yoy',
        'share_of_net', round((coalesce(r.m_a1, 0) - coalesce(r.m_a0, 0)) / nullif(abs((select mom from net)), 0), 4),
        'organic', jsonb_build_object('basis', r.org_basis, 'billed_per_case_ref', r.org_rpc, 'ref_months', r.ref_months, 'ref_from', r.ref_from, 'ref_to', r.ref_to,
                                      'expected', (r.per->'mom'->>'org_cur')::numeric, 'effort', (r.per->'mom'->>'effort_cur')::numeric, 'effort_pct', (r.per->'mom'->>'effort_pct')::numeric,
                                      'status', case when (r.per->'mom'->>'org_cur')::numeric > 0 then
                                                       case when (r.per->'mom'->>'effort_cur')::numeric / (r.per->'mom'->>'org_cur')::numeric > 0.05 then 'above'
                                                            when (r.per->'mom'->>'effort_cur')::numeric / (r.per->'mom'->>'org_cur')::numeric < -0.05 then 'below' else 'in_line' end end),
        'branches', case when r.verified is not null then jsonb_build_object('verified', r.verified, 'matchable', r.matchable, 'active_6m', r.active6,
                            'coverage', round(r.active6::numeric / nullif(r.matchable, 0), 4), 'never_activated', r.never, 'indicative_cases_per_month', r.opp) end,
        'force1', jsonb_build_object('utilisation', r.use1, 'unit_level', true),
        'tat', jsonb_build_object('median_hours', r.med1, 'sla', r.sla1, 'cases', r.n1),
        'confidence', (select coalesce(jsonb_agg(w), '[]') from (
            select 'invoices for ' || r.members || ' locations are combined (invoices do not name the city)' w where r.zl and r.members > 1
            union all select 'no invoices identified for ' || to_char(v_bm, 'Mon-YY') || ' although the tracker shows ₹' || to_char(round(r.m_e1), 'FM99,99,99,999') || ' expected'
              where coalesce(r.m_a1, 0) = 0 and coalesce(r.m_e1, 0) > 0
            union all select 'invoiced ' || round(100 * r.m_a1 / r.m_e1) || '% of expected — invoices may sit under another location or client'
              where r.m_e1 > 0 and r.m_a1 > 0 and (r.m_a1 / r.m_e1 < 0.5 or r.m_a1 / r.m_e1 > 2)
            union all select 'small base (₹' || to_char(round(r.m_a0), 'FM99,99,99,999') || ' last month)' where coalesce(r.m_a0, 0) > 0 and r.m_a0 < v_minr
            union all select 'new this month' where coalesce(r.m_a0, 0) = 0 and coalesce(r.m_a1, 0) > 0
            union all select 'organic from the client''s Pan India billing ratio (fewer than 2 usable months for this pair)' where r.org_basis = 'family'
            union all select 'no organic revenue estimate' where coalesce(r.org_basis, 'unavailable') in ('unavailable', 'no organic cases') and coalesce(r.m_a1, 0) > 0
            union all select 'owners differ across the combined locations' where position(',' in coalesce(r.owners, '')) > 0
            union all select 'owner changed this month' where r.owners is distinct from r.owners_prev) z))
        order by abs(coalesce(r.m_a1, 0) - coalesce(r.m_a0, 0)) desc), '[]') from rows r),
    'method', jsonb_build_object(
      'actual', 'Actual invoiced revenue = invoice Basic (ex-GST) of every invoice identified for the invoice month, counted once: invoices still open or part-paid in the latest outstanding snapshot plus invoices quoted by receipts in the collection workbook. GST, TDS and cash are kept separately. It is invoiced revenue, not accounting-recognised revenue.',
      'complete', b->>'rule',
      'service_month', 'Invoices are dated at the end of the month they bill, and invoice-month revenue tracks the same month''s cases far better than the next or previous month''s (location × client correlation 0.92 vs 0.84 and 0.90, Apr–Aug 2026). Invoice month is therefore treated as the service month; per-case figures are approximate.',
      'units', 'Revenue is compared by billing unit × client. A billing unit is a location, or a whole zone where most invoices do not name the city (Gujarat, Bhopal MP, Lucknow / ROUP), so those locations cannot be ranked separately on revenue.',
      'expected', 'Expected minimum revenue = Zonal Tracker cases × rate. It is shown beside actual invoiced revenue as a benchmark and is never used in its place.',
      'organic', 'Organic invoiced revenue = organic cases (the existing business-as-usual case model) × invoiced revenue per case over the last three completely billed months before the month (months with a missing or one-off invoice pattern left out), adjusted for the month''s tracker rate. With fewer than two usable months for a pair, the client''s Pan India invoiced ÷ expected ratio is applied to the pair''s tracker rate.',
      'comparison', 'Actual growth = actual (current) − actual (comparison). Expected organic growth = organic (current) − organic (comparison). Growth beyond organic = actual growth − expected organic growth (= effort now − effort then). Organic totals cover only pairs with an organic estimate in every month of both periods; the covered share is shown.',
      'small_base', 'A change % is hidden when the comparison period has less than ₹25,000 per month; the absolute change is always shown. Missing data is never treated as zero for organic estimates.',
      'owner', 'Owner = stakeholders mapped to the unit''s locations at the end of the billing month. Mapped responsibility, not proof of cause.',
      'collections', 'Settled = the share of each invoice no longer open in the snapshot (ex-GST). Cash allocated = receipts quoting the invoices (GST-inclusive, after TDS). They use different bases and are never divided by each other.'))
  into res;
  return res;
end $fn$;

