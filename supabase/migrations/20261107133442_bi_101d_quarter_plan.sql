-- Applied to Supabase project via MCP on 20261107133442
-- Wave 101b (owner, 7-Nov-2026 18:39 IST): this-quarter and next-quarter plan vs actual, re-forecast as actuals arrive, delta,
-- shortfall, run-rate needed; revenue only. Plan = latest saved version (bi_101c); months before it use the tracker targets.
create or replace function bi.api_plan(p_month date, f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare r jsonb; v_ref date; v_share numeric; v_asof date; v_ver bigint; v_vname text; v_vat timestamptz; v_q0 date; v_anchor date;
        v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  f := coalesce(f, '{}'::jsonb);
  select x.month, (x.inputs->>'share_to_date')::numeric, x.as_of into v_ref, v_share, v_asof from bi.potential_run x order by x.run_id desc limit 1;
  select id, name, created_at into v_ver, v_vname, v_vat from bi.plan_version order by id desc limit 1;
  v_anchor := date_trunc('month', coalesce(p_month, v_today))::date;
  v_q0 := (date_trunc('quarter', v_anchor - interval '3 months') + interval '3 months')::date;   -- FY quarters: Apr, Jul, Oct, Jan
  with _m as materialized (
    select g::date as month, case when g::date < v_q0 + interval '3 months' then 'this' else 'next' end q,
           bi.workdays(g::date, (g::date + interval '1 month' - interval '1 day')::date) wd
      from generate_series(v_q0, v_q0 + interval '5 months', interval '1 month') g),
  -- actuals and tracker targets by team x client family
  _a as materialized (
    select v.month, coalesce(c.family, v.client_code) fam, v.location_id, sum(coalesce(v.revenue, 0)) actual, sum(v.revenue_target) tt, max(v.as_of) as_of
      from bi.v_month_business v left join bi.client c on c.code = v.client_code join bi.location l on l.id = v.location_id
     where v.month in (select month from _m) and bi.loc_ok(v.location_id, l.recon_unit, f, v.month) and bi.fam_ok(v.client_code, f)
     group by 1, 2, 3),
  -- plan rows (latest saved version) and re-forecast (current pace carried with month factors)
  _pl as materialized (
    select pt.month, pt.client_family fam, pt.location_id, coalesce(pt.zone_group, l.zone_group) zone_group, sum(pt.target) plan
      from bi.plan_target pt left join bi.location l on l.id = pt.location_id
     where pt.version_id = v_ver and pt.month in (select month from _m)
       and (f->>'client_family' is null or pt.client_family = f->>'client_family')
       and case when pt.location_id is not null then bi.loc_ok(pt.location_id, null, f)
                else f - 'client_family' = '{}'::jsonb or (f->>'location_id' is null and f->>'stakeholder' is null and (f->>'zone_group' is null or pt.zone_group = f->>'zone_group')) end
     group by 1, 2, 3, 4),
  _f as materialized (select pf.month, pf.factor from bi.plan_factors(v_ref, v_q0, (v_q0 + interval '5 months')::date) pf),
  _fc as materialized (
    select m.month, x.client_family fam, x.location_id, coalesce(x.zone_group, l.zone_group) zone_group, x.pace0 * ff.factor fc
      from _m m join _f ff on ff.month = m.month cross join bi.plan_cells() x left join bi.location l on l.id = x.location_id
     where m.month > v_ref and x.pace0 > 0
       and (f->>'client_family' is null or x.client_family = f->>'client_family')
       and case when x.location_id is not null then bi.loc_ok(x.location_id, null, f) else f - 'client_family' = '{}'::jsonb end),
  -- one row per month x team x client: plan (saved plan, else tracker target), actual, outlook
  k as (select month, fam, location_id from _a union select month, fam, location_id from _pl union select month, fam, location_id from _fc),
  j as (select k.month, k.fam, k.location_id, coalesce(l.zone_group, pl.zone_group, fc.zone_group) zone_group, coalesce(l.label, 'No team yet') location,
                 a.actual, a.tt, a.as_of, pl.plan, fc.fc
            from k left join _a a on a.month = k.month and a.fam = k.fam and a.location_id is not distinct from k.location_id
            left join _pl pl on pl.month = k.month and pl.fam = k.fam and pl.location_id is not distinct from k.location_id
            left join _fc fc on fc.month = k.month and fc.fam = k.fam and fc.location_id is not distinct from k.location_id
            left join bi.location l on l.id = k.location_id),
  _r as materialized (select j.*, m.q,
           case when j.plan is not null then 'plan' when j.tt is not null then 'tracker target' end plan_source,
           coalesce(j.plan, j.tt) plan_value,
           case when j.month < v_ref then 'actual' when j.month = v_ref then case when coalesce(v_share, 1) < 1 then 'actual + projection' else 'actual' end else 'forecast' end basis,
           case when j.month < v_ref then coalesce(j.actual, 0) when j.month = v_ref then coalesce(j.actual, 0) / coalesce(nullif(v_share, 0), 1) else coalesce(j.fc, 0) end outlook
      from j join _m m on m.month = j.month)
  select jsonb_build_object(
    'plan', case when v_ver is null then null else jsonb_build_object('version', v_ver, 'name', v_vname, 'saved_at', v_vat) end,
    'data_month', v_ref, 'data_as_of', v_asof, 'share_to_date', v_share,
    'months', (select jsonb_agg(jsonb_build_object('month', m.month, 'quarter', m.q, 'workdays', m.wd,
                  'plan', (select round(sum(plan_value)) from _r where _r.month = m.month),
                  'plan_source', (select string_agg(distinct plan_source, ' + ') from _r where _r.month = m.month and plan_source is not null),
                  'tracker_target', (select round(sum(tt)) from _r where _r.month = m.month),
                  'actual', (select round(sum(actual)) from _r where _r.month = m.month and _r.month <= v_ref),
                  'outlook', (select round(sum(outlook)) from _r where _r.month = m.month),
                  'basis', case when m.month < v_ref then 'actual' when m.month = v_ref then case when coalesce(v_share, 1) < 1 then 'actual to ' || to_char(v_asof, 'DD-Mon') || ' + projection' else 'actual' end else 'forecast at current pace' end,
                  'delta', (select round(sum(outlook) - sum(plan_value)) from _r where _r.month = m.month),
                  'shortfall', (select round(greatest(sum(plan_value) - sum(outlook), 0)) from _r where _r.month = m.month)) order by m.month) from _m m),
    'quarters', (select jsonb_agg(jsonb_build_object('quarter', q.q, 'from', q.f1, 'to', q.f2,
                  'label', 'Q' || (case when extract(month from q.f1) between 4 and 6 then 1 when extract(month from q.f1) between 7 and 9 then 2 when extract(month from q.f1) between 10 and 12 then 3 else 4 end)
                           || ' FY' || to_char(case when extract(month from q.f1) >= 4 then q.f1 + interval '1 year' else q.f1 end, 'YY'),
                  'plan', q.plan, 'actual_to_date', q.act, 'outlook', q.outlook, 'delta', q.outlook - q.plan, 'shortfall', greatest(q.plan - q.outlook, 0),
                  'remaining_workdays', q.rwd, 'needed_per_workday', case when q.rwd > 0 then round(greatest(q.plan - q.act, 0) / q.rwd) end,
                  'pace_per_workday', q.ppw,
                  'needed_vs_pace', case when q.rwd > 0 and q.ppw > 0 then round(greatest(q.plan - q.act, 0) / q.rwd / q.ppw - 1, 4) end) order by q.f1)
                 from (select m.q, min(m.month) f1, max(m.month) f2,
                              (select round(sum(plan_value)) from _r where _r.q = m.q) plan,
                              (select round(coalesce(sum(actual), 0)) from _r where _r.q = m.q and _r.month <= v_ref) act,
                              (select round(sum(outlook)) from _r where _r.q = m.q) outlook,
                              bi.workdays(greatest(min(m.month), coalesce(v_asof, v_ref) + 1), (max(m.month) + interval '1 month' - interval '1 day')::date) rwd,
                              (select round(sum(x.pace0) / nullif(bi.workdays(v_ref, (v_ref + interval '1 month' - interval '1 day')::date), 0))
                                 from bi.plan_cells() x where (f->>'client_family' is null or x.client_family = f->>'client_family')
                                  and case when x.location_id is not null then bi.loc_ok(x.location_id, null, f) else f - 'client_family' = '{}'::jsonb end) ppw
                         from _m m group by m.q) q),
    'by_zone', (select coalesce(jsonb_agg(o order by (o->>'plan_this')::numeric desc nulls last), '[]'::jsonb) from (
        select jsonb_build_object('zone_group', zone_group,
          'plan_this', round(sum(plan_value) filter (where q = 'this')), 'outlook_this', round(sum(outlook) filter (where q = 'this')),
          'delta_this', round(sum(outlook) filter (where q = 'this') - sum(plan_value) filter (where q = 'this')),
          'plan_next', round(sum(plan_value) filter (where q = 'next')), 'outlook_next', round(sum(outlook) filter (where q = 'next')),
          'delta_next', round(sum(outlook) filter (where q = 'next') - sum(plan_value) filter (where q = 'next'))) o
        from _r group by zone_group) z),
    'by_location', (select coalesce(jsonb_agg(o order by (o->>'plan_this')::numeric desc nulls last), '[]'::jsonb) from (
        select jsonb_build_object('location_id', location_id, 'location', location, 'zone_group', min(zone_group),
          'plan_this', round(sum(plan_value) filter (where q = 'this')), 'outlook_this', round(sum(outlook) filter (where q = 'this')),
          'delta_this', round(sum(outlook) filter (where q = 'this') - sum(plan_value) filter (where q = 'this')),
          'plan_next', round(sum(plan_value) filter (where q = 'next')), 'outlook_next', round(sum(outlook) filter (where q = 'next')),
          'delta_next', round(sum(outlook) filter (where q = 'next') - sum(plan_value) filter (where q = 'next'))) o
        from _r group by location_id, location) z),
    'by_client', (select coalesce(jsonb_agg(o order by (o->>'plan_this')::numeric desc nulls last), '[]'::jsonb) from (
        select jsonb_build_object('client_family', fam,
          'plan_this', round(sum(plan_value) filter (where q = 'this')), 'outlook_this', round(sum(outlook) filter (where q = 'this')),
          'delta_this', round(sum(outlook) filter (where q = 'this') - sum(plan_value) filter (where q = 'this')),
          'plan_next', round(sum(plan_value) filter (where q = 'next')), 'outlook_next', round(sum(outlook) filter (where q = 'next')),
          'delta_next', round(sum(outlook) filter (where q = 'next') - sum(plan_value) filter (where q = 'next'))) o
        from _r group by fam) z),
    'method', 'Plan = the saved plan (Admin → Plan & targets)' || case when v_ver is null then ' — none saved yet, so the tracker''s monthly targets are used where they exist' else ' for its months; months before it use the tracker''s monthly targets' end
      || '. Outlook = actual for completed months; for ' || to_char(v_ref, 'Mon-YY') || ' actual to ' || coalesce(to_char(v_asof, 'DD-Mon'), '?')
      || case when coalesce(v_share, 1) < 1 then ' ÷ ' || round(v_share * 100, 1) || '% (usual share of a month reached by that working day)' else '' end
      || '; later months = forecast at current pace (latest month per working day, seasonality and working days of each month) — it is recalculated every time a new tracker arrives, so actuals replace forecasts automatically. Delta = outlook − plan; shortfall = plan − outlook when positive. Needed per working day = (quarter plan − actual so far) ÷ working days left in the quarter; compared with the current pace per working day. Quarters follow the Indian financial year (Q1 Apr–Jun … Q4 Jan–Mar). Sources: bi.plan_target / bi.plan_version, bi.v_month_business, bi.potential_cell, bi.organic_si, bi.workdays.')
    into r;
  return r;
end $f$;

revoke all on function bi.api_plan(date, jsonb, jsonb) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('bi.call_compute(text, jsonb)'::regprocedure);
begin
  if position('''plan''' in d) = 0 then
    d := replace(d, 'when ''organic'' then', 'when ''plan'' then bi.api_plan(m, f, coalesce(p_args->''p'', ''{}''::jsonb))
      when ''organic'' then');
    execute d;
  end if;
end $m$;
