-- Applied to Supabase project via MCP on 20261014113630
create or replace function bi.api_organic(p_month date, f jsonb default '{}'::jsonb, p_group text default 'location', p_measure text default 'cases')
returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare m date := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date; asof date; complete boolean; k int; kk int; share numeric;
        grp text := case when p_group in ('location','client','zone','stakeholder','region','pair','total') then p_group else 'location' end;
        meas text := case when p_measure = 'revenue' then 'revenue' else 'cases' end; res jsonb; dstart date;
begin
  f := coalesce(f, '{}'::jsonb);
  asof := (select max(snapshot_date) from bi.zt_snapshot where report_month = m);
  complete := m < date_trunc('month', (select max(snapshot_date) from bi.zt_snapshot))::date;
  kk := bi.workdays(m, (m + interval '1 month - 1 day')::date);
  k := case when complete or asof is null then kk else bi.workdays(m, asof) end;
  share := case when complete then 1 else coalesce(bi.organic_share(m, k), round(k::numeric / kk, 4)) end;
  dstart := (select min(received_month) from bi.case_store);
  with op as (select o.*, l.recon_unit, l.region, l.label loc_label,
                     (select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(o.location_id, 'zone_group', coalesce(asof, m))) zone,
                     bi.loc_attr_at(o.location_id, 'stakeholder', coalesce(asof, m)) stakeholder,
                     coalesce(c.summary_under, o.client_code) client_grp, coalesce(pc.label, c.label, o.client_code) client_label,
                     coalesce((select z.rate from bi.zt_row z where z.row_type = 'leaf' and z.location_id = o.location_id and z.client_code = o.client_code and z.snapshot_date <= coalesce(asof, (m + interval '1 month - 1 day')::date)
                               order by z.snapshot_date desc limit 1), 0) rate
              from bi.organic_pairs(m) o join bi.location l on l.id = o.location_id left join bi.client c on c.code = o.client_code left join bi.client pc on pc.code = c.summary_under
              where bi.loc_ok(o.location_id, l.recon_unit, f, coalesce(asof, m)) and bi.fam_ok(o.client_code, f)),
  act as (select location_id, client_code, sum(case when meas = 'cases' then v else rv end) a from (
            select x.location_id, x.client_code, x.mtd_cases v, x.revenue_actual rv from bi.v_zt_leaf x where not complete and x.snapshot_date = asof
            union all select mb.location_id, mb.client_code, mb.cases, mb.revenue from bi.v_month_business mb where complete and mb.month = m) q group by 1, 2),
  j as (select op.*, coalesce(a.a, 0) actual, case when meas = 'cases' then op.organic else op.organic * op.rate end org,
               case grp when 'location' then op.loc_label when 'client' then op.client_label when 'zone' then coalesce(op.zone, '(no zone)') when 'stakeholder' then coalesce(op.stakeholder, '(none)')
                        when 'region' then coalesce(op.region, '(none)') when 'pair' then op.loc_label || ' · ' || coalesce(op.client_label, op.client_code) else 'Total' end g
        from op left join act a on a.location_id = op.location_id and a.client_code = op.client_code),
  gr as (select g, sum(actual) actual, sum(org) org, sum(org) * share org_td, count(*) n,
                sum(v1) v1, sum(v2) v2, sum(v3) v3, sum(organic) org_cases,
                max(wd1) wd1, max(wd2) wd2, max(wd3) wd3, max(wd) wd, max(si_t) si_t, max(si1) si1, max(si2) si2, max(si3) si3
         from j group by g),
  br as (select cs.client_code, upper(regexp_replace(cs.branch_code, '^0+', '')) bk, cs.location_id, cs.received_month, count(*) n
         from bi.case_store cs where nullif(cs.branch_code, '') is not null and cs.received_month between (m - interval '24 months')::date and m group by 1, 2, 3, 4),
  brm as (select b.client_code, b.bk, b.location_id, b.n,
                 (select min(b2.received_month) from br b2 where b2.client_code = b.client_code and b2.bk = b.bk) first_m,
                 exists (select 1 from br b3 where b3.client_code = b.client_code and b3.bk = b.bk and b3.received_month between (m - interval '3 months')::date and (m - interval '1 month')::date) recent
          from br b left join bi.location l on l.id = b.location_id
          where b.received_month = m and (b.location_id is null and f - 'client_family' = '{}'::jsonb or b.location_id is not null and bi.loc_ok(b.location_id, l.recon_unit, f, m)) and bi.fam_ok(b.client_code, f)),
  brs as (select count(*) filter (where first_m = m and m >= (dstart + interval '3 months')::date) new_branches, coalesce(sum(n) filter (where first_m = m and m >= (dstart + interval '3 months')::date), 0) new_cases,
                 count(*) filter (where first_m < m and not recent) reactivated_branches, coalesce(sum(n) filter (where first_m < m and not recent), 0) reactivated_cases,
                 count(*) filter (where recent) continuing_branches, coalesce(sum(n) filter (where recent), 0) continuing_cases, coalesce(sum(n), 0) force1_cases from brm),
  tot as (select sum(actual) actual, sum(org) org, sum(org) * share org_td, sum(v1) v1, sum(v2) v2, sum(v3) v3, max(wd1) wd1, max(wd2) wd2, max(wd3) wd3, max(wd) wd,
                 max(si_t) si_t, max(si1) si1, max(si2) si2, max(si3) si3, count(*) n from j)
  select jsonb_build_object(
    'month', m, 'as_of', asof, 'complete', complete, 'measure', meas, 'group', grp, 'filters', f,
    'workdays_elapsed', k, 'workdays_in_month', kk, 'share_to_date', share,
    'total', (select jsonb_build_object('actual', round(actual), 'organic_month', round(org), 'organic_to_date', round(org_td), 'effort_to_date', round(actual - org_td),
               'effort_pct', round((actual - org_td) / nullif(org_td, 0), 4), 'projected', case when not complete and share > 0 then round(actual / share) end,
               'projected_effort', case when not complete and share > 0 then round(actual / share - org) else round(actual - org) end,
               'inputs', jsonb_build_object('v1', v1, 'v2', v2, 'v3', v3, 'wd1', wd1, 'wd2', wd2, 'wd3', wd3, 'wd', wd, 'si', si_t, 'si1', si1, 'si2', si2, 'si3', si3, 'rows', n)) from tot),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('group', g, 'actual', round(actual), 'organic_month', round(org), 'organic_to_date', round(org_td),
               'effort', round(actual - org_td), 'effort_pct', round((actual - org_td) / nullif(org_td, 0), 4),
               'status', case when org_td <= 0 and actual > 0 then 'new' when org_td <= 0 then 'none' when (actual - org_td) / org_td > 0.05 then 'above' when (actual - org_td) / org_td < -0.05 then 'below' else 'in_line' end,
               'projected', case when not complete and share > 0 then round(actual / share) end,
               'inputs', jsonb_build_object('v1', v1, 'v2', v2, 'v3', v3, 'wd1', wd1, 'wd2', wd2, 'wd3', wd3, 'wd', wd, 'si', si_t, 'si1', si1, 'si2', si2, 'si3', si3, 'rows', n, 'organic_cases', round(org_cases)))
               order by actual - org_td), '[]') from gr),
    'branches', (select to_jsonb(brs) from brs),
    'months', jsonb_build_array(to_char((m - interval '3 months'), 'Mon-YY'), to_char((m - interval '2 months'), 'Mon-YY'), to_char((m - interval '1 month'), 'Mon-YY'), to_char(m, 'Mon-YY')),
    'method', jsonb_build_object(
      'formula', 'Organic = (0.7 × last month + 0.2 × the month before + 0.1 × three months back), each as cases per working day with the usual seasonal effect removed, × this month''s usual seasonal effect × this month''s working days.',
      'seasonal', 'Seasonal effect of a calendar month = its business per working day compared with the surrounding 12 months, averaged over the previous two years (Pan India).',
      'to_date', 'Organic to date = organic for the month × the share of a month''s business normally reached by this working day (' || round(share * 100, 1) || '% on working day ' || k || ' of ' || kk || ').',
      'effort', 'Effort = actual − organic. Above organic by more than 5% = effort growth; below by more than 5% = needs attention.',
      'revenue', 'Revenue view: organic cases × each row''s current rate.',
      'why', 'Chosen by testing six methods on Dec-2025 → Sep-2026: this one missed actual monthly business by 6.7% on average at Pan India level (location × client 21.5%). The previous rule — the higher of last-year growth × 3-month average and 3-month running growth × last month — overstated organic business by 25% on average, so it labelled normal months as under-performance.',
      'branches', 'Force1 branch activity is shown alongside: business from branches that started or came back this month is part of effort growth. It covers only locations with Force1 case files.'))
  into res;
  return res;
end $fn$;

create or replace function bi.api_organic_trend(f jsonb default '{}'::jsonb, p_months int default 12) returns jsonb language sql stable security definer set search_path to 'bi','public' as $fn$
  with last as (select (date_trunc('month', max(snapshot_date)) - interval '1 month')::date lc from bi.zt_snapshot),
  ms as (select (last.lc - make_interval(months => g))::date m from last, generate_series(0, greatest(1, least(coalesce(p_months, 12), 24)) - 1) g),
  o as (select ms.m, sum(op.organic) organic from ms cross join lateral bi.organic_pairs(ms.m) op join bi.location l on l.id = op.location_id
        where bi.loc_ok(op.location_id, l.recon_unit, coalesce(f, '{}'::jsonb), ms.m) and bi.fam_ok(op.client_code, coalesce(f, '{}'::jsonb)) group by 1),
  a as (select mb.month m, sum(mb.cases) actual from bi.v_month_business mb join bi.location l on l.id = mb.location_id join ms on ms.m = mb.month
        where bi.loc_ok(mb.location_id, l.recon_unit, coalesce(f, '{}'::jsonb), mb.month) and bi.fam_ok(mb.client_code, coalesce(f, '{}'::jsonb)) group by 1)
  select jsonb_build_object('months', coalesce(jsonb_agg(jsonb_build_object('month', ms.m, 'actual', a.actual, 'organic', round(o.organic), 'effort', round(a.actual - o.organic),
           'effort_pct', round((a.actual - o.organic) / nullif(o.organic, 0), 4)) order by ms.m), '[]'))
  from ms left join o on o.m = ms.m left join a on a.m = ms.m
$fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''organic''' in d) = 0 then
    d := replace(d, 'when ''branch_coverage'' then bi.api_branch_coverage(f)',
      'when ''branch_coverage'' then bi.api_branch_coverage(f)' || chr(10) ||
      '      when ''organic'' then bi.api_organic(m, f, coalesce(p_args->>''group'', ''location''), coalesce(p_args->>''measure'', ''cases''))' || chr(10) ||
      '      when ''organic_trend'' then bi.api_organic_trend(f, coalesce((p_args->>''months'')::int, 12))');
    if position('''organic''' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;
