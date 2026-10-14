-- Applied to Supabase project via MCP on 20261014114218
create or replace function bi.api_potential(p_month date, f jsonb default '{}'::jsonb, p_measure text default 'revenue', p_group text default 'location')
returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare m date := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date; me date; asof date; k int; kk int; rem int; share numeric;
        meas text := case when p_measure = 'cases' then 'cases' else 'revenue' end;
        grp text := case when p_group in ('location','zone','client','stakeholder','total') then p_group else 'location' end; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb); me := (m + interval '1 month - 1 day')::date;
  asof := (select max(snapshot_date) from bi.zt_snapshot where report_month = m);
  if asof is null then return jsonb_build_object('available', false, 'reason', 'No reports for this month yet'); end if;
  kk := bi.workdays(m, me); k := bi.workdays(m, asof);
  rem := greatest(0, bi.workdays(asof + 1, me) - (select count(*) from bi.report_calendar_exception e where e.report_date > asof and e.report_date <= me and extract(isodow from e.report_date) <> 7));
  with leaf as (select x.snapshot_date d, x.report_month mon, x.location_id, x.client_code, case when meas = 'cases' then x.mtd_cases else x.revenue_actual end v,
                       case when meas = 'cases' then x.target_cases else x.revenue_target end t
                from bi.v_zt_leaf x join bi.location l on l.id = x.location_id
                where x.report_month <= m and x.report_month >= (m - interval '12 months')::date and bi.loc_ok(x.location_id, l.recon_unit, f, x.snapshot_date) and bi.fam_ok(x.client_code, f)),
  gmap as (select distinct lf.location_id, lf.client_code,
             case grp when 'location' then l.label when 'zone' then coalesce((select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(lf.location_id, 'zone_group', asof)), '(no zone)')
                      when 'client' then coalesce(pc.label, c.label, lf.client_code) when 'stakeholder' then coalesce(bi.loc_attr_at(lf.location_id, 'stakeholder', asof), '(none)') else 'Pan India' end g
           from leaf lf join bi.location l on l.id = lf.location_id left join bi.client c on c.code = lf.client_code left join bi.client pc on pc.code = c.summary_under),
  snap as (select lf.mon, lf.d, gm.g, sum(lf.v) v, sum(lf.t) t, bi.workdays(lf.mon, lf.d) wk from leaf lf join gmap gm using (location_id, client_code) group by 1, 2, 3),
  fin as (select mb.month mon, gm.g, sum(case when meas = 'cases' then mb.cases else mb.revenue end) final
          from bi.v_month_business mb join gmap gm on gm.location_id = mb.location_id and gm.client_code = mb.client_code
          where mb.month < m and mb.month >= (m - interval '12 months')::date group by 1, 2),
  past as (select s.mon, s.g, (array_agg(s.v order by s.d desc))[1] v_k from snap s where s.mon < m and s.wk <= k group by 1, 2),
  mult as (select p.g, p.mon, f2.final / nullif(p.v_k, 0) mlt from past p join fin f2 on f2.mon = p.mon and f2.g = p.g where p.v_k > 0 and f2.final > 0),
  pmult as (select p.mon, sum(f2.final) / nullif(sum(p.v_k), 0) mlt from past p join fin f2 on f2.mon = p.mon and f2.g = p.g group by 1),
  pstats as (select percentile_cont(0.5) within group (order by mlt) med, min(mlt) lo, max(mlt) hi, count(*) n from pmult where mlt > 0),
  gstats as (select g, percentile_cont(0.5) within group (order by mlt) med, min(mlt) lo, max(mlt) hi, count(*) n from mult group by g),
  cur as (select g, max(v) filter (where d = asof) mtd, max(t) filter (where d = asof) tgt,
                 (array_agg(v order by d desc) filter (where extract(day from d) <= 10))[1] v10,
                 (array_agg(v order by d desc) filter (where extract(day from d) <= 20))[1] v20
          from snap where mon = m group by g),
  pace as (select g, (max(v) filter (where rn = 1) - max(v) filter (where rn = least(6, cnt))) / nullif(bi.workdays(max(d) filter (where rn = least(6, cnt)) + 1, max(d) filter (where rn = 1)), 0) per_day
           from (select g, d, v, row_number() over (partition by g order by d desc) rn, count(*) over (partition by g) cnt from snap where mon = m) z group by g),
  org as (select gm.g, sum(case when meas = 'cases' then o.organic else o.organic * coalesce((select z.rate from bi.zt_row z where z.row_type = 'leaf' and z.location_id = o.location_id and z.client_code = o.client_code and z.snapshot_date = asof limit 1), 0) end) organic
          from bi.organic_get(m) o join gmap gm on gm.location_id = o.location_id and gm.client_code = o.client_code group by 1),
  rows as (select c.g, c.mtd, c.tgt, c.v10, c.v20,
             case when gs.n >= 2 and c.mtd >= case when meas = 'cases' then 30 else 7500 end then gs.med else ps.med end mmed,
             case when gs.n >= 2 and c.mtd >= case when meas = 'cases' then 30 else 7500 end then gs.lo else ps.lo end mlo,
             case when gs.n >= 2 and c.mtd >= case when meas = 'cases' then 30 else 7500 end then gs.hi else ps.hi end mhi,
             case when gs.n >= 2 and c.mtd >= case when meas = 'cases' then 30 else 7500 end then 'own' else 'pan' end basis, coalesce(gs.n, 0) months_used,
             pc.per_day, og.organic
           from cur c left join gstats gs on gs.g = c.g cross join pstats ps left join pace pc on pc.g = c.g left join org og on og.g = c.g),
  outp as (select r.*, round(r.mtd * r.mmed) likely, round(r.mtd * r.mlo) low, round(r.mtd * r.mhi) high,
             round(greatest(coalesce(r.tgt, 0) - r.mtd, 0) / nullif(rem, 0)) required_per_day from rows r)
  select jsonb_build_object('available', true, 'month', m, 'as_of', asof, 'measure', meas, 'group', grp, 'filters', f,
    'workdays_elapsed', k, 'workdays_in_month', kk, 'workdays_left', rem,
    'pan', (select jsonb_build_object('median', round(med::numeric, 3), 'low', round(lo::numeric, 3), 'high', round(hi::numeric, 3), 'months', n) from pstats),
    'months_with_daily_reports', (select coalesce(jsonb_agg(to_char(mon, 'Mon-YY') order by mon), '[]') from pmult),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('group', g, 'mtd', round(mtd), 'target', round(tgt), 'day10', round(v10), 'day20', round(v20),
              'added_1_10', round(v10), 'added_11_20', case when v20 is not null and v10 is not null and extract(day from asof) > 10 then round(v20 - v10) end,
              'added_21_end', case when extract(day from asof) > 20 then round(mtd - coalesce(v20, 0)) end,
              'likely', likely, 'low', low, 'high', high, 'can_still_add', likely - round(mtd),
              'multiple', round(mmed::numeric, 3), 'multiple_low', round(mlo::numeric, 3), 'multiple_high', round(mhi::numeric, 3), 'basis', basis, 'months_used', months_used,
              'required_per_day', required_per_day, 'recent_per_day', round(per_day), 'organic', round(organic),
              'achievement_likely', round(likely / nullif(tgt, 0), 4),
              'status', case when tgt is null or tgt = 0 then 'no_target' when likely >= tgt then 'on_track' when required_per_day <= coalesce(per_day, 0) * 1.25 then 'stretch' else 'at_risk' end,
              'classic', case when v10 is not null and extract(day from asof) >= 10 then jsonb_build_object('x3_25', round(v10 * 3.25), 'x3_5', round(v10 * 3.5), 'x4', round(v10 * 4), 'x5', round(v10 * 5)) end)
              order by likely - coalesce(tgt, 0)), '[]') from outp),
    'method', jsonb_build_object(
      'likely', 'Likely month end = business so far × how much a month usually grows from this working day to month end (median of the past months with daily reports; low/high = the weakest and strongest of those months).',
      'basis', 'Own = this row''s own past months; Pan India = the overall pattern, used when the row has fewer than 2 past months or very small numbers.',
      'required', 'Required per day = (target − so far) ÷ working days left (Monday–Saturday minus declared holidays).',
      'status', 'On track = likely month end reaches the target; Stretch = the required daily pace is within 25% of the last five reports'' pace; At risk = needs more than that.',
      'classic', 'Classic options = business on the 10th × 3.25 / 3.5 / 4 / 5, the rule of thumb used in the earlier 10-day analysis, shown for comparison.',
      'organic', 'Organic = business-as-usual expectation for the full month (see the ? next to Organic).'))
  into res;
  return res;
end $fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''potential''' in d) = 0 then
    d := replace(d, 'when ''branch_coverage'' then bi.api_branch_coverage(f)',
      'when ''branch_coverage'' then bi.api_branch_coverage(f)' || chr(10) ||
      '      when ''potential'' then bi.api_potential(m, f, coalesce(p_args->>''measure'', ''revenue''), coalesce(p_args->>''group'', ''location''))');
    if position('''potential''' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;
