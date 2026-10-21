-- Applied to Supabase project via MCP on 20261021114829
-- bi_090d (21-Oct-2026): Revenue & Collections API — outstanding position and ageing, receipts, realisation, revenue-to-cash flow,
-- revenue per case, smart alerts; admin-only review queue and invoice / receipt records.
-- Bases (stated in every response): outstanding and receipts are as recorded in the finance workbooks (gross of GST, after TDS);
-- revenue is the Zonal Tracker reported revenue (ex-GST); realisation and the flow compare like with like on the ex-GST invoice value.

create or replace function bi.api_collections(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare
  v_os bigint; v_asof date; v_osfile text; v_osbasis text; v_co bigint[]; v_thru date; v_cofile text;
  v_fam text := f->>'client_family'; v_locs int[]; v_zlocs int[]; v_b int[]; v_rules jsonb; v_credit int;
  v_fy date; v_rm_last date; v_rm_done date; v_rev_last date; v_months date[]; v_m3 date[];
  v_age jsonb; v_trend jsonb; v_byloc jsonb; v_bycl jsonb; v_flow jsonb; v_pc jsonb; v_alerts jsonb := '[]'::jsonb; v_rev jsonb;
  v_rev3 numeric; v_col3 numeric; v_osb numeric; v_ost numeric; v_o90 numeric; v_o180 numeric; v_un numeric; v_pre24 numeric;
  v_cm numeric; v_cp numeric; v_cfy numeric; v_lag numeric; v_rcopen numeric; v_rcopen_n int; v_dup numeric; v_unm numeric; v_unalloc numeric;
  v_realb numeric; v_reals numeric; v_moout numeric; v_x jsonb;
begin
  select id, as_of, file_name, as_of_basis into v_os, v_asof, v_osfile, v_osbasis from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select array_agg(id), max(as_of), (array_agg(file_name order by as_of desc))[1] into v_co, v_thru, v_cofile from bi.fin_upload where kind = 'collection' and status = 'committed';
  if v_os is null and v_co is null then
    return jsonb_build_object('available', false, 'message', 'No collection or outstanding workbook has been imported yet. An admin can add them in Admin → Upload.');
  end if;
  v_co := coalesce(v_co, '{}'::bigint[]); v_asof := coalesce(v_asof, v_thru); v_thru := coalesce(v_thru, v_asof);
  select array_agg(l.id) into v_locs from bi.location l where bi.fin_loc_ok(l.id, f);
  if coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb then v_locs := v_locs || 0; end if;
  select array_agg(l.id) into v_zlocs from bi.location l where not coalesce(l.is_rollup, false) and bi.loc_ok(l.id, l.recon_unit, f);
  v_b := (select array_agg(t.x::int order by t.o) from jsonb_array_elements_text((select value from bi.fin_config where key = 'ageing_buckets')) with ordinality t(x, o));
  v_rules := (select value from bi.fin_config where key = 'alert_rules');
  v_credit := (select (value #>> '{}')::int from bi.fin_config where key = 'credit_days' and jsonb_typeof(value) = 'number');
  v_rm_last := date_trunc('month', v_thru)::date;
  v_rm_done := case when v_thru = (v_rm_last + interval '1 month' - interval '1 day')::date then v_rm_last else (v_rm_last - interval '1 month')::date end;
  v_rev_last := (select max(h.month) from bi.zt_month_history h);
  v_fy := bi.fin_fy(v_thru);
  select array_agg(g::date order by g) into v_months from generate_series(v_fy, v_rm_last, interval '1 month') g;
  select array_agg(g::date order by g) into v_m3 from generate_series((least(v_rm_done, v_rev_last) - interval '2 month')::date, least(v_rm_done, v_rev_last), interval '1 month') g;

  -- ---------- outstanding position and ageing ----------
  with a as (select o.os, o.n, o.os_basic, o.dup_os, o.location_id, o.inv_month,
                    case when o.inv_month = date '1900-01-01' then null else v_asof - (o.inv_month + interval '1 month' - interval '1 day')::date end age_d
             from bi.fin_os_agg o where o.upload_id = v_os and o.location_id = any (v_locs) and (v_fam is null or o.family = v_fam) and o.n > 0),
       ab as (select a.*, case when a.age_d is null then 0 else coalesce((select min(i) from generate_subscripts(v_b, 1) i where a.age_d <= v_b[i]), array_length(v_b, 1) + 1) end bk from a),
       bs as (select ab.bk, sum(ab.os) os, sum(ab.n) n from ab group by 1)
  select coalesce((select sum(os) from a), 0), coalesce((select sum(os) from a where age_d > 90), 0), coalesce((select sum(os) from a where age_d > 180), 0),
         coalesce((select sum(os) from a where inv_month < date '2024-04-01' and inv_month > date '1900-01-01'), 0), coalesce((select sum(os_basic) from a), 0),
         coalesce((select sum(dup_os) from a), 0), coalesce((select sum(os) from a where location_id = 0), 0),
         (select coalesce(jsonb_agg(jsonb_build_object('bucket', case when g.i = 0 then 'Invoice month unknown' when g.i = 1 then '0–' || v_b[1] || ' days'
                                                                      when g.i <= array_length(v_b, 1) then (v_b[g.i - 1] + 1) || '–' || v_b[g.i] || ' days' else 'Over ' || v_b[g.i - 1] || ' days' end,
                                                     'from', case when g.i = 1 then 0 when g.i > 1 then v_b[g.i - 1] + 1 end, 'to', case when g.i between 1 and array_length(v_b, 1) then v_b[g.i] end,
                                                     'amount', round(coalesce(bs.os, 0)), 'invoices', coalesce(bs.n, 0)) order by g.i), '[]')
          from generate_series(0, array_length(v_b, 1) + 1) g(i) left join bs on bs.bk = g.i where g.i > 0 or bs.n > 0)
  into v_ost, v_o90, v_o180, v_pre24, v_osb, v_dup, v_unm, v_age;
  select coalesce(jsonb_agg(x || jsonb_build_object('share', case when v_ost <> 0 then round((x->>'amount')::numeric / v_ost, 4) end)), '[]') into v_age from jsonb_array_elements(v_age) x;
  v_un := case when v_fam is null then (select coalesce(sum(u.amount), 0) from bi.fin_unadj u where u.upload_id = v_os and u.location_id = any (v_locs)) end;

  -- ---------- receipts and reported revenue by month ----------
  with rc as (select r.rcpt_month mo, sum(r.amount) amt, sum(r.inv_amount) inv_amt from bi.fin_rcpt_agg r
              where r.upload_id = any (v_co) and r.location_id = any (v_locs) and (v_fam is null or r.family = v_fam) and r.n > 0 group by 1),
       rv as (select h.month mo, sum(h.revenue) rev, sum(h.cases) cases from bi.zt_month_history h left join bi.client c on c.code = h.client_code
              where h.location_id = any (v_zlocs) and (v_fam is null or c.family = v_fam) and h.month >= v_fy group by 1)
  select coalesce(jsonb_agg(jsonb_build_object('month', g.mo, 'revenue', round(rv.rev), 'cases', rv.cases, 'collected', round(rc.amt), 'against_invoices', round(rc.inv_amt),
                                               'unallocated', round(rc.amt - rc.inv_amt), 'partial', g.mo > v_rm_done,
                                               'cash_cover', case when rv.rev > 0 and g.mo <= v_rm_done then round(rc.amt / rv.rev, 3) end) order by g.mo), '[]'),
         sum(rv.rev) filter (where g.mo = any (v_m3)), sum(rc.amt) filter (where g.mo = any (v_m3)),
         sum(rc.amt) filter (where g.mo = v_rm_done), sum(rc.amt) filter (where g.mo = (v_rm_done - interval '1 month')::date), sum(rc.amt), sum(rc.amt - rc.inv_amt)
  into v_trend, v_rev3, v_col3, v_cm, v_cp, v_cfy, v_unalloc
  from unnest(v_months) g(mo) left join rc on rc.mo = g.mo left join rv on rv.mo = g.mo;

  select case when sum(r.lag_amount) > 0 then round(sum(r.lag_x_amount) / sum(r.lag_amount)) end, coalesce(sum(r.open_amount), 0), coalesce(sum(r.open_n), 0)::int
  into v_lag, v_rcopen, v_rcopen_n
  from bi.fin_rcpt_agg r where r.upload_id = any (v_co) and r.location_id = any (v_locs) and (v_fam is null or r.family = v_fam) and r.n > 0;
  v_moout := case when coalesce(v_rev3, 0) > 0 then round(v_osb / (v_rev3 / greatest(array_length(v_m3, 1), 1)), 2) end;

  -- ---------- realisation by invoice month (ex-GST): settled share of the invoice value identified for that month ----------
  with iv as (select i.inv_month mo, sum(i.basic) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n
              from bi.fin_inv_month i where i.location_id = any (v_locs) and (v_fam is null or i.family = v_fam) and i.inv_n > 0 and i.inv_month >= v_fy group by 1),
       rv as (select h.month mo, sum(h.revenue) rev from bi.zt_month_history h left join bi.client c on c.code = h.client_code
              where h.location_id = any (v_zlocs) and (v_fam is null or c.family = v_fam) and h.month >= v_fy group by 1),
       g as (select gg::date mo from generate_series(v_fy, (date_trunc('month', v_asof) - interval '1 month')::date, interval '1 month') gg)
  select coalesce(jsonb_agg(jsonb_build_object('month', g.mo, 'revenue', round(rv.rev), 'identified', round(iv.basic), 'settled', round(iv.settled), 'open', round(iv.open_b),
            'not_traced', case when rv.rev is not null then round(greatest(rv.rev - coalesce(iv.basic, 0), 0)) end,
            'realisation', case when iv.basic > 0 then round(iv.settled / iv.basic, 3) end, 'coverage', case when rv.rev > 0 then round(coalesce(iv.basic, 0) / rv.rev, 3) end,
            'invoices', iv.n, 'age_days', v_asof - (g.mo + interval '1 month' - interval '1 day')::date) order by g.mo), '[]'),
         sum(iv.basic) filter (where g.mo <= (date_trunc('month', v_asof) - interval '2 month')::date), sum(iv.settled) filter (where g.mo <= (date_trunc('month', v_asof) - interval '2 month')::date)
  into v_flow, v_realb, v_reals
  from g left join iv on iv.mo = g.mo left join rv on rv.mo = g.mo;

  -- ---------- revenue per case: reported, tracker rate, invoiced, collected (all ex-GST) ----------
  with rv as (select h.month mo, sum(h.revenue) rev, sum(h.cases) cases from bi.zt_month_history h left join bi.client c on c.code = h.client_code
              where h.location_id = any (v_zlocs) and (v_fam is null or c.family = v_fam) and h.month >= v_fy group by 1),
       snap as (select date_trunc('month', z.snapshot_date)::date mo, max(z.snapshot_date) sd from bi.zt_row z where z.row_type = 'leaf' and z.snapshot_date >= v_fy group by 1),
       rt as (select s.mo, sum(z.rate * z.mtd_cases) / nullif(sum(z.mtd_cases), 0) rate
              from snap s join bi.zt_row z on z.snapshot_date = s.sd and z.row_type = 'leaf' left join bi.client c on c.code = z.client_code
              where z.location_id = any (v_zlocs) and (v_fam is null or c.family = v_fam) and z.rate > 0 and z.mtd_cases > 0 group by 1),
       iv as (select i.inv_month mo, sum(i.basic) basic, sum(i.settled_basic) settled from bi.fin_inv_month i
              where i.location_id = any (v_locs) and (v_fam is null or i.family = v_fam) and i.inv_n > 0 group by 1)
  select coalesce(jsonb_agg(jsonb_build_object('month', rv.mo, 'cases', rv.cases, 'revenue_per_case', round(rv.rev / nullif(rv.cases, 0), 1), 'tracker_rate', round(rt.rate, 1),
            'invoiced_per_case', round(iv.basic / nullif(rv.cases, 0), 1), 'collected_per_case', round(iv.settled / nullif(rv.cases, 0), 1),
            'rate_gap', case when rt.rate > 0 and rv.cases > 0 then round((rv.rev / rv.cases - rt.rate) / rt.rate, 3) end,
            'billing_gap', case when rt.rate > 0 and rv.cases > 0 and iv.basic is not null then round((iv.basic / rv.cases - rt.rate) / rt.rate, 3) end) order by rv.mo), '[]')
  into v_pc from rv left join rt on rt.mo = rv.mo left join iv on iv.mo = rv.mo;

  -- ---------- by location ----------
  with o as (select a.location_id, sum(a.os) os, sum(a.os) filter (where a.inv_month > date '1900-01-01' and v_asof - (a.inv_month + interval '1 month' - interval '1 day')::date > 90) o90,
                    sum(a.os) filter (where a.inv_month > date '1900-01-01' and v_asof - (a.inv_month + interval '1 month' - interval '1 day')::date > 180) o180,
                    sum(a.os_basic) osb, sum(a.dup_os) dup
             from bi.fin_os_agg a where a.upload_id = v_os and a.location_id = any (v_locs) and (v_fam is null or a.family = v_fam) and a.n > 0 group by 1),
       u as (select x.location_id, sum(x.amount) un from bi.fin_unadj x where x.upload_id = v_os and x.location_id = any (v_locs) and v_fam is null group by 1),
       c as (select r.location_id, sum(r.amount) cfy, sum(r.amount) filter (where r.rcpt_month = any (v_m3)) c3, sum(r.amount) filter (where r.rcpt_month = v_rm_done) cm,
                    sum(r.open_amount) ro, case when sum(r.lag_amount) > 0 then round(sum(r.lag_x_amount) / sum(r.lag_amount)) end lagd
             from bi.fin_rcpt_agg r where r.upload_id = any (v_co) and r.location_id = any (v_locs) and (v_fam is null or r.family = v_fam) and r.n > 0 group by 1),
       rv as (select h.location_id, sum(h.revenue) filter (where h.month = any (v_m3)) r3 from bi.zt_month_history h left join bi.client cl on cl.code = h.client_code
              where h.location_id = any (v_zlocs) and (v_fam is null or cl.family = v_fam) group by 1),
       ids as (select o.location_id id from o union select u.location_id from u union select c.location_id from c)
  select coalesce(jsonb_agg(jsonb_build_object('location_id', ids.id, 'location', coalesce(l.label, 'Location not identified'), 'zone', coalesce(l.zone_group, l.rollup_zone),
            'zone_level', coalesce(l.is_rollup, false), 'outstanding', round(coalesce(o.os, 0)), 'over_90', round(coalesce(o.o90, 0)), 'over_180', round(coalesce(o.o180, 0)),
            'over_180_share', case when o.os > 0 then round(o.o180 / o.os, 3) end, 'unadjusted', round(u.un), 'net_receivable', round(coalesce(o.os, 0) - coalesce(u.un, 0)),
            'collected_fytd', round(c.cfy), 'collected_last_month', round(c.cm), 'revenue_3m', round(rv.r3), 'collected_3m', round(c.c3),
            'cash_cover_3m', case when rv.r3 > 0 then round(coalesce(c.c3, 0) / rv.r3, 3) end,
            'months_outstanding', case when rv.r3 > 0 then round(o.osb / (rv.r3 / greatest(array_length(v_m3, 1), 1)), 2) end,
            'avg_days_to_collect', c.lagd, 'receipts_not_in_ledger', round(coalesce(c.ro, 0)), 'possible_duplicates', round(coalesce(o.dup, 0)))
            order by coalesce(o.os, 0) desc), '[]')
  into v_byloc from ids left join o on o.location_id = ids.id left join u on u.location_id = ids.id left join c on c.location_id = ids.id
  left join rv on rv.location_id = ids.id left join bi.location l on l.id = ids.id;

  -- ---------- by client family ----------
  with o as (select a.family, sum(a.os) os, sum(a.os) filter (where a.inv_month > date '1900-01-01' and v_asof - (a.inv_month + interval '1 month' - interval '1 day')::date > 180) o180
             from bi.fin_os_agg a where a.upload_id = v_os and a.location_id = any (v_locs) and (v_fam is null or a.family = v_fam) and a.n > 0 group by 1),
       c as (select r.family, sum(r.amount) cfy, sum(r.amount) filter (where r.rcpt_month = any (v_m3)) c3 from bi.fin_rcpt_agg r
             where r.upload_id = any (v_co) and r.location_id = any (v_locs) and (v_fam is null or r.family = v_fam) and r.n > 0 group by 1),
       rv as (select coalesce(cl.family, 'OTHERS') family, sum(h.revenue) filter (where h.month = any (v_m3)) r3 from bi.zt_month_history h left join bi.client cl on cl.code = h.client_code
              where h.location_id = any (v_zlocs) and (v_fam is null or cl.family = v_fam) group by 1),
       ids as (select o.family from o union select c.family from c)
  select coalesce(jsonb_agg(jsonb_build_object('family', ids.family, 'outstanding', round(coalesce(o.os, 0)), 'over_180', round(coalesce(o.o180, 0)),
            'collected_fytd', round(c.cfy), 'collected_3m', round(c.c3), 'revenue_3m', round(rv.r3), 'cash_cover_3m', case when rv.r3 > 0 then round(coalesce(c.c3, 0) / rv.r3, 3) end)
            order by coalesce(o.os, 0) desc), '[]')
  into v_bycl from ids left join o on o.family = ids.family left join c on c.family = ids.family left join rv on rv.family = ids.family;

  -- ---------- smart alerts ----------
  if v_asof < current_date - coalesce((v_rules->>'os_stale_days')::int, 35) then
    v_alerts := v_alerts || jsonb_build_object('severity', 'warn', 'title', 'Outstanding snapshot is ' || (current_date - v_asof) || ' days old', 'detail', 'Latest ledger snapshot: ' || to_char(v_asof, 'DD-Mon-YYYY') || ' (' || v_osfile || ').', 'action', 'Upload the latest outstanding workbook.', 'owner', 'Finance');
  end if;
  if v_thru < current_date - coalesce((v_rules->>'rc_stale_days')::int, 20) then
    v_alerts := v_alerts || jsonb_build_object('severity', 'warn', 'title', 'Receipts are recorded only up to ' || to_char(v_thru, 'DD-Mon-YYYY'), 'detail', 'Collections after this date are not in the dashboard.', 'action', 'Upload the latest collection workbook.', 'owner', 'Finance');
  end if;
  if v_rev3 > 0 and v_col3 / v_rev3 < coalesce((v_rules->>'cash_ratio_min')::numeric, 0.6) then
    v_alerts := v_alerts || jsonb_build_object('severity', 'high', 'title', 'Cash received is ' || round(100 * v_col3 / v_rev3) || '% of reported revenue over ' || to_char(v_m3[1], 'Mon') || '–' || to_char(v_m3[array_length(v_m3, 1)], 'Mon YYYY'),
      'detail', 'Receipts ' || bi.fmt_inr(v_col3) || ' against revenue ' || bi.fmt_inr(v_rev3) || '. Receipts include GST net of TDS, so the like-for-like ratio is lower still.', 'metric', round(v_col3 / v_rev3, 3),
      'action', 'Review the locations with the lowest cash cover and the largest >90-day balances.', 'owner', 'Finance / zone heads');
  end if;
  if v_cp > 0 and (v_cp - v_cm) / v_cp > coalesce((v_rules->>'collection_drop')::numeric, 0.25) then
    v_alerts := v_alerts || jsonb_build_object('severity', 'warn', 'title', 'Collections fell ' || round(100 * (v_cp - v_cm) / v_cp) || '% in ' || to_char(v_rm_done, 'Mon YYYY'), 'detail', bi.fmt_inr(v_cm) || ' vs ' || bi.fmt_inr(v_cp) || ' the month before.', 'owner', 'Finance');
  end if;
  v_alerts := v_alerts || coalesce((select jsonb_agg(jsonb_build_object('severity', 'high', 'title', (q.x->>'location') || ': ' || round(100 * (q.x->>'over_180_share')::numeric) || '% of the balance is over 180 days',
              'detail', bi.fmt_inr((q.x->>'over_180')::numeric) || ' of ' || bi.fmt_inr((q.x->>'outstanding')::numeric) || ' outstanding.', 'location_id', (q.x->>'location_id')::int,
              'action', 'Agree a recovery or write-off review for invoices older than 180 days.', 'owner', 'Location head + Finance'))
     from (select x from jsonb_array_elements(v_byloc) x where (x->>'over_180_share')::numeric > coalesce((v_rules->>'over180_share')::numeric, 0.3)
           and (x->>'over_180')::numeric >= coalesce((v_rules->>'min_amount')::numeric, 100000) order by (x->>'over_180')::numeric desc limit 3) q), '[]'::jsonb);
  v_alerts := v_alerts || coalesce((select jsonb_agg(jsonb_build_object('severity', 'warn', 'title', (q.x->>'location') || ': unadjusted receipts are ' || round(100 * (q.x->>'unadjusted')::numeric / (q.x->>'outstanding')::numeric) || '% of the balance',
              'detail', bi.fmt_inr((q.x->>'unadjusted')::numeric) || ' received but not matched to invoices, so the open invoices overstate what is owed.', 'location_id', (q.x->>'location_id')::int,
              'action', 'Allocate the unadjusted receipts to invoices.', 'owner', 'Finance'))
     from (select x from jsonb_array_elements(v_byloc) x where (x->>'outstanding')::numeric > 0 and (x->>'unadjusted')::numeric / (x->>'outstanding')::numeric > coalesce((v_rules->>'unadj_share')::numeric, 0.2)
           and (x->>'unadjusted')::numeric >= coalesce((v_rules->>'min_amount')::numeric, 100000) order by (x->>'unadjusted')::numeric desc limit 3) q), '[]'::jsonb);
  if v_rcopen_n > 0 then
    v_alerts := v_alerts || jsonb_build_object('severity', 'warn', 'title', v_rcopen_n || ' receipts (' || bi.fmt_inr(v_rcopen) || ') are not reflected in the outstanding ledger',
      'detail', 'The bank ledger shows money received against these invoices, but the ' || to_char(v_asof, 'DD-Mon-YYYY') || ' snapshot still shows them fully unpaid.', 'action', 'Reconcile in Data Health → Finance review.', 'owner', 'Finance');
  end if;
  if v_dup > 0 then
    v_alerts := v_alerts || jsonb_build_object('severity', 'info', 'title', 'Possible double entries in the outstanding ledger: ' || bi.fmt_inr(v_dup), 'detail', 'The same invoice number appears more than once with identical amounts.', 'action', 'Check in Data Health → Finance review.', 'owner', 'Finance');
  end if;
  select x into v_x from jsonb_array_elements(v_pc) x where (x->>'month')::date = v_rev_last;
  if (v_x->>'rate_gap')::numeric < -coalesce((v_rules->>'rate_gap')::numeric, 0.1) then
    v_alerts := v_alerts || jsonb_build_object('severity', 'warn', 'title', 'Reported revenue per case is ' || round(-100 * (v_x->>'rate_gap')::numeric) || '% below the tracker rate in ' || to_char(v_rev_last, 'Mon YYYY'),
      'detail', '₹' || (v_x->>'revenue_per_case') || ' per case vs a case-weighted rate of ₹' || (v_x->>'tracker_rate') || '.', 'action', 'Check rates and revenue booking for the largest clients.', 'owner', 'Finance');
  end if;
  -- billing check on the latest month that is at least a month old: identified invoice value per case vs the tracker rate
  select x into v_x from jsonb_array_elements(v_pc) x where (x->>'month')::date = (date_trunc('month', v_asof) - interval '2 month')::date;
  if abs((v_x->>'billing_gap')::numeric) > coalesce((v_rules->>'rate_gap')::numeric, 0.1) then
    v_alerts := v_alerts || jsonb_build_object('severity', 'warn', 'title', 'Invoiced value per case is ' || round(abs(100 * (v_x->>'billing_gap')::numeric)) || '% ' ||
        case when (v_x->>'billing_gap')::numeric < 0 then 'below' else 'above' end || ' the tracker rate for ' || to_char((v_x->>'month')::date, 'Mon YYYY'),
      'detail', '₹' || (v_x->>'invoiced_per_case') || ' invoiced per case vs a case-weighted tracker rate of ₹' || (v_x->>'tracker_rate') || ' (ex-GST).',
      'action', 'Check for cases not yet billed or billed at a different rate.', 'owner', 'Finance');
  end if;
  if v_pre24 > 0 then
    v_alerts := v_alerts || jsonb_build_object('severity', 'info', 'title', bi.fmt_inr(v_pre24) || ' is still open on invoices raised before April 2024', 'detail', 'Kept in the outstanding balance as recorded.', 'action', 'Decide recovery or provisioning.', 'owner', 'Finance');
  end if;

  select jsonb_build_object('open', coalesce(sum(q.n), 0), 'by_kind', coalesce(jsonb_object_agg(q.kind, q.n), '{}'::jsonb))
  into v_rev from (select r.kind, count(*) n from bi.fin_review r where r.status = 'open' group by 1) q;

  return jsonb_build_object('available', true,
    'snapshot', jsonb_build_object('upload_id', v_os, 'file', v_osfile, 'as_of', v_asof, 'as_of_basis', v_osbasis),
    'receipts', jsonb_build_object('file', v_cofile, 'data_through', v_thru, 'last_complete_month', v_rm_done, 'partial_month', case when v_rm_last > v_rm_done then v_rm_last end),
    'revenue_last_month', v_rev_last, 'comparison_months', to_jsonb(v_m3),
    'kpi', jsonb_build_object('outstanding', round(v_ost), 'unadjusted', round(v_un), 'net_receivable', case when v_un is not null then round(v_ost - v_un) end,
       'over_90', round(v_o90), 'over_180', round(v_o180), 'over_180_share', case when v_ost > 0 then round(v_o180 / v_ost, 3) end, 'pre_apr_2024', round(v_pre24),
       'collected_last_month', round(v_cm), 'collected_prev_month', round(v_cp), 'collected_fytd', round(v_cfy), 'unallocated_fytd', round(v_unalloc),
       'revenue_3m', round(v_rev3), 'collected_3m', round(v_col3), 'cash_cover_3m', case when v_rev3 > 0 then round(v_col3 / v_rev3, 3) end,
       'realisation', case when v_realb > 0 then round(v_reals / v_realb, 3) end,
       'realisation_basis', 'Invoices raised ' || to_char(v_fy, 'Mon YYYY') || ' to ' || to_char(date_trunc('month', v_asof) - interval '2 month', 'Mon YYYY') || ' (at least a month old at the snapshot)',
       'months_outstanding', v_moout, 'avg_days_to_collect', v_lag, 'receipts_not_in_ledger', round(v_rcopen), 'receipts_not_in_ledger_n', v_rcopen_n,
       'possible_duplicates', round(v_dup), 'location_not_identified', round(v_unm), 'credit_days', v_credit),
    'ageing', v_age, 'trend', v_trend, 'flow', v_flow, 'per_case', v_pc, 'by_location', v_byloc, 'by_client', v_bycl, 'alerts', v_alerts, 'review', v_rev,
    'method', jsonb_build_object(
       'outstanding', 'Sum of "Actual Outstanding" on every invoice line of the latest outstanding workbook (gross of GST, after TDS and part-receipts). Snapshots are never added together.',
       'unadjusted', 'Receipts listed at the foot of each location sheet that are not yet matched to invoices. Net receivable = outstanding − unadjusted.',
       'ageing', 'Days from the last day of the invoice month (taken from the invoice number) to the snapshot date. Invoice dates in the workbooks are incomplete, so they are not used. Nothing is called overdue because payment terms are not recorded' || case when v_credit is not null then ' — terms set to ' || v_credit || ' days' else '' end || '.',
       'receipts', 'Bank-account sheets of the collection workbook (the "Main" sheet repeats April only and is used as a cross-check, never added).',
       'cash_cover', 'Cash received ÷ reported revenue for the same complete months. Receipts include GST and are after TDS; revenue excludes GST.',
       'realisation', 'Of the invoice value (ex-GST) identified for an invoice month, the share no longer open in the ledger snapshot. Invoices are identified from the ledger and from receipts that quote an invoice number; each invoice counted once.',
       'not_traced', 'Reported revenue for the month minus the invoice value identified for it (invoices paid without an invoice reference, or not yet billed).',
       'revenue_per_case', 'Reported revenue ÷ tracker cases; tracker rate = case-weighted rate on the month''s last tracker snapshot; invoiced and collected per case use the identified invoice value (ex-GST). Reported revenue is computed from the tracker rate, so the meaningful comparison is invoiced value per case against the rate (billing gap).'),
    'limitations', jsonb_build_array(
       'Outstanding as-of date: ' || to_char(v_asof, 'DD-Mon-YYYY') || coalesce(' — ' || v_osbasis, '') || '.',
       'Receipts without an invoice number (' || bi.fmt_inr(coalesce(v_unalloc, 0)) || ' this financial year) cannot be matched to invoices.',
       'Amounts mapped only to a zone (for example "Gujarat Zone") appear on a zone line, not a city.',
       'Collections before ' || to_char(v_fy, 'Mon YYYY') || ' are not in the imported workbook, so realisation for older invoice months is not measured.'));
end $function$;

create or replace function bi.api_fin_review(p jsonb) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $$
  select jsonb_build_object(
    'counts', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'status', status, 'n', n, 'amount', amt) order by kind, status), '[]')
               from (select kind, status, count(*) n, round(sum(amount)) amt from bi.fin_review group by 1, 2) q),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'severity', r.severity, 'title', r.title, 'amount', round(r.amount, 2), 'n', r.n,
                       'location', coalesce(l.label, case when r.location_id = 0 then 'Not identified' end), 'status', r.status, 'note', r.note, 'first_seen', r.first_seen, 'detail', r.detail)
                       order by abs(coalesce(r.amount, 0)) desc), '[]')
              from (select * from bi.fin_review where status = coalesce(p->>'status', 'open') and (p->>'kind' is null or kind = p->>'kind')
                    order by abs(coalesce(amount, 0)) desc limit least(coalesce((p->>'limit')::int, 200), 1000)) r
              left join bi.location l on l.id = r.location_id)) $$;

create or replace function bi.api_fin_records(p jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare v_os bigint; v_asof date; v_co bigint[]; lim int := least(coalesce((p->>'limit')::int, 200), 1000); r jsonb; lo int := (p->>'age_from')::int; hi int := (p->>'age_to')::int;
begin
  select id, as_of into v_os, v_asof from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select array_agg(id) into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  if coalesce(p->>'kind', 'outstanding') = 'outstanding' then
    select jsonb_build_object('as_of', v_asof, 'rows', coalesce(jsonb_agg(to_jsonb(x) order by x.open_amount desc), '[]')) into r from (
      select l.inv_key invoice, l.inv invoice_as_written, l.sheet, l.r sheet_row, coalesce(lo2.label, 'Not identified') location, l.family, l.cl client_as_written, l.br branch,
             l.im invoice_month, v_asof - (l.im + interval '1 month' - interval '1 day')::date age_days, l.basic, l.net, l.partial received, l.os open_amount, l.rk remark
      from bi.fin_os_lines(v_os) l left join bi.location lo2 on lo2.id = l.location_id
      where (p->>'location_id' is null or l.location_id = (p->>'location_id')::int) and (p->>'family' is null or l.family = p->>'family')
        and (p->>'invoice' is null or l.inv_key = bi.fin_inv_key(p->>'invoice')) and (p->>'inv_month' is null or l.im = (p->>'inv_month')::date)
        and (lo is null or v_asof - (l.im + interval '1 month' - interval '1 day')::date >= lo) and (hi is null or v_asof - (l.im + interval '1 month' - interval '1 day')::date <= hi)
      order by l.os desc limit lim) x;
  else
    select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(x) order by x.receipt_date desc nulls last), '[]')) into r from (
      select m.sheet bank_sheet, m.r sheet_row, m.d receipt_date, m.rm receipt_month, m.amt amount, coalesce(lo2.label, 'Not identified') location, m.family, m.inv_key invoice,
             m.inv invoice_as_written, m.im invoice_month, m.mstat ledger_status, m.lag days_after_invoice_month
      from bi.fin_rc_matched(v_os, coalesce(v_co, '{}'), coalesce(v_asof, current_date), 7) m left join bi.location lo2 on lo2.id = m.location_id
      where (p->>'location_id' is null or m.location_id = (p->>'location_id')::int) and (p->>'family' is null or m.family = p->>'family')
        and (p->>'invoice' is null or m.inv_key = bi.fin_inv_key(p->>'invoice')) and (p->>'rcpt_month' is null or m.rm = (p->>'rcpt_month')::date)
        and (p->>'status' is null or m.mstat = p->>'status')
      order by m.d desc nulls last limit lim) x;
  end if;
  return r;
end $function$;

create or replace function bi.fin_admin(p_actor text, p jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '120s' as $function$
declare op text := p->>'op'; d jsonb;
begin
  if op = 'review_set' then
    if p->>'status' not in ('open', 'accepted', 'resolved', 'ignored') then raise exception 'status must be open, accepted, resolved or ignored'; end if;
    update bi.fin_review set status = p->>'status', note = left(p->>'note', 500), resolved_by = p_actor, resolved_at = now() where id = (p->>'id')::bigint;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_review_set', 'fin_review', p->>'id', p);
    return jsonb_build_object('ok', true);
  elsif op = 'map_set' then
    if p->>'key_type' not in ('prefix', 'label', 'sheet') then raise exception 'key_type must be prefix, label or sheet'; end if;
    insert into bi.fin_loc_map (key_type, key, location_id, confidence, note, updated_by, updated_at)
    values (p->>'key_type', case when p->>'key_type' = 'prefix' then upper(btrim(p->>'key')) else bi.fin_label(p->>'key') end, nullif(p->>'location_id', '')::int,
            coalesce(p->>'confidence', 'high'), p->>'note', p_actor, now())
    on conflict (key_type, key) do update set location_id = excluded.location_id, confidence = excluded.confidence, note = excluded.note, updated_by = p_actor, updated_at = now();
  elsif op = 'client_map_set' then
    insert into bi.fin_client_map (key, family, note, updated_by, updated_at) values (bi.fin_label(p->>'key'), p->>'family', p->>'note', p_actor, now())
    on conflict (key) do update set family = excluded.family, note = excluded.note, updated_by = p_actor, updated_at = now();
  elsif op = 'config_set' then
    if p->>'key' not in (select key from bi.fin_config) then raise exception 'unknown setting %', p->>'key'; end if;
    update bi.fin_config set value = p->'value', updated_by = p_actor, updated_at = now() where key = p->>'key';
  elsif op = 'snapshot_date' then
    update bi.fin_upload set as_of = (p->>'as_of')::date, as_of_basis = 'Entered by ' || p_actor where id = (p->>'upload_id')::bigint and kind = 'outstanding';
  elsif op = 'derive' then null;
  else raise exception 'unknown op %', op;
  end if;
  insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_' || op, 'fin_admin', coalesce(p->>'key', p->>'upload_id', ''), p);
  d := bi.fin_derive(p_actor);
  return jsonb_build_object('ok', true, 'derive', d);
end $function$;
