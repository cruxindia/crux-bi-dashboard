-- Applied to Supabase project via MCP on 20261107133042
-- Wave 101b (owner, 7-Nov-2026 18:39 IST): targets for the next X / Y / Z months from current pace, potential and
-- opportunity (revenue only). Quarter plan vs actual is in bi_101d.
-- Definitions (one each):
--   current pace (month k)  = the latest tracker month's revenue (projected to month end when incomplete) per working day,
--                             with the seasonal effect removed, x working days of month k x the seasonal effect of month k
--   potential               = the all-branch figure (bi.potential_cell, latest run), carried to month k the same way
--   opportunity             = potential − current pace
--   target (month k)        = (current pace + c_k x opportunity) x month factor, c_k ramping linearly to the chosen capture by
--                             the end of the horizon; growth from one month to the next kept between the minimum and maximum
--                             (seasonally adjusted by default, or in rupees). Each team x client gets pace + its share of the
--                             captured opportunity, so teams with no headroom are asked for their pace, not more.
-- The latest saved plan version is the plan (no flags to update).
create table if not exists bi.plan_version (
  id bigserial primary key, name text not null, params jsonb not null, ref_month date not null, ref_share numeric,
  first_month date not null, last_month date not null, created_by text not null, created_at timestamptz not null default now(),
  reason text not null, totals jsonb);
create table if not exists bi.plan_target (
  version_id bigint not null references bi.plan_version(id), month date not null, zone_group text, location_id int,
  client_family text not null, pace numeric, organic numeric, target numeric);
create index if not exists plan_target_v on bi.plan_target (version_id, month);
alter table bi.plan_version enable row level security;
alter table bi.plan_target enable row level security;

create or replace function bi.plan_month_factor(p_ref date, p_m date) returns numeric language sql stable security definer
set search_path to 'bi', 'public' as $f$
  select (bi.workdays(p_m, (p_m + interval '1 month' - interval '1 day')::date) * bi.organic_si(p_m))
       / nullif(bi.workdays(p_ref, (p_ref + interval '1 month' - interval '1 day')::date) * bi.organic_si(p_ref), 0) $f$;

-- the cells: zone x team x client family; pace0 = reference-month revenue (projected), organic = all-branch figure (potential)
create or replace function bi.plan_cells() returns table(zone_group text, location_id int, client_family text, pace0 numeric, organic numeric)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  select c.zone_group, c.location_id, c.client_family, coalesce(sum(c.revenue) filter (where c.layer = 'current'), 0), coalesce(sum(c.revenue), 0)
    from bi.potential_cell c where c.run_id = (select max(run_id) from bi.potential_run)
   group by 1, 2, 3 $f$;

create or replace function bi.plan_compute(p jsonb default '{}'::jsonb)
returns table(k int, month date, factor numeric, zone_group text, location_id int, client_family text, pace numeric, organic numeric, target numeric)
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare v_h int := least(greatest(coalesce((p->>'horizon')::int, 12), 1), 24);
        v_c numeric := least(greatest(coalesce((p->>'capture')::numeric, 0.30), 0), 1);
        v_gmin numeric := coalesce((p->>'gmin')::numeric, 0.02); v_gmax numeric := coalesce((p->>'gmax')::numeric, 0.12);
        v_basis text := coalesce(nullif(p->>'basis', ''), 'seasonal');
        v_ref date := (select r.month from bi.potential_run r order by r.run_id desc limit 1);
        v_pace0 numeric; v_opp numeric; a_prev numeric; t_prev numeric; a numeric; t numeric; f numeric; i int; m date; cc numeric[] := '{}';
begin
  if v_gmax < v_gmin then v_gmax := v_gmin; end if;
  select sum(x.pace0), sum(greatest(x.organic - x.pace0, 0)) into v_pace0, v_opp from bi.plan_cells() x;
  a_prev := v_pace0; t_prev := v_pace0;
  for i in 1 .. v_h loop
    m := (v_ref + make_interval(months => i))::date; f := bi.plan_month_factor(v_ref, m);
    a := v_pace0 + v_c * i::numeric / v_h * v_opp;
    if v_basis = 'nominal' then
      t := least(greatest(a * f, t_prev * (1 + v_gmin)), t_prev * (1 + v_gmax)); a := t / f;
    else
      a := least(greatest(a, a_prev * (1 + v_gmin)), a_prev * (1 + v_gmax)); t := a * f;
    end if;
    cc := cc || ((a - v_pace0) / nullif(v_opp, 0));
    a_prev := a; t_prev := t;
  end loop;
  return query
    select g.i, (v_ref + make_interval(months => g.i))::date, bi.plan_month_factor(v_ref, (v_ref + make_interval(months => g.i))::date),
           x.zone_group, x.location_id, x.client_family,
           x.pace0 * bi.plan_month_factor(v_ref, (v_ref + make_interval(months => g.i))::date),
           x.organic * bi.plan_month_factor(v_ref, (v_ref + make_interval(months => g.i))::date),
           (x.pace0 + coalesce(cc[g.i], 0) * greatest(x.organic - x.pace0, 0)) * bi.plan_month_factor(v_ref, (v_ref + make_interval(months => g.i))::date)
      from generate_series(1, v_h) g(i) cross join bi.plan_cells() x;
end $f$;

-- preview / view of targets (any filter); milestones X / Y / Z
create or replace function bi.api_targets(p_month date, f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare r jsonb; v_ref date; v_share numeric; v_ms int[]; v_src text := coalesce(nullif(p->>'source', ''), 'preview'); v_ver bigint; v_params jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  select x.month, (x.inputs->>'share_to_date')::numeric into v_ref, v_share from bi.potential_run x order by x.run_id desc limit 1;
  if v_src = 'plan' then
    select id, params into v_ver, v_params from bi.plan_version order by id desc limit 1;
    if v_ver is null then return jsonb_build_object('error', 'no plan saved yet'); end if;
  else v_params := p; end if;
  v_ms := coalesce((select array_agg(x.value::int order by x.value::int) from jsonb_array_elements_text(coalesce(v_params->'milestones', '[3,6,12]'::jsonb)) x), array[3,6,12]);
  with t as materialized (
    select c.k, c.month, c.factor, coalesce(c.zone_group, l.zone_group) zone_group, c.location_id, coalesce(l.label, 'No team yet') location, c.client_family, c.pace, c.organic, c.target
      from (select * from bi.plan_compute(v_params) where v_src <> 'plan'
            union all
            select (extract(year from age(pt.month, v_ref)) * 12 + extract(month from age(pt.month, v_ref)))::int, pt.month, bi.plan_month_factor(v_ref, pt.month),
                   pt.zone_group, pt.location_id, pt.client_family, pt.pace, pt.organic, pt.target
              from bi.plan_target pt where v_src = 'plan' and pt.version_id = v_ver) c
      left join bi.location l on l.id = c.location_id
     where (f->>'client_family' is null or c.client_family = f->>'client_family')
       and case when c.location_id is not null then bi.loc_ok(c.location_id, null, f)
                else f - 'client_family' = '{}'::jsonb or (f->>'location_id' is null and f->>'stakeholder' is null and (f->>'zone_group' is null or c.zone_group = f->>'zone_group')) end)
  select jsonb_build_object(
    'source', v_src, 'version', v_ver, 'params', v_params, 'reference_month', v_ref, 'reference_share', v_share,
    'reference', (select jsonb_build_object('pace', round(sum(x.pace0)), 'organic', round(sum(x.organic)), 'opportunity', round(sum(greatest(x.organic - x.pace0, 0))))
                    from bi.plan_cells() x left join bi.location l on l.id = x.location_id
                   where (f->>'client_family' is null or x.client_family = f->>'client_family')
                     and case when x.location_id is not null then bi.loc_ok(x.location_id, null, f)
                              else f - 'client_family' = '{}'::jsonb or (f->>'location_id' is null and f->>'stakeholder' is null and (f->>'zone_group' is null or x.zone_group = f->>'zone_group')) end),
    'months', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'month', month, 'factor', round(factor, 4), 'pace', round(pace), 'target', round(target),
                 'organic', round(organic), 'opportunity', round(organic - pace), 'stretch', round(target / nullif(pace, 0) - 1, 4)) order by k), '[]'::jsonb)
               from (select k, month, max(factor) factor, sum(pace) pace, sum(target) target, sum(organic) organic from t group by k, month) q),
    'milestones', (select coalesce(jsonb_agg(jsonb_build_object('months', ms, 'month', (v_ref + make_interval(months => ms))::date,
                 'monthly_target', (select round(sum(target)) from t where k = ms), 'monthly_pace', (select round(sum(pace)) from t where k = ms),
                 'cumulative_target', (select round(sum(target)) from t where k <= ms), 'cumulative_pace', (select round(sum(pace)) from t where k <= ms),
                 'growth_vs_reference', (select round(sum(target) / nullif((select sum(x.pace0) from bi.plan_cells() x), 0) - 1, 4) from t where k = ms)) order by ms), '[]'::jsonb)
                   from unnest(v_ms) ms where ms <= (select max(k) from t)),
    'by_zone', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', zone_group, 'targets', t, 'pace', pc, 'total_target', tt, 'total_pace', tp, 'organic_month1', om) order by tt desc), '[]'::jsonb)
                from (select zone_group, jsonb_agg(round(target) order by k) t, jsonb_agg(round(pace) order by k) pc, round(sum(target)) tt, round(sum(pace)) tp,
                             round(sum(organic) filter (where k = 1)) om
                        from (select zone_group, k, sum(target) target, sum(pace) pace, sum(organic) organic from t group by 1, 2) z group by zone_group) q),
    'by_location', (select coalesce(jsonb_agg(jsonb_build_object('location_id', location_id, 'location', location, 'zone_group', zone_group, 'targets', t, 'pace', pc, 'total_target', tt, 'total_pace', tp, 'organic_month1', om) order by tt desc), '[]'::jsonb)
                from (select location_id, location, zone_group, jsonb_agg(round(target) order by k) t, jsonb_agg(round(pace) order by k) pc, round(sum(target)) tt, round(sum(pace)) tp,
                             round(sum(organic) filter (where k = 1)) om
                        from (select location_id, location, zone_group, k, sum(target) target, sum(pace) pace, sum(organic) organic from t group by 1, 2, 3, 4) z group by location_id, location, zone_group) q),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_family', client_family, 'targets', t, 'pace', pc, 'total_target', tt, 'total_pace', tp, 'organic_month1', om) order by tt desc), '[]'::jsonb)
                from (select client_family, jsonb_agg(round(target) order by k) t, jsonb_agg(round(pace) order by k) pc, round(sum(target)) tt, round(sum(pace)) tp,
                             round(sum(organic) filter (where k = 1)) om
                        from (select client_family, k, sum(target) target, sum(pace) pace, sum(organic) organic from t group by 1, 2) z group by client_family) q),
    'method', 'Current pace = ' || to_char(v_ref, 'Mon-YY') || ' revenue' || case when coalesce(v_share, 1) < 1 then ' projected to month end (÷ ' || round(v_share * 100, 1) || '%, the usual share reached by that working day)' else '' end
      || ' per working day with the seasonal effect removed, carried to each month with its working days and seasonal effect. Potential = every client branch at what a typical active branch of the same client gives (bi.potential_cell). Opportunity = potential − pace. Target = (pace + c × opportunity) × month factor; c rises in equal steps to ' || round(coalesce((v_params->>'capture')::numeric, 0.30) * 100) || '% at month ' || coalesce(v_params->>'horizon', '12')
      || '; month-on-month growth kept between ' || round(coalesce((v_params->>'gmin')::numeric, 0.02) * 100, 1) || '% and ' || round(coalesce((v_params->>'gmax')::numeric, 0.12) * 100, 1) || '% '
      || case when coalesce(v_params->>'basis', 'seasonal') = 'nominal' then 'in rupees.' else 'after seasonality and working days (rupee targets follow the business''s usual monthly rhythm).' end
      || ' Each team x client gets its pace plus its share of the captured opportunity (share = its opportunity ÷ all opportunity). Sources: bi.potential_cell, bi.v_month_business, bi.organic_si, bi.workdays; function bi.plan_compute.')
    into r;
  return r;
end $f$;

-- admin: save the current preview as the plan (audited; the latest saved version is the plan); list versions
create or replace function bi.plan_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer
set search_path to 'bi', 'public' as $f$
declare v_id bigint; v_params jsonb := coalesce(p->'params', '{}'::jsonb); v_ref date; v_share numeric; v_tot jsonb;
begin
  if coalesce(p->>'op', 'list') = 'list' then
    return jsonb_build_object('versions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'params', params, 'ref_month', ref_month,
             'first_month', first_month, 'last_month', last_month, 'created_by', created_by, 'created_at', created_at, 'reason', reason, 'current', id = (select max(x.id) from bi.plan_version x), 'totals', totals) order by id desc), '[]'::jsonb) from bi.plan_version));
  end if;
  if p->>'op' <> 'save' then raise exception 'unknown op %', p->>'op'; end if;
  if length(coalesce(trim(p->>'reason'), '')) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
  select month, (inputs->>'share_to_date')::numeric into v_ref, v_share from bi.potential_run order by run_id desc limit 1;
  select jsonb_object_agg(to_char(q.month, 'YYYY-MM'), round(q.t)) into v_tot from (select c.month, sum(c.target) t from bi.plan_compute(v_params) c group by 1) q;
  insert into bi.plan_version(name, params, ref_month, ref_share, first_month, last_month, created_by, reason, totals)
  values (coalesce(nullif(trim(p->>'name'), ''), 'Plan from ' || to_char(v_ref, 'Mon-YY')), v_params, v_ref, v_share,
          (v_ref + interval '1 month')::date, (v_ref + make_interval(months => least(greatest(coalesce((v_params->>'horizon')::int, 12), 1), 24)))::date,
          p_actor, p->>'reason', v_tot)
  returning id into v_id;
  insert into bi.plan_target(version_id, month, zone_group, location_id, client_family, pace, organic, target)
  select v_id, c.month, c.zone_group, c.location_id, c.client_family, round(c.pace, 2), round(c.organic, 2), round(c.target, 2) from bi.plan_compute(v_params) c;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (p_actor, 'plan_save', 'plan_version', v_id::text, jsonb_build_object('params', v_params, 'reason', p->>'reason', 'totals', v_tot));
  return jsonb_build_object('ok', true, 'version', v_id, 'totals', v_tot);
end $f$;

revoke all on function bi.plan_compute(jsonb), bi.plan_cells(), bi.plan_month_factor(date, date), bi.api_targets(date, jsonb, jsonb),
  bi.plan_admin(text, jsonb) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('bi.call_compute(text, jsonb)'::regprocedure);
begin
  if position('''targets''' in d) = 0 then
    d := replace(d, 'when ''organic'' then', 'when ''targets'' then bi.api_targets(m, f, coalesce(p_args->''p'', ''{}''::jsonb))
      when ''organic'' then');
    execute d;
  end if;
  d := pg_get_functiondef('public.bi_admin(text, jsonb)'::regprocedure);
  if position('''plan''' in d) = 0 then
    if position('when ''db_health'' then' in d) = 0 then raise exception 'bi_admin anchor not found'; end if;
    d := replace(d, 'when ''db_health'' then', 'when ''plan'' then return bi.plan_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');
    when ''db_health'' then');
    execute d;
  end if;
end $m$;
