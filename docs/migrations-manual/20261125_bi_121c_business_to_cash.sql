-- Wave 121c (25-Nov-2026): wave 119 stage C applied — business-to-cash (bi.api_b2c, bi_call 'b2c'). Reviewed from the proposal of 21-Nov
-- (supabase/proposals/2026-11-21_bi_119f_business_to_cash.sql). Change from the proposal: a location's case TAT / SLA is used only when tat_summary
-- marks it reliable (not 'unreliable' back-entered closures, not low sample); field TAT likewise; 'Location not identified' / '(no zone)' get no score or signals;
-- a client filter alone keeps receivables of every unit; a collection outlook (settlement curve by invoice age, cash pace); receivables, cash, unadjusted and TAT of a zone-billed unit's own location
-- (e.g. Lucknow / ROUP Zone) count under that unit, as its invoices do in bi.fin_rev_facts (the proposal joined members only, which put them under 'Location not identified'); an association weaker than 0.2 (or under 8 locations) has no direction; statement timeout 40 s. Additive; call_compute body saved in bi.fn_backup ('119f').
-- wave 119f (21-Nov-2026): business-to-cash — one SQL answer that puts business generation, operations, billing, settlement, cash and receivables side by
-- side for a comparable window, by location (billing unit), zone or client; with a health score whose components and weights are stated, the
-- associations between operational efficiency and financial results (rank correlation — association, not cause) and the signals of where business gets
-- stuck. Used by the Overview, the scorecards, the drill-downs and Ask Crux (bi_call 'b2c'). Read-only.
--
-- Window: the last N (default 3) months that are completely billed and whose month end is at least 30 days before the outstanding snapshot (so the
-- settlement of those invoices can be seen). Expected revenue and cases: tracker; billed: invoices by invoice month (register / traced, see D411);
-- settled and open: ex-GST against the outstanding snapshot; cash in the window: bank credits by receipt month (incl. GST, after TDS — never a revenue
-- figure); outstanding: latest snapshot, all ages, gross; unadjusted: latest unadjusted file; TAT / SLA: Force1 case TAT of the window's last month.
-- 121c: a computed figure shared between callers inside the database (same cache entry and key as bi_call): used for the Force1 TAT inside bi.api_b2c,
-- so the location, zone and client views and parallel Ask Crux look-ups do not each recompute it (6 s). A result of the current data version is used;
-- an older one only when computed in the last 6 hours and after the latest correction floor. Callers of the same figure wait for the first (advisory lock).
create or replace function bi.cached_compute(p_fn text, p_args jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $cc$
declare v_key text := md5(p_fn || '|' || coalesce(p_args::text, '')); v_ver bigint := bi.cache_version(); r jsonb; c_ver bigint; c_at timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext('cached_compute:' || v_key));
  select v, version, computed_at into r, c_ver, c_at from bi.api_cache where k = v_key;
  if r is not null and (c_ver = v_ver or (c_at > now() - interval '6 hours'
       and c_at >= (select coalesce(max(floor_at), '-infinity'::timestamptz) from bi.api_cache_floor))) then return r; end if;
  r := bi.call_compute(p_fn, p_args);
  if r is not null then
    begin perform set_config('lock_timeout', '1500ms', true);
      insert into bi.api_cache(k, v, version, fn, args) values (v_key, r, v_ver, p_fn, p_args)
      on conflict (k) do update set v = excluded.v, version = excluded.version, fn = excluded.fn, args = excluded.args, computed_at = now();
    exception when lock_not_available then null; end;
    perform set_config('lock_timeout', '0', true);
  end if;
  return r;
end $cc$;
revoke all on function bi.cached_compute(text, jsonb) from public, anon, authenticated;

create or replace function bi.api_b2c(m date, f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb) returns jsonb language plpgsql volatile security definer set search_path to 'bi', 'public' set statement_timeout to '40s' as $f$
declare b jsonb := bi.fin_billing_basis(); v_asof date; v_lc date; v_fc date; v_to date; v_from date; v_pto date; v_pfrom date; v_rthru date;
        v_n int := least(greatest(coalesce(nullif(p->>'months', '')::int, 3), 1), 6); v_group text := coalesce(nullif(p->>'group', ''), 'location');
        v_os bigint; v_ua bigint; v_ua_asof date; v_co bigint[]; v_tat jsonb; v_rows jsonb; v_tot jsonb; v_assoc jsonb; v_outlook jsonb; v_fam text := nullif(f->>'client_family', '');
        -- 121c: receivables, cash and unadjusted are limited to the filtered units only when a location filter is set (a client filter alone keeps every unit)
        v_nofilter boolean := not exists (select 1 from jsonb_each_text(coalesce(f, '{}'::jsonb) - 'client_family') e where nullif(e.value, '') is not null);
begin
  if v_group not in ('location', 'zone', 'client') then v_group := 'location'; end if;
  v_asof := (b->>'as_of')::date; v_lc := (b->>'last_complete')::date; v_fc := (b->>'first_complete')::date; v_rthru := (b->>'receipts_through')::date;
  if v_asof is null or v_lc is null then return jsonb_build_object('available', false, 'reason', 'No outstanding workbook or completely billed month yet.'); end if;
  v_to := (select max(g::date) from generate_series(v_fc, v_lc, interval '1 month') g where (g + interval '1 month' - interval '1 day')::date + 30 <= v_asof);
  if v_to is null then return jsonb_build_object('available', false, 'reason', 'No completely billed month is at least 30 days before the outstanding date.'); end if;
  v_from := greatest(v_fc, (v_to - make_interval(months => v_n - 1))::date);
  v_pto := (v_from - interval '1 month')::date; v_pfrom := (v_from - make_interval(months => (extract(year from age(v_to, v_from)) * 12 + extract(month from age(v_to, v_from)))::int + 1))::date;
  select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select id, as_of into v_ua, v_ua_asof from bi.fin_upload where kind = 'unadjusted' and status = 'committed' order by as_of desc, id desc limit 1;
  select coalesce(array_agg(id), '{}') into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  v_tat := bi.cached_compute('tat_summary', jsonb_build_object('month', v_to, 'filters', coalesce(f, '{}'::jsonb), 'group', case when v_group = 'client' then 'client' else 'location' end));   -- 121c: shared

  with um as materialized (select * from bi.fin_unit_map()),
  ul as materialized (select distinct um.unit_id, um.unit_label, um.zone_level, coalesce(l.rollup_zone, l.zone_group) zone from um join bi.location l on l.id = um.unit_id where um.unit_id > 0),
  fx as materialized (select * from bi.fin_rev_facts(v_from, v_to, coalesce(f, '{}'::jsonb), m) where unit_ok),
  fp as materialized (select * from bi.fin_rev_facts(v_pfrom, v_pto, coalesce(f, '{}'::jsonb), m) where unit_ok),
  units as materialized (select distinct unit_id from bi.fin_rev_facts(v_pfrom, v_to, coalesce(f, '{}'::jsonb) - 'client_family', m) where unit_ok and not v_nofilter),
  -- grouping key of a unit × client family
  kx as (select x.*, case v_group when 'client' then x.fam when 'zone' then coalesce(ul.zone, '(no zone)') else x.unit_id::text end gkey,
                case v_group when 'client' then coalesce(c.label, x.fam) when 'zone' then coalesce(ul.zone, '(no zone)') else coalesce(ul.unit_label, 'Location not identified') end glabel
           from fx x left join ul on ul.unit_id = x.unit_id left join lateral (select label from bi.client where family = x.fam order by code limit 1) c on true),
  kp as (select x.*, case v_group when 'client' then x.fam when 'zone' then coalesce(ul.zone, '(no zone)') else x.unit_id::text end gkey
           from fp x left join ul on ul.unit_id = x.unit_id),
  g as (select gkey, min(glabel) glabel, sum(coalesce(cases, 0)) cases, sum(coalesce(expected, 0)) expected, sum(coalesce(billed, 0)) billed,
               sum(coalesce(settled, 0)) settled, sum(coalesce(open_b, 0)) open_b, sum(coalesce(collected, 0)) cash_alloc, sum(coalesce(organic, 0)) organic,
               bool_or(unit_split) split
          from kx group by gkey),
  gp as (select gkey, sum(coalesce(cases, 0)) cases, sum(coalesce(expected, 0)) expected, sum(coalesce(billed, 0)) billed from kp group by gkey),
  -- receivables at the snapshot (gross), > 90 days, by unit × family
  os as (select coalesce(u.unit_id, 0) unit_id, a.family fam, sum(a.os) os, sum(a.os) filter (where (a.inv_month + interval '1 month' - interval '1 day')::date < v_asof - 90) os90
           from bi.fin_os_agg a left join um u on u.location_id = a.location_id
          where a.upload_id = v_os and a.n > 0 group by 1, 2),
  osg as (select case v_group when 'client' then o.fam when 'zone' then coalesce(ul.zone, '(no zone)') else o.unit_id::text end gkey, sum(o.os) os, sum(o.os90) os90
            from os o left join ul on ul.unit_id = o.unit_id where (v_nofilter or o.unit_id in (select unit_id from units)) and (v_fam is null or o.fam = v_fam) group by 1),
  -- cash received in the window (receipt months) and how fast invoices are paid
  rc as (select coalesce(u.unit_id, 0) unit_id, r.family fam, sum(r.amount) cash, sum(r.lag_x_amount) lx, sum(r.lag_amount) la
           from bi.fin_rcpt_agg r left join um u on u.location_id = r.location_id
          where r.upload_id = any (v_co) and r.rcpt_month between v_from and v_to and r.n > 0 group by 1, 2),
  rcg as (select case v_group when 'client' then r.fam when 'zone' then coalesce(ul.zone, '(no zone)') else r.unit_id::text end gkey, sum(r.cash) cash, sum(r.lx) lx, sum(r.la) la
            from rc r left join ul on ul.unit_id = r.unit_id where (v_nofilter or r.unit_id in (select unit_id from units)) and (v_fam is null or r.fam = v_fam) group by 1),
  -- unadjusted receipts (latest file) by unit
  ua as (select coalesce(u.unit_id, 0) unit_id, sum(t.amount) amt from bi.fin_unadj_txn t left join um u on u.location_id = t.location_id
          where t.upload_id = v_ua and t.n > 0 group by 1),
  uag as (select case v_group when 'zone' then coalesce(ul.zone, '(no zone)') else a.unit_id::text end gkey, sum(a.amt) amt
            from ua a left join ul on ul.unit_id = a.unit_id where v_group <> 'client' and (v_nofilter or a.unit_id in (select unit_id from units)) group by 1),
  -- case TAT and SLA of the window's last month (case-weighted mean of the medians of the locations in the group)
  -- wave 121c: a TAT that tat_summary marks unreliable (cases closed in Force1 after the work) or low-sample is left out, so it cannot score or flag
  tt as (select (x->>'id') id, nullif(x->'case'->>'n', '')::numeric n,
                case when coalesce(x->'case'->>'reliability', 'ok') = 'ok' and not coalesce((x->'case'->>'low_sample')::boolean, false) then nullif(x->'case'->>'median', '')::numeric end med,
                case when coalesce(x->'case'->>'reliability', 'ok') = 'ok' and not coalesce((x->'case'->>'low_sample')::boolean, false) then nullif(x->'case'->>'sla_met_pct', '')::numeric end sla,
                case when coalesce(x->'field'->>'reliability', 'ok') = 'ok' and not coalesce((x->'field'->>'low_sample')::boolean, false) then nullif(x->'field'->>'median', '')::numeric end fmed,
                case when not coalesce((x->'document'->>'low_sample')::boolean, false) then nullif(x->'document'->>'median', '')::numeric end dmed,
                nullif(x->'case'->>'open_past_due', '')::numeric late
           from jsonb_array_elements(case when jsonb_typeof(v_tat) = 'array' then v_tat else '[]'::jsonb end) x),
  ttk as (select case v_group when 'client' then coalesce((select family from bi.client c where c.code = tt.id), tt.id)
                              when 'zone' then case when u.unit_id is not null then coalesce(ul.zone, '(no zone)') end else u.unit_id::text end gkey, tt.*   -- 121c: Force1 locations outside the billing map are left out
            from tt left join um u on v_group <> 'client' and u.location_id::text = tt.id left join ul on ul.unit_id = u.unit_id),
  ttg as (select gkey, sum(n) tat_n, sum(med * n) / nullif(sum(n) filter (where med is not null), 0) tat, sum(sla * n) / nullif(sum(n) filter (where sla is not null), 0) sla,
                 sum(fmed * n) / nullif(sum(n) filter (where fmed is not null), 0) ftat, sum(dmed * n) / nullif(sum(n) filter (where dmed is not null), 0) dtat, sum(late) late
            from ttk where n > 0 and gkey is not null group by 1),
  -- 121c: a group with receivables or cash but no billing in the window (e.g. a client filter at a unit with only old invoices) still shows
  ky as (select gkey from g union select gkey from osg union select gkey from rcg),
  ga as (select ky.gkey, coalesce(g.glabel, case v_group when 'client' then coalesce((select c.label from bi.client c where c.family = ky.gkey order by c.code limit 1), ky.gkey)
                                                          when 'zone' then ky.gkey
                                                          else coalesce((select min(ul.unit_label) from ul where ul.unit_id::text = ky.gkey), 'Location not identified') end) glabel,
                coalesce(g.split, false) split, coalesce(g.cases, 0) cases, coalesce(g.expected, 0) expected, coalesce(g.billed, 0) billed, coalesce(g.settled, 0) settled,
                coalesce(g.open_b, 0) open_b, coalesce(g.cash_alloc, 0) cash_alloc, coalesce(g.organic, 0) organic
           from ky left join g on g.gkey = ky.gkey),
  j as materialized (
    select g.gkey, g.glabel, g.split, g.cases, g.expected, g.billed, g.settled, g.open_b, g.settled + g.open_b traced, g.cash_alloc, g.organic,
           gp.cases cases_prev, gp.expected expected_prev, gp.billed billed_prev, osg.os, osg.os90, rcg.cash, case when rcg.la > 0 then rcg.lx / rcg.la end days_to_collect,
           uag.amt unadj, ttg.tat, ttg.sla, ttg.ftat, ttg.dtat, ttg.tat_n, ttg.late,
           case when g.expected > 0 then g.billed / g.expected end bill_conv, case when g.settled + g.open_b > 0 then g.settled / (g.settled + g.open_b) end realisation,
           case when g.cases > 0 then g.expected / g.cases end exp_pc, case when g.cases > 0 then g.billed / g.cases end bill_pc, case when g.cases > 0 then g.settled / g.cases end settled_pc,
           case when osg.os > 0 then coalesce(osg.os90, 0) / osg.os end os90_share, case when gp.cases > 0 then g.cases / gp.cases - 1 end case_growth,
           case when gp.billed > 25000 then g.billed / gp.billed - 1 end billed_growth
      from ga g left join gp on gp.gkey = g.gkey left join osg on osg.gkey = g.gkey left join rcg on rcg.gkey = g.gkey left join uag on uag.gkey = g.gkey left join ttg on ttg.gkey = g.gkey
     where g.cases > 0 or g.billed > 0 or g.expected > 0 or coalesce(osg.os, 0) <> 0 or coalesce(rcg.cash, 0) <> 0),
  -- health score: percentile rank of each component among the groups that have it (0 = weakest, 100 = strongest); stated weights
  sc as (select j.gkey,
           100 * percent_rank() over (partition by (j.bill_conv is not null) order by least(j.bill_conv, 1.2)) r_bill,
           100 * percent_rank() over (partition by (j.realisation is not null) order by j.realisation) r_real,
           100 * percent_rank() over (partition by (j.os90_share is not null) order by - j.os90_share) r_age,
           100 * percent_rank() over (partition by (j.days_to_collect is not null) order by - j.days_to_collect) r_speed,
           100 * percent_rank() over (partition by (j.tat is not null) order by - j.tat) r_tat,
           100 * percent_rank() over (partition by (j.sla is not null) order by j.sla) r_sla,
           100 * percent_rank() over (partition by (j.case_growth is not null) order by j.case_growth) r_growth
         from j where (j.cases >= 50 or j.billed >= 100000) and j.gkey not in ('0', '(no zone)')),   -- 121c: 'Location not identified' / '(no zone)' is not scored
  sc2 as (select sc.gkey, sc.r_bill, sc.r_real, sc.r_age, sc.r_speed, sc.r_tat, sc.r_sla, sc.r_growth, j.bill_conv, j.realisation, j.os90_share, j.days_to_collect, j.tat, j.sla, j.case_growth
            from sc join j on j.gkey = sc.gkey),
  sc3 as (select gkey,
           (coalesce(case when bill_conv is not null then 20 * r_bill end, 0) + coalesce(case when realisation is not null then 20 * r_real end, 0) + coalesce(case when os90_share is not null then 20 * r_age end, 0)
            + coalesce(case when days_to_collect is not null then 10 * r_speed end, 0) + coalesce(case when tat is not null then 10 * r_tat end, 0) + coalesce(case when sla is not null then 10 * r_sla end, 0)
            + coalesce(case when case_growth is not null then 10 * r_growth end, 0))
           / nullif((case when bill_conv is not null then 20 else 0 end + case when realisation is not null then 20 else 0 end + case when os90_share is not null then 20 else 0 end
                     + case when days_to_collect is not null then 10 else 0 end + case when tat is not null then 10 else 0 end + case when sla is not null then 10 else 0 end
                     + case when case_growth is not null then 10 else 0 end), 0) score,
           (case when bill_conv is not null then 20 else 0 end + case when realisation is not null then 20 else 0 end + case when os90_share is not null then 20 else 0 end
            + case when days_to_collect is not null then 10 else 0 end + case when tat is not null then 10 else 0 end + case when sla is not null then 10 else 0 end
            + case when case_growth is not null then 10 else 0 end) weight_covered,
           r_bill, r_real, r_age, r_speed, r_tat, r_sla, r_growth
         from sc2),
  qs as (select percentile_cont(0.5) within group (order by cases) cases_med, percentile_cont(0.25) within group (order by bill_pc) bpc_q1, percentile_cont(0.75) within group (order by bill_pc) bpc_q3,
                percentile_cont(0.5) within group (order by tat) tat_med, percentile_cont(0.25) within group (order by realisation) real_q1
           from j where j.cases >= 50 and j.gkey not in ('0', '(no zone)'))
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', j.gkey, 'label', j.glabel, 'zone_billed', j.split, 'cases', round(j.cases), 'cases_prev', round(j.cases_prev), 'case_growth', round(j.case_growth, 3),
           'expected', round(j.expected), 'billed', round(j.billed), 'billed_prev', round(j.billed_prev), 'billed_growth', round(j.billed_growth, 3),
           'billing_gap', round(j.billed - j.expected), 'billing_conversion', round(j.bill_conv, 3),
           'expected_per_case', round(j.exp_pc, 1), 'billed_per_case', round(j.bill_pc, 1), 'settled_per_case', round(j.settled_pc, 1),
           'traced', round(j.traced), 'settled', round(j.settled), 'open', round(j.open_b), 'realisation', round(j.realisation, 3), 'cash_allocated', round(j.cash_alloc),
           'cash_in_window', round(j.cash), 'days_to_collect', round(j.days_to_collect), 'outstanding', round(j.os), 'outstanding_over_90', round(j.os90), 'over_90_share', round(j.os90_share, 3),
           'outstanding_per_case', case when j.cases > 0 and j.os is not null then round(j.os / (j.cases / greatest(v_n, 1)), 1) end,
           'unadjusted', round(j.unadj), 'case_tat_hours', round(j.tat, 1), 'field_tat_hours', round(j.ftat, 1), 'document_tat_hours', round(j.dtat, 1), 'sla_met', round(j.sla, 3),
           'open_past_due', j.late, 'organic_billed', round(j.organic),
           'health', case when s.score is not null then jsonb_build_object('score', round(s.score), 'weight_covered', s.weight_covered,
              'components', jsonb_build_object('billing_conversion', round(s.r_bill), 'realisation', round(s.r_real), 'receivable_age', round(s.r_age), 'collection_speed', round(s.r_speed),
                                               'case_tat', round(s.r_tat), 'sla', round(s.r_sla), 'growth', round(s.r_growth))) end,
           'signals', case when j.gkey in ('0', '(no zone)') then '[]'::jsonb else to_jsonb(array_remove(array[
              case when j.cases >= qs.cases_med and j.bill_pc <= qs.bpc_q1 then 'high volume, low billed revenue per case' end,
              case when j.cases < qs.cases_med and j.bill_pc >= qs.bpc_q3 then 'lower volume, high billed revenue per case' end,
              case when j.expected >= 100000 and j.bill_conv < 0.9 then 'billed below the expected minimum' end,
              case when j.expected >= 100000 and j.bill_conv > 1.2 then 'billed well above the expected minimum (rates or extra billing)' end,
              case when j.tat is not null and j.tat <= qs.tat_med and j.realisation <= qs.real_q1 then 'efficient operations, weak settlement' end,
              case when j.tat is not null and j.tat > qs.tat_med and j.cases >= qs.cases_med then 'high volume, slower case TAT' end,
              case when j.os90_share >= 0.5 and j.os >= 500000 then 'half or more of receivables over 90 days' end,
              case when j.case_growth > 0.1 and coalesce(j.billed_growth, 0) < 0 then 'business up, billing down' end], null)) end
         ) order by j.billed desc nulls last), '[]'::jsonb),
         jsonb_build_object('cases', round(sum(j.cases)), 'cases_prev', round(sum(j.cases_prev)), 'expected', round(sum(j.expected)), 'billed', round(sum(j.billed)), 'billed_prev', round(sum(j.billed_prev)),
           'traced', round(sum(j.traced)), 'settled', round(sum(j.settled)), 'open', round(sum(j.open_b)), 'cash_allocated', round(sum(j.cash_alloc)), 'cash_in_window', round(sum(j.cash)),
           'outstanding', round(sum(j.os)), 'outstanding_over_90', round(sum(j.os90)), 'unadjusted', round(sum(j.unadj)), 'organic_billed', round(sum(j.organic)),
           'billing_conversion', round(sum(j.billed) / nullif(sum(j.expected), 0), 3), 'realisation', round(sum(j.settled) / nullif(sum(j.traced), 0), 3),
           'expected_per_case', round(sum(j.expected) / nullif(sum(j.cases), 0), 1), 'billed_per_case', round(sum(j.billed) / nullif(sum(j.cases), 0), 1),
           'settled_per_case', round(sum(j.settled) / nullif(sum(j.cases), 0), 1), 'case_growth', round(sum(j.cases) / nullif(sum(j.cases_prev), 0) - 1, 3),
           'billed_growth', round(sum(j.billed) / nullif(sum(j.billed_prev), 0) - 1, 3),
           'billing_gap', round(sum(j.billed) - sum(j.expected)), 'billed_below_expected', round(sum(greatest(j.expected - j.billed, 0)) filter (where j.expected >= 100000)),
           'case_tat_hours', round(sum(j.tat * j.tat_n) / nullif(sum(j.tat_n) filter (where j.tat is not null), 0), 1), 'sla_met', round(sum(j.sla * j.tat_n) / nullif(sum(j.tat_n) filter (where j.sla is not null), 0), 3))
    into v_rows, v_tot
    from j left join sc3 s on s.gkey = j.gkey cross join qs;

  -- associations between operations and money across locations (Spearman: Pearson correlation of ranks); only locations with 100+ cases in the window
  if v_group = 'location' then
    with r as (select (x->>'cases')::numeric cs, nullif(x->>'case_tat_hours', '')::numeric tat, nullif(x->>'sla_met', '')::numeric sla, nullif(x->>'billed_per_case', '')::numeric bpc,
                      nullif(x->>'realisation', '')::numeric rl, nullif(x->>'billing_conversion', '')::numeric bc, nullif(x->>'case_growth', '')::numeric gr, nullif(x->>'over_90_share', '')::numeric o90,
                      nullif(x->>'field_tat_hours', '')::numeric ftat
                 from jsonb_array_elements(v_rows) x where (x->>'cases')::numeric >= 100 and x->>'key' <> '0'),
         pairs(code, label_x, label_y, xv, yv) as (
           select 'tat_vs_billed_per_case', 'case TAT', 'billed revenue per case', tat, bpc from r union all
           select 'tat_vs_realisation', 'case TAT', 'realisation', tat, rl from r union all
           select 'field_tat_vs_billed_per_case', 'field TAT', 'billed revenue per case', ftat, bpc from r union all
           select 'sla_vs_growth', 'SLA met', 'case growth', sla, gr from r union all
           select 'billing_conversion_vs_realisation', 'billing conversion', 'realisation', bc, rl from r union all
           select 'tat_vs_receivable_age', 'case TAT', 'share of receivables over 90 days', tat, o90 from r),
         rk as (select code, label_x, label_y, rank() over (partition by code order by xv) rx, rank() over (partition by code order by yv) ry from pairs where xv is not null and yv is not null),
         co as (select code, min(label_x) lx, min(label_y) ly, count(*) n, corr(rx, ry) rho from rk group by code)
    select coalesce(jsonb_agg(jsonb_build_object('code', code, 'x', lx, 'y', ly, 'n', n, 'rho', round(rho::numeric, 2),
             'strength', case when n < 8 or rho is null then 'too few locations' when abs(rho) < 0.2 then 'no clear association' when abs(rho) < 0.4 then 'weak'
                              when abs(rho) < 0.6 then 'moderate' else 'strong' end,
             'direction', case when n < 8 or abs(rho) < 0.2 then null when rho > 0 then 'higher ' || lx || ' goes with higher ' || ly when rho < 0 then 'higher ' || lx || ' goes with lower ' || ly end) order by abs(coalesce(rho, 0)) desc), '[]'::jsonb)
      into v_assoc from co;
  end if;

  -- 121c: collection outlook (wave 119 stage C). The settled share of each invoice month at the snapshot, read as a curve by age: an invoice month
  -- that is one month older has settled a further share of what was still open; applied to what each month still has open, that share estimates the
  -- settlement of the next ~30 days after the snapshot (ex-GST). Plus the pace of cash: the last 3 complete receipt months and the months of cash needed
  -- to clear the receivables at that pace. An estimate from one snapshot, labelled as such; invoices before the first completely billed month are not in it.
  with c as (select x.month, sum(x.billed) billed, sum(x.settled) settled, sum(x.open_b) open_b
               from bi.fin_rev_facts(v_fc, v_lc, coalesce(f, '{}'::jsonb), m) x where x.unit_ok group by 1),
       s as (select month, billed, settled, open_b, settled / nullif(settled + open_b, 0) sh, v_asof - (month + interval '1 month' - interval '1 day')::date age_days
               from c where settled + open_b > 0),
       h0 as (select s.*, (lead(sh) over (order by month desc) - sh) / nullif(1 - sh, 0) raw from s),
       h as (select h0.*, case when raw is not null then greatest(0, least(1, raw)) end hz0 from h0),   -- greatest / least skip nulls: keep a null a null
       h2 as (select h.*, coalesce(hz0, lag(hz0) over (order by month desc)) hz from h),
       un as (select distinct unit_id from bi.fin_rev_facts(v_pfrom, v_to, coalesce(f, '{}'::jsonb) - 'client_family', m) where unit_ok and not v_nofilter),
       rm as (select r.rcpt_month, sum(r.amount) amt from bi.fin_rcpt_agg r left join bi.fin_unit_map() u on u.location_id = r.location_id
               where r.upload_id = any (v_co) and r.n > 0 and r.rcpt_month < date_trunc('month', v_rthru + 1)::date and (v_fam is null or r.family = v_fam)
                 and (v_nofilter or coalesce(u.unit_id, 0) in (select unit_id from un))
               group by 1 order by 1 desc limit 3)
  select jsonb_build_object('snapshot', v_asof,
           'next_30_days_settlement', (select round(sum(open_b * hz)) from h2), 'open_in_estimate', (select round(sum(open_b)) from h2),
           'curve', (select jsonb_agg(jsonb_build_object('invoice_month', month, 'age_days', age_days, 'billed', round(billed), 'settled', round(settled), 'open', round(open_b),
                                     'settled_share', round(sh, 3), 'next_month_share_of_open', round(hz, 3)) order by month desc) from h2),
           'cash_last_months', (select jsonb_agg(jsonb_build_object('month', rcpt_month, 'cash', round(amt)) order by rcpt_month desc) from rm),
           'avg_monthly_cash', (select round(avg(amt)) from rm),
           'months_of_cash_to_clear_receivables', (select round((v_tot->>'outstanding')::numeric / nullif(avg(amt), 0), 1) from rm),
           'method', 'Settled share of each invoice month at the outstanding snapshot, read by age: the next older month shows what share of the still-open amount gets settled in about a month; that share × what each month still has open = the estimate (ex-GST). Cash pace = bank credits of the last complete receipt months (incl. GST).',
           'caveats', jsonb_build_array('An estimate from one snapshot (' || to_char(v_asof, 'DD-Mon-YYYY') || '): it assumes younger invoice months settle like older ones did; a new outstanding workbook replaces it.',
                                        'Invoices before ' || to_char(v_fc, 'Mon-YYYY') || ' are not in the estimate (their earlier payments are not in the receipts).',
                                        'Cash includes GST; the settlement estimate is ex-GST — they are not added together.'))
    into v_outlook;

  return jsonb_build_object('available', true, 'group', v_group,
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'months', (extract(year from age(v_to, v_from)) * 12 + extract(month from age(v_to, v_from)))::int + 1, 'previous_from', v_pfrom, 'previous_to', v_pto,
      'rule', 'Completely billed months whose month end is at least 30 days before the outstanding snapshot (' || to_char(v_asof, 'DD-Mon-YYYY') || '), so their settlement can be seen; the previous window has the same length.'),
    'basis', jsonb_build_object('outstanding_as_of', v_asof, 'receipts_through', v_rthru, 'unadjusted_as_of', v_ua_asof, 'sales_register', b->>'sales_file', 'sales_register_as_of', b->>'sales_as_of',
      'tat_month', v_to, 'billing_rule', b->>'rule'),
    'total', v_tot, 'rows', v_rows, 'associations', v_assoc, 'outlook', v_outlook,
    'stages', jsonb_build_array(
      jsonb_build_object('stage', 'cases', 'label', 'Cases generated', 'value', v_tot->'cases', 'unit', 'cases'),
      jsonb_build_object('stage', 'expected', 'label', 'Expected minimum revenue', 'value', v_tot->'expected', 'definition', 'Tracker cases × agreed rate (ex-GST); an expectation, not money billed.'),
      jsonb_build_object('stage', 'billed', 'label', 'Invoiced (billed)', 'value', v_tot->'billed', 'of_previous', v_tot->'billing_conversion', 'definition', 'Invoice basic value ex-GST by invoice month (≈ service month).'),
      jsonb_build_object('stage', 'settled', 'label', 'Settled', 'value', v_tot->'settled', 'of_previous', round(((v_tot->>'settled')::numeric / nullif((v_tot->>'billed')::numeric, 0)), 3),
                         'definition', 'Ex-GST value of those invoices no longer open in the outstanding snapshot (paid in full or in part).'),
      jsonb_build_object('stage', 'open', 'label', 'Still open', 'value', v_tot->'open', 'of_previous', round(((v_tot->>'open')::numeric / nullif((v_tot->>'billed')::numeric, 0)), 3),
                         'definition', 'Ex-GST value of those invoices still open at the snapshot.'),
      jsonb_build_object('stage', 'cash', 'label', 'Cash received in the window', 'value', v_tot->'cash_in_window', 'definition', 'Bank credits by receipt month (incl. GST, after TDS) — a cash-flow figure, not revenue of these months.')),
    'health_method', jsonb_build_object('weights', jsonb_build_object('billing_conversion', 20, 'realisation', 20, 'receivable_age', 20, 'collection_speed', 10, 'case_tat', 10, 'sla', 10, 'growth', 10),
      'why', 'Turning business into money carries 60 % (billing conversion, realisation, receivables not overdue — the three steps between work done and cash); speed of cash 10 %; delivery (case TAT, SLA) 20 %; growth 10 %. Each component is the percentile rank among the groups that have it (0 weakest, 100 strongest), so no arbitrary thresholds; a missing component is left out and the weights of the rest are scaled up (weight_covered shows how much was available). Groups with fewer than 50 cases and under ₹1 L billed are not scored.'),
    'notes', jsonb_build_array(
      'Invoice month is used as an approximation of the service month; per-case figures use the same months and units on both sides.',
      'Zone-billed units (invoices that do not name the city) are scored as one unit.',
      'Cash in the window is bank credits by receipt month and includes GST; it is never divided by ex-GST revenue.',
      'Associations are rank correlations across locations — they show which results move together, not what causes what.'));
end $f$;
revoke all on function bi.api_b2c(date, jsonb, jsonb) from public, anon, authenticated;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '119f');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  $r$      when 'fin_sources' then bi.api_fin_sources(f)   -- wave 119a$r$,
  $r$      when 'fin_sources' then bi.api_fin_sources(f)   -- wave 119a
      when 'b2c' then bi.api_b2c(m, f, coalesce(p_args->'p', '{}'::jsonb))   -- wave 119f$r$], array[1]);

-- 121c: definitions for the page hints and Ask Crux (explain_metric)
insert into bi.metric_doc(key, title, math, sources, api, updated_at) values
('business_to_cash', 'Business to cash',
 'Window = the last 3 completely billed months whose month end is at least 30 days before the outstanding snapshot (so their settlement can be seen); previous window = the same number of months before it. Stages: cases (Zonal Tracker) → expected minimum revenue (cases × agreed rate, ex-GST) → invoiced (invoice basic ex-GST by invoice month) → settled / still open (ex-GST value of those invoices no longer / still open in the outstanding snapshot) → cash received in the window (bank credits by receipt month, incl. GST, after TDS — a cash-flow figure, never divided by ex-GST revenue). Billing conversion = invoiced ÷ expected. Realisation = settled ÷ (settled + open). Receivables = latest outstanding snapshot, all ages, gross; over-90 share = invoices older than 90 days ÷ outstanding. Days to collect = amount-weighted days from invoice to receipt. Case TAT / SLA = Force1 case TAT of the window''s last month, only where Force1 timing is reliable. Associations = Spearman rank correlation across locations with 100+ cases (association, not cause).',
 '[{"name":"bi.fin_rev_facts","role":"cases, expected, invoiced, settled, open by billing unit × client"},{"name":"bi.fin_os_agg","role":"outstanding snapshot"},{"name":"bi.fin_rcpt_agg","role":"receipts and days to collect"},{"name":"bi.fin_unadj_txn","role":"unadjusted receipts"},{"name":"bi.tat_summary","role":"case TAT and SLA"}]'::jsonb,
 array['b2c'], now()),
('health_score', 'Business-to-cash health score',
 'Score 0–100 = weighted mean of percentile ranks among the groups (location, zone or client) that have each measure: billing conversion 20, realisation 20, receivables not over 90 days 20, collection speed (days to collect) 10, case TAT 10, SLA met 10, case growth vs the previous window 10. Turning work into money carries 60 (the three steps between work done and cash), speed of cash 10, delivery 20, growth 10. A missing measure is left out and the other weights are scaled up (weight covered shows how much was available). Groups with fewer than 50 cases and under ₹1 L invoiced, Location not identified and (no zone) are not scored. A rank compares groups with each other — 50 is the middle of the groups, not a pass mark.',
 '[{"name":"bi.api_b2c","role":"score, components and weights"}]'::jsonb, array['b2c'], now())
on conflict (key) do update set title = excluded.title, math = excluded.math, sources = excluded.sources, api = excluded.api, updated_at = now();
