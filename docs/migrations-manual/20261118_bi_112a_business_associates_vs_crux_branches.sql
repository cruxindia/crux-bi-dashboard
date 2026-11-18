-- wave 112a (18-Nov-2026): Business Associates (partner-run) vs Crux Branches (own branches).
-- New: bi.api_assoc (bi_call 'assoc'): business, growth at the same working day, likely month end (same rule as every page), Force1 TAT/SLA,
-- potential, by zone / location / client / pair. Register edits now refresh the cached figures. Wording: Business Associate / Crux Branch.
-- The consistency check also reads the new page (Business Associates + Crux Branches + not set must equal the total).
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '112a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

create or replace function bi.api_assoc(p_month date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
-- wave 112: Business Associates (partner-run) vs Crux Branches (own branches): business, growth, likely month end, Force1 TAT / SLA, potential.
-- Model of each client x location for a month = the register entry in force on the 15th (product entry wins over family entry), as on the admin page.
declare
  v_cur date := (select max(month) from bi.v_month_business);
  m date := coalesce(date_trunc('month', p_month)::date, (select max(month) from bi.v_month_business));
  pm date; ly date; m0 date; s1 date; s0 date; k int; kk int; sh numeric; part boolean := false; pr bigint; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  pm := (m - interval '1 month')::date; ly := (m - interval '12 months')::date; m0 := (m - interval '5 months')::date;
  select max(snapshot_date) into s1 from bi.zt_snapshot where report_month = m;
  if m = v_cur and s1 is not null then
    k := bi.workdays(m, s1); kk := bi.workdays(m, (m + interval '1 month - 1 day')::date);
    if k < kk then
      part := true; sh := bi.organic_share(m, k);
      select max(snapshot_date) into s0 from bi.zt_snapshot where report_month = pm and bi.workdays(pm, snapshot_date) <= k;
    end if;
  end if;
  select max(run_id) into pr from bi.potential_run where month = m;

  with rows as materialized (
    select mb.month, mb.location_id, mb.client_code, coalesce(c.family, mb.client_code) fam, l.zone_group, l.label loc,
           coalesce(mb.cases, 0) cases, coalesce(mb.revenue, 0) revenue, mb.target_cases, mb.revenue_target,
           case bi.model_on(mb.client_code, mb.location_id, mb.month + 14) when 'partner' then 'associate' when 'self' then 'crux' else 'not_set' end md
      from bi.v_month_business mb join bi.location l on l.id = mb.location_id left join bi.client c on c.code = mb.client_code
     where (mb.month between m0 and m or mb.month = ly) and not l.is_rollup
       and bi.loc_ok(mb.location_id, l.recon_unit, f, mb.month) and bi.fam_ok(mb.client_code, f)),
  prevsd as materialized (
    select z.location_id, coalesce(c.family, z.client_code) fam, l.zone_group, l.label loc, coalesce(z.mtd_cases, 0) cases, coalesce(z.revenue_actual, 0) revenue,
           case bi.model_on(z.client_code, z.location_id, pm + 14) when 'partner' then 'associate' when 'self' then 'crux' else 'not_set' end md
      from bi.v_zt_leaf z join bi.location l on l.id = z.location_id left join bi.client c on c.code = z.client_code
     where part and z.report_month = pm and z.snapshot_date = s0 and not l.is_rollup
       and bi.loc_ok(z.location_id, l.recon_unit, f, z.snapshot_date) and bi.fam_ok(z.client_code, f)),
  cmp as (select md, fam, zone_group, loc, location_id, cases, revenue from prevsd
          union all select md, fam, zone_group, loc, location_id, cases, revenue from rows where not part and month = pm),
  cur as (select * from rows where month = m),
  lyr as (select * from rows where month = ly),
  tot as (select sum(cases) c, sum(revenue) r from cur),
  mds as (select * from (values ('associate', 'Business Associates', 1), ('crux', 'Crux Branches', 2), ('not_set', 'Not set yet', 3)) v(md, label, o)),
  -- Force1 case TAT and SLA by model, last 6 months (received month)
  f1p as (select x.received_month mo, x.client_code, x.location_id,
                 case bi.model_on(x.client_code, x.location_id, x.received_month + 14) when 'partner' then 'associate' when 'self' then 'crux' else 'not_set' end md
            from (select distinct received_month, client_code, location_id from bi.case_store where received_month between m0 and m) x),
  f1 as materialized (
    select v.received_month mo, coalesce(p.md, 'not_set') md, count(*) f1_cases, count(*) filter (where v.tat_flag = 'valid') completed,
           round(percentile_cont(0.5) within group (order by v.raw_tat_hours) filter (where v.tat_flag = 'valid')::numeric, 1) tat_median_h,
           round(percentile_cont(0.9) within group (order by v.raw_tat_hours) filter (where v.tat_flag = 'valid')::numeric, 1) tat_p90_h,
           round(avg(case when v.sla_met then 1.0 when v.sla_met = false then 0 end), 4) sla_met
      from bi.v_case v left join f1p p on p.mo = v.received_month and p.client_code is not distinct from v.client_code and p.location_id is not distinct from v.location_id
     where v.received_month between m0 and m and bi.loc_ok(v.location_id, v.recon_unit, f) and (f->>'client_family' is null or v.client_family = f->>'client_family')
     group by 1, 2),
  pot as (select case bi.model_on(pc.client_family, pc.location_id, m + 14) when 'partner' then 'associate' when 'self' then 'crux' else 'not_set' end md,
                 pc.layer, pc.cases, pc.revenue
            from bi.potential_cell pc join bi.location l on l.id = pc.location_id
           where pc.run_id = pr and bi.loc_ok(pc.location_id, l.recon_unit, f, m)
             and (f->>'client_family' is null or pc.client_family = f->>'client_family')),
  sm as (select d.md, d.label, d.o,
            (select count(distinct (location_id, fam)) from cur where cur.md = d.md and (cases <> 0 or revenue <> 0)) pairs,
            (select count(distinct location_id) from cur where cur.md = d.md and (cases <> 0 or revenue <> 0)) locations,
            (select count(distinct fam) from cur where cur.md = d.md and (cases <> 0 or revenue <> 0)) clients,
            (select sum(cases) from cur where cur.md = d.md) cases, (select sum(revenue) from cur where cur.md = d.md) revenue,
            nullif((select sum(target_cases) from cur where cur.md = d.md), 0) target_cases, nullif((select sum(revenue_target) from cur where cur.md = d.md), 0) revenue_target,
            (select sum(cases) from cmp where cmp.md = d.md) cmp_cases, (select sum(revenue) from cmp where cmp.md = d.md) cmp_revenue,
            (select sum(cases) from lyr where lyr.md = d.md) ly_cases, (select sum(revenue) from lyr where lyr.md = d.md) ly_revenue
       from mds d),
  sm2 as (select s.*, case when part and sh > 0 then s.cases / sh else s.cases end likely_cases, case when part and sh > 0 then s.revenue / sh else s.revenue end likely_revenue from sm s)
  select jsonb_build_object(
    'month', m, 'as_of', s1, 'partial', part, 'working_days_done', k, 'working_days_in_month', kk, 'month_share', round(sh, 6),
    'comparison', case when part then 'previous month at the same working day (' || to_char(s0, 'DD-Mon') || ')' else 'previous month in full' end, 'comparison_snapshot', s0,
    'labels', jsonb_build_object('associate', 'Business Associates', 'crux', 'Crux Branches', 'not_set', 'Not set yet'),
    'rule', 'Business Associates = client and location pairs run by a partner (business associate); Crux Branches = pairs run by our own branch. Each month counts under the entry in force on its 15th (Admin, Business Associates & Crux Branches). Likely month end = so far ÷ the usual share of the month done by this working day (the same rule on every page). TAT = Force1 case TAT in hours (received to completed), median of completed cases; SLA met = completed by the due time.',
    'totals', (select jsonb_build_object('cases', c, 'revenue', round(r)) from tot),
    'summary', (select jsonb_agg(jsonb_build_object('model', md, 'label', label, 'pairs', pairs, 'locations', locations, 'clients', clients,
          'cases', cases, 'revenue', round(revenue), 'revenue_per_case', round(revenue / nullif(cases, 0), 1),
          'revenue_per_location', round(revenue / nullif(locations, 0)), 'cases_per_location', round(cases / nullif(locations, 0)),
          'share_cases', round(cases / nullif((select c from tot), 0), 4), 'share_revenue', round(revenue / nullif((select r from tot), 0), 4),
          'likely_cases', round(likely_cases), 'likely_revenue', round(likely_revenue),
          'cmp_cases', cmp_cases, 'cmp_revenue', round(cmp_revenue),
          'growth_cases', round(cases / nullif(cmp_cases, 0) - 1, 4), 'growth_revenue', round(revenue / nullif(cmp_revenue, 0) - 1, 4),
          'ly_cases', ly_cases, 'ly_revenue', round(ly_revenue),
          'yoy_cases', round(likely_cases / nullif(ly_cases, 0) - 1, 4), 'yoy_revenue', round(likely_revenue / nullif(ly_revenue, 0) - 1, 4),
          'target_cases', target_cases, 'revenue_target', round(revenue_target),
          'likely_vs_target', round(likely_revenue / nullif(revenue_target, 0), 4),
          'f1_cases', (select f1_cases from f1 where f1.mo = m and f1.md = s.md), 'tat_median_h', (select tat_median_h from f1 where f1.mo = m and f1.md = s.md),
          'tat_p90_h', (select tat_p90_h from f1 where f1.mo = m and f1.md = s.md), 'sla_met', (select sla_met from f1 where f1.mo = m and f1.md = s.md),
          'f1_last_full', (select jsonb_build_object('month', f1.mo, 'f1_cases', f1.f1_cases, 'tat_median_h', f1.tat_median_h, 'tat_p90_h', f1.tat_p90_h, 'sla_met', f1.sla_met)
                             from f1 where f1.md = s.md and f1.mo = pm),
          'potential', (select jsonb_build_object('likely', round(sum(revenue) filter (where layer = 'current')),
                              'recover', round(sum(revenue) filter (where layer = 'recover')), 'dormant', round(sum(revenue) filter (where layer = 'dormant')),
                              'new', round(sum(revenue) filter (where layer like 'never%')), 'untapped', round(sum(revenue) filter (where layer <> 'current')))
                          from pot where pot.md = s.md)
        ) order by o) from sm2 s),
    'trend', (select coalesce(jsonb_agg(jsonb_build_object('month', t.month, 'model', t.md, 'cases', t.cases, 'revenue', round(t.revenue),
                 'revenue_per_case', round(t.revenue / nullif(t.cases, 0), 1), 'locations', t.locs, 'partial', part and t.month = m,
                 'f1_cases', f1.f1_cases, 'tat_median_h', f1.tat_median_h, 'sla_met', f1.sla_met) order by t.month, t.md), '[]')
              from (select month, md, sum(cases) cases, sum(revenue) revenue, count(distinct location_id) filter (where cases <> 0 or revenue <> 0) locs
                      from rows where month between m0 and m group by 1, 2) t left join f1 on f1.mo = t.month and f1.md = t.md),
    'by_zone', (select coalesce(jsonb_agg(z order by z->>'zone_group', z->>'model'), '[]') from (
                 select jsonb_build_object('zone_group', g.zone_group, 'model', g.md, 'cases', g.c, 'revenue', round(g.r), 'locations', g.locs,
                   'likely_revenue', round(case when part and sh > 0 then g.r / sh else g.r end),
                   'cmp_cases', p.c, 'cmp_revenue', round(p.r), 'growth_cases', round(g.c / nullif(p.c, 0) - 1, 4), 'growth_revenue', round(g.r / nullif(p.r, 0) - 1, 4)) z
                 from (select zone_group, md, sum(cases) c, sum(revenue) r, count(distinct location_id) filter (where cases <> 0 or revenue <> 0) locs from cur group by 1, 2) g
                 left join (select zone_group, md, sum(cases) c, sum(revenue) r from cmp group by 1, 2) p on p.zone_group is not distinct from g.zone_group and p.md = g.md) q),
    'by_location', (select coalesce(jsonb_agg(z order by z->>'zone_group', z->>'location'), '[]') from (
                 select jsonb_build_object('location_id', g.location_id, 'location', g.loc, 'zone_group', g.zone_group,
                   'associate_cases', g.ac, 'associate_revenue', round(g.ar), 'associate_clients', g.acl,
                   'crux_cases', g.cc, 'crux_revenue', round(g.cr), 'crux_clients', g.ccl,
                   'not_set_cases', g.nc, 'not_set_revenue', round(g.nr),
                   'mix', case when g.acl > 0 and g.ccl > 0 then 'both' when g.acl > 0 then 'associate' when g.ccl > 0 then 'crux' else 'not_set' end,
                   'cmp_revenue', round(p.r), 'growth_revenue', round((coalesce(g.ar, 0) + coalesce(g.cr, 0) + coalesce(g.nr, 0)) / nullif(p.r, 0) - 1, 4)) z
                 from (select location_id, loc, zone_group,
                         sum(cases) filter (where md = 'associate') ac, sum(revenue) filter (where md = 'associate') ar, count(distinct fam) filter (where md = 'associate' and (cases <> 0 or revenue <> 0)) acl,
                         sum(cases) filter (where md = 'crux') cc, sum(revenue) filter (where md = 'crux') cr, count(distinct fam) filter (where md = 'crux' and (cases <> 0 or revenue <> 0)) ccl,
                         sum(cases) filter (where md = 'not_set') nc, sum(revenue) filter (where md = 'not_set') nr
                       from cur group by 1, 2, 3) g
                 left join (select location_id, sum(revenue) r from cmp group by 1) p on p.location_id = g.location_id) q),
    'by_client', (select coalesce(jsonb_agg(z order by (z->>'revenue')::numeric desc nulls last), '[]') from (
                 select jsonb_build_object('client', g.fam, 'model', g.md, 'cases', g.c, 'revenue', round(g.r), 'locations', g.locs,
                   'revenue_per_case', round(g.r / nullif(g.c, 0), 1), 'cmp_revenue', round(p.r), 'growth_revenue', round(g.r / nullif(p.r, 0) - 1, 4),
                   'growth_cases', round(g.c / nullif(p.c, 0) - 1, 4)) z
                 from (select fam, md, sum(cases) c, sum(revenue) r, count(distinct location_id) filter (where cases <> 0 or revenue <> 0) locs from cur group by 1, 2) g
                 left join (select fam, md, sum(cases) c, sum(revenue) r from cmp group by 1, 2) p on p.fam = g.fam and p.md = g.md
                 where g.c <> 0 or g.r <> 0) q),
    'pairs', (select coalesce(jsonb_agg(z order by z->>'zone_group', z->>'location', z->>'client'), '[]') from (
                 select jsonb_build_object('zone_group', g.zone_group, 'location', g.loc, 'client', g.fam, 'model', g.md, 'cases', g.c, 'revenue', round(g.r),
                   'likely_revenue', round(case when part and sh > 0 then g.r / sh else g.r end), 'cmp_revenue', round(p.r),
                   'growth_revenue', round(g.r / nullif(p.r, 0) - 1, 4)) z
                 from (select zone_group, loc, location_id, fam, md, sum(cases) c, sum(revenue) r from cur group by 1, 2, 3, 4, 5) g
                 left join (select location_id, fam, sum(revenue) r from cmp group by 1, 2) p on p.location_id = g.location_id and p.fam = g.fam
                 where g.c <> 0 or g.r <> 0 or coalesce(p.r, 0) <> 0) q)
  ) into res;
  return res;
end $fn$;
comment on function bi.api_assoc(date, jsonb) is 'wave 112: Business Associates vs Crux Branches performance (business, growth at the same working day, likely month end, Force1 TAT/SLA, potential), by zone, location, client and pair.';

select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  $r$      when 'operating_model' then bi.api_operating_model(m, f)   -- wave 109c$r$,
  $r$      when 'operating_model' then bi.api_operating_model(m, f)   -- wave 109c
      when 'assoc' then bi.api_assoc(m, f)   -- wave 112: Business Associates vs Crux Branches$r$], array[1]);

select pg_temp.patch('bi.operating_model_save(text,jsonb,boolean)'::regprocedure, array[
  $r$'model must be Partner or Own branch'$r$, $r$'model must be Business Associate or Crux Branch'$r$,
  $r$case o.model when 'partner' then 'partner' else 'own-branch' end$r$, $r$case o.model when 'partner' then 'Business Associate' else 'Crux Branch' end$r$], array[1,1]);

select pg_temp.patch('bi.operating_model_admin(text,jsonb)'::regprocedure, array[
  $r$begin
  if op = 'list' then$r$, $r$begin
  if op not in ('list', 'grid') then delete from bi.api_cache where fn in ('operating_model', 'assoc'); end if;   -- wave 112: register edits show at once
  if op = 'list' then$r$], array[1]);

select pg_temp.patch('bi.consistency_check(date,boolean)'::regprocedure, array[
  $r$mp jsonb; ov jsonb;$r$, $r$mp jsonb; ov jsonb; ba jsonb;$r$,
  $r$  sh := nullif(bm->>'share_of_month_done', '')::numeric;$r$, $r$  ba := public.bi_call('assoc', a);   -- wave 112
  sh := nullif(bm->>'share_of_month_done', '')::numeric;$r$,
  $r$'Business-as-usual model', orr #> '{total,actual}'));$r$,
  $r$'Business-as-usual model', orr #> '{total,actual}',
          'Business Associates vs Crux Branches (sum of the three groups)', (select to_jsonb(sum((x->>'revenue')::numeric)) from jsonb_array_elements(coalesce(ba->'summary', '[]')) x)));$r$,
  $r$'Business-as-usual model', ogc #> '{total,actual}'));$r$,
  $r$'Business-as-usual model', ogc #> '{total,actual}',
          'Business Associates vs Crux Branches (sum of the three groups)', (select to_jsonb(sum((x->>'cases')::numeric)) from jsonb_array_elements(coalesce(ba->'summary', '[]')) x)));$r$,
  $r$'Business-as-usual model', orr #> '{total,projected}'));$r$,
  $r$'Business-as-usual model', orr #> '{total,projected}',
          'Business Associates vs Crux Branches (sum of the three groups)', (select to_jsonb(sum((x->>'likely_revenue')::numeric)) from jsonb_array_elements(coalesce(ba->'summary', '[]')) x)));$r$
], array[1,1,1,1,1]);

delete from bi.api_cache where fn in ('operating_model', 'assoc');
