-- Applied to Supabase project via MCP on 20261015001447
-- bi_083: operational detail for the drill-down drawer and comparisons.
-- Every figure re-uses an existing dashboard definition (TAT section, Force1 utilisation, branch coverage, branch priority,
-- penalties, revenue potential); tests T43-T46 check that totals equal the section endpoints. Read-only.

-- zone of each location (as of a date, honouring WEF zone moves) and of each location group
create or replace function bi.zone_map(p_at date)
returns table(location_id int, recon_unit text, zone text) language sql stable security definer set search_path to 'bi', 'public' as $function$
  select l.id, l.recon_unit, coalesce(bi.loc_attr_at(l.id, 'zone_group', p_at), l.zone_group) from bi.location l
$function$;

-- TAT for a selection, grouped: case TAT (Completed - Received), document TAT, field TAT, tele TAT (definitions of the TAT section)
create or replace function bi.tat_summary(m date, f jsonb, grp text default 'total')
returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
with zm as materialized (select * from bi.zone_map(coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = m), (m + interval '1 month - 1 day')::date))),
uz as materialized (select recon_unit, min(zone) zone from zm group by 1),
cs as (select case grp when 'zone' then coalesce((select zone from zm where zm.location_id = v.location_id), (select zone from uz where uz.recon_unit = v.recon_unit))
                       when 'location' then v.location_id::text when 'client' then v.client_family when 'unit' then v.recon_unit
                       when 'branch' then v.client_family || '|' || coalesce(bi.norm_code(v.branch_code), '') else 'total' end id,
              v.tat_flag, v.raw_tat_hours, v.sla_met
       from bi.v_case v
       where v.received_month = m and bi.loc_ok(v.location_id, v.recon_unit, f) and (f->>'client_family' is null or v.client_family = f->>'client_family')),
ca as (select id, count(*) cases, count(*) filter (where tat_flag = 'valid') completed, count(*) filter (where tat_flag = 'open') open,
         round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) median,
         round(percentile_cont(0.9) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) p90,
         round(avg(raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1) avg,
         round(avg(case when sla_met then 1.0 when sla_met = false then 0 end), 4) sla_met_pct
       from cs group by id),
pv as (select v.*, c.family fam from bi.v_point v left join bi.client c on c.code = v.client_code
       where v.created_month = m and bi.loc_ok(v.location_id, v.recon_unit, f) and bi.fam_ok(v.client_code, f)),
ps as (select case grp when 'zone' then coalesce((select zone from zm where zm.location_id = v.location_id), (select zone from uz where uz.recon_unit = v.recon_unit))
                       when 'location' then v.location_id::text when 'client' then v.fam when 'unit' then v.recon_unit
                       when 'branch' then cf.family || '|' || coalesce(bi.norm_code(c2.branch_code), '')
                       else 'total' end id,
              v.category, v.field_tat_hours, v.field_tat_invalid, v.doc_tat_hours, v.tele_tat_hours
       from pv v left join bi.case_store c2 on grp = 'branch' and c2.case_id = v.case_id left join bi.client cf on cf.code = c2.client_code),
pa as (select id, count(*) points,
         count(*) filter (where category = 'field') field_points, count(field_tat_hours) field_n, count(*) filter (where field_tat_invalid) field_invalid,
         round(percentile_cont(0.5) within group (order by field_tat_hours)::numeric, 1) field_median,
         round(percentile_cont(0.9) within group (order by field_tat_hours)::numeric, 1) field_p90,
         count(*) filter (where category = 'document') doc_points, count(doc_tat_hours) doc_n,
         round(percentile_cont(0.5) within group (order by doc_tat_hours)::numeric, 1) doc_median,
         round(percentile_cont(0.9) within group (order by doc_tat_hours)::numeric, 1) doc_p90,
         count(*) filter (where category = 'tele') tele_points, count(tele_tat_hours) tele_n,
         round(percentile_cont(0.5) within group (order by tele_tat_hours)::numeric, 1) tele_median
       from ps group by id)
select coalesce(jsonb_agg(jsonb_build_object('id', coalesce(ca.id, pa.id),
  'case', jsonb_build_object('cases', coalesce(ca.cases, 0), 'completed', coalesce(ca.completed, 0), 'open', coalesce(ca.open, 0), 'median', ca.median, 'p90', ca.p90,
                             'avg', ca.avg, 'sla_met_pct', ca.sla_met_pct, 'low_sample', coalesce(ca.completed, 0) < 30),
  'document', jsonb_build_object('points', coalesce(pa.doc_points, 0), 'n', coalesce(pa.doc_n, 0), 'median', pa.doc_median, 'p90', pa.doc_p90, 'low_sample', coalesce(pa.doc_n, 0) < 30),
  'field', jsonb_build_object('points', coalesce(pa.field_points, 0), 'n', coalesce(pa.field_n, 0), 'median', pa.field_median, 'p90', pa.field_p90,
                              'invalid', coalesce(pa.field_invalid, 0), 'low_sample', coalesce(pa.field_n, 0) < 30),
  'tele', jsonb_build_object('points', coalesce(pa.tele_points, 0), 'n', coalesce(pa.tele_n, 0), 'median', pa.tele_median),
  'points', coalesce(pa.points, 0)) order by coalesce(ca.cases, 0) desc), '[]'::jsonb)
from ca full join pa on pa.id is not distinct from ca.id
$function$;

-- branch lifecycle rows (same rules and windows as api_branches); optional restriction to location groups for speed
create or replace function bi.branch_lifecycle_rows(p_units text[] default null)
returns table(client_code text, bkey text, bname text, bcode text, recon_unit text, location_id int, n_cov bigint, l3 numeric, p3 numeric, total numeric,
              first_seen date, last_seen date, status text, n_peer bigint, peer_med double precision, opp_monthly double precision, impact numeric)
language sql stable security definer set search_path to 'bi', 'public' as $function$
with cov as (select recon_unit, received_month m from bi.case_store where received_month < date_trunc('month', now() at time zone 'Asia/Kolkata')
               and (p_units is null or recon_unit = any(p_units)) group by 1,2),
covr as (select recon_unit, m, row_number() over (partition by recon_unit order by m desc) rn, count(*) over (partition by recon_unit) n_cov from cov),
br as (select c.client_code, coalesce(nullif(c.branch_code,''), d.val) bkey, max(d.val) bname, max(c.branch_code) bcode, c.recon_unit,
         mode() within group (order by c.location_id) location_id, c.received_month m, count(*) n
       from bi.case_store c left join bi.dim d on d.id=c.branch_id
       where c.received_month < date_trunc('month', now() at time zone 'Asia/Kolkata') and (p_units is null or c.recon_unit = any(p_units))
       group by c.client_code, coalesce(nullif(c.branch_code,''), d.val), c.recon_unit, c.received_month),
grid as (select b.client_code, b.bkey, b.recon_unit, v.m, v.rn, v.n_cov, coalesce(x.n,0) n
         from (select distinct client_code, bkey, recon_unit from br) b join covr v on v.recon_unit=b.recon_unit
         left join br x on x.client_code=b.client_code and x.bkey=b.bkey and x.recon_unit=b.recon_unit and x.m=v.m),
s as (select g.client_code, g.bkey, g.recon_unit, max(g.n_cov) n_cov,
        sum(n) filter (where rn<=3) l3, sum(n) filter (where rn between 4 and 6) p3, sum(n) filter (where rn<=2) l2,
        sum(n) filter (where rn=1) last1, sum(n) filter (where rn between 2 and 3) prev2, sum(n) total,
        min(m) filter (where n>0) first_seen, max(m) filter (where n>0) last_seen,
        (select max(m) from covr c2 where c2.recon_unit=g.recon_unit and c2.rn=2) cov2
      from grid g group by 1,2,3),
meta as (select client_code, bkey, recon_unit, max(bname) bname, max(bcode) bcode, mode() within group (order by location_id) location_id from br group by 1,2,3),
cls as (select s.*, m.bname, m.bcode, m.location_id,
  case when s.n_cov < 6 or s.total < 3 then 'insufficient_data'
       when s.first_seen >= s.cov2 then 'new'
       when s.l2 = 0 then 'dormant'
       when s.last1 > 0 and s.prev2 = 0 and s.total - s.l3 > 0 then 'reactivated'
       when s.l3 >= s.p3*1.2 and s.l3 - s.p3 >= 3 then 'growing'
       when s.l3 <= s.p3*0.7 and s.p3 - s.l3 >= 3 then 'losing_traction'
       else 'stable' end status
  from s join meta m using (client_code, bkey, recon_unit)),
peer as (select client_code, recon_unit, count(*) n_peer, percentile_cont(0.5) within group (order by l3/3.0) med
         from cls where status in ('stable','growing','losing_traction') group by 1,2)
select c.client_code, c.bkey, c.bname, c.bcode, c.recon_unit, c.location_id, c.n_cov, c.l3, c.p3, c.total, c.first_seen, c.last_seen, c.status, p.n_peer, p.med,
       case when c.status in ('stable','losing_traction') and p.n_peer >= 5 then greatest(0, p.med - c.l3/3.0) end,
       case c.status when 'losing_traction' then (c.p3 - c.l3)/3.0 when 'dormant' then (c.total - c.l3)::numeric/greatest(c.n_cov-3,1)
                     else coalesce(case when c.status in ('stable','losing_traction') and p.n_peer >= 5 then greatest(0, p.med - c.l3/3.0) end, 0)::numeric end
from cls c left join peer p using (client_code, recon_unit)
$function$;

-- drawer / comparison detail, one part per call so parts load in parallel and are cached separately
create or replace function bi.api_drill_ops(m date, f jsonb, lvl text, part text)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare asof date; me date; res jsonb; tot jsonb; kids jsonb; units text[];
begin
  f := coalesce(f, '{}'::jsonb);
  if lvl not in ('zone', 'location', 'client', 'branch', 'none') then raise exception 'level must be zone, location, client, branch or none'; end if;
  me := (m + interval '1 month - 1 day')::date;
  asof := coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = m), me);

  if part = 'tat' then
    tot := bi.tat_summary(m, f, 'total')->0;
    if lvl <> 'none' then kids := bi.tat_summary(m, f, lvl); end if;
    return jsonb_build_object('part', part, 'month', m, 'total', tot, 'children', kids,
      'method', 'Case TAT = case completed − case received (Force1 Case Wise, cases received in the month). Document TAT = document point completed − created; Field TAT = field visit reviewed − assigned; Tele TAT = tele point completed − created (Force1 Point Wise, points created in the month). Median and P90 in hours; fewer than 30 completed items = low sample. Same definitions as the TAT section.');

  elsif part = 'force1' then
    with zm as materialized (select * from bi.zone_map(asof)), uz as materialized (select recon_unit, min(zone) zone from zm group by 1),
    ucount as (select recon_unit, count(*) n, min(id) only_loc from bi.location group by 1),
    lok as (select location_id, recon_unit from (select distinct location_id, recon_unit from bi.point_derived where created_month = m offset 0) x where bi.loc_ok(location_id, recon_unit, f)),
    cok as (select code from bi.client where bi.fam_ok(code, f)),
    pts as (select p.*, case lvl when 'zone' then coalesce((select zone from zm where zm.location_id = p.location_id), (select zone from uz where uz.recon_unit = p.recon_unit))
                                 when 'location' then p.location_id::text when 'client' then (select family from bi.client c where c.code = p.client_code) else 'total' end cid
            from bi.point_derived p join lok on lok.location_id is not distinct from p.location_id and lok.recon_unit is not distinct from p.recon_unit
            where p.created_month = m and (f->>'client_family' is null or p.client_code in (select code from cok))),
    fu as (select v.*, case lvl when 'zone' then (select zone from uz where uz.recon_unit = v.recon_unit) when 'client' then v.client_family
                               when 'location' then (select case when u.n = 1 then u.only_loc::text end from ucount u where u.recon_unit = v.recon_unit) else 'total' end cid
           from bi.v_force_usage v where v.month = m and v.case_data_available and bi.loc_ok(null, v.recon_unit, f) and (f->>'client_family' is null or v.client_family = f->>'client_family')),
    pt as (select 'TOTAL'::text k, * from pts union all select coalesce(cid, '(not assigned)'), * from pts where lvl in ('zone', 'location', 'client')),
    ft as (select 'TOTAL'::text k, * from fu union all select coalesce(cid, '(not assigned)'), * from fu where lvl in ('zone', 'location', 'client')),
    pagg as (select pt.k id, count(*) filter (where category = 'field') field_points, count(*) filter (where route = 1) f1_field, count(*) filter (where route = 2) manual_field,
                    count(*) filter (where route in (3, 4)) unverified_field, count(distinct verifier_id) filter (where verifier_class = 1) field_execs,
                    count(distinct verifier_id) filter (where verifier_class = 2) back_office_staff,
                    percentile_cont(0.5) within group (order by field_tat_hours) filter (where route = 1 and field_tat_hours is not null) f1_tat,
                    percentile_cont(0.5) within group (order by field_tat_hours) filter (where route = 2 and field_tat_hours is not null) man_tat
             from pt group by 1),
    cagg as (select ft.k id, sum(tracker_cases) tracker_cases, sum(force_cases) force1_cases from ft group by 1),
    j as (select coalesce(p.id, c.id) id, jsonb_build_object(
              'tracker_cases', c.tracker_cases, 'force1_cases', c.force1_cases, 'case_utilisation', round(c.force1_cases::numeric / nullif(c.tracker_cases, 0), 4),
              'field_points', p.field_points, 'f1_field', p.f1_field, 'manual_field', p.manual_field, 'unverified_field', p.unverified_field,
              'field_utilisation', round(p.f1_field::numeric / nullif(p.f1_field + p.manual_field, 0), 4),
              'field_execs', p.field_execs, 'back_office_staff', p.back_office_staff,
              'f1_field_tat_hours', round(p.f1_tat::numeric, 1), 'manual_field_tat_hours', round(p.man_tat::numeric, 1)) x
          from pagg p full join cagg c on c.id = p.id)
    select (select x from j where id = 'TOTAL'),
           (select coalesce(jsonb_agg(x || jsonb_build_object('id', id) order by (x->>'tracker_cases')::numeric desc nulls last), '[]'::jsonb) from j where id <> 'TOTAL')
      into tot, kids;
    return jsonb_build_object('part', part, 'month', m, 'total', tot, 'children', case when lvl in ('zone', 'location', 'client') then kids end,
      'method', 'Case utilisation = Force1 cases ÷ Zonal Tracker cases for location groups with Force1 case data (measured per location group, so a single location shows it only when it is its group''s only location). Field utilisation = field points submitted by field executives ÷ (field executives + back office). Same definitions as the Force1 utilisation section.');

  elsif part = 'coverage' then
    with zm as materialized (select * from bi.zone_map(asof)),
    locs as (select l2.id from bi.location l2 where bi.loc_ok(l2.id, l2.recon_unit, f)),
    fams as (select r.family from bi.client_family_research r where bi.fam_ok(r.family, f) union select c2.family from bi.client c2 where bi.fam_ok(c2.family, f)),
    cut as (select (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date c),
    x as (select v.*, a.last_m, a.n, a.n3,
                 case lvl when 'zone' then (select zone from zm where zm.location_id = v.location_id) when 'location' then v.location_id::text when 'client' then v.fam else 'total' end cid
          from bi.branch_cov_mv v
          left join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm and not v.website
          where (v.location_id is null and coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb or v.location_id in (select id from locs))
            and v.fam in (select family from fams)),
    ver as (select * from x where status = 'active' and vs in ('source_verified', 'admin_upload')),
    peer as (select fam, location_id, percentile_cont(0.5) within group (order by n3 / 3.0) med from ver where n3 > 0 and location_id is not null group by 1, 2 having count(*) >= 5),
    vv as (select v.*, p.med from ver v left join peer p on p.fam = v.fam and p.location_id = v.location_id),
    t as (select 'TOTAL'::text k, * from vv union all select coalesce(cid, '(territory not mapped)'), * from vv where lvl in ('zone', 'location', 'client')),
    tx as (select 'TOTAL'::text k, * from x union all select coalesce(cid, '(territory not mapped)'), * from x where lvl in ('zone', 'location', 'client')),
    a as (select k, count(*) verified_active, count(*) filter (where website) website_listed, count(*) filter (where not website) matchable,
                 count(*) filter (where last_m >= (select c from cut)) active_6m, count(*) filter (where n is not null) ever_with_crux,
                 count(*) filter (where n is null and not website) never_activated, count(*) filter (where n is not null and last_m < (select c from cut)) gone_quiet_6m,
                 count(*) filter (where n is null and not website and med is not null) opportunity_branches,
                 round(sum(med) filter (where n is null and not website)::numeric, 0) indicative_cases_per_month
          from t group by k),
    b as (select k, count(*) filter (where status <> 'active') closed_or_ineligible, count(*) filter (where status = 'active' and vs = 'status_uncertain') status_uncertain from tx group by k),
    j as (select coalesce(a.k, b.k) k, jsonb_build_object('verified_active', coalesce(a.verified_active, 0), 'website_listed', coalesce(a.website_listed, 0),
            'matchable', coalesce(a.matchable, 0), 'active_6m', coalesce(a.active_6m, 0), 'ever_with_crux', coalesce(a.ever_with_crux, 0),
            'never_activated', coalesce(a.never_activated, 0), 'gone_quiet_6m', coalesce(a.gone_quiet_6m, 0),
            'coverage_6m', round(a.active_6m::numeric / nullif(a.matchable, 0), 4), 'opportunity_branches', coalesce(a.opportunity_branches, 0),
            'indicative_cases_per_month', a.indicative_cases_per_month, 'closed_or_ineligible', coalesce(b.closed_or_ineligible, 0),
            'status_uncertain', coalesce(b.status_uncertain, 0)) x
          from a full join b on b.k = a.k)
    select (select x from j where k = 'TOTAL'), (select coalesce(jsonb_agg(x || jsonb_build_object('id', k) order by (x->>'verified_active')::int desc), '[]'::jsonb) from j where k <> 'TOTAL')
      into tot, kids;
    return jsonb_build_object('part', part, 'total', tot, 'children', case when lvl in ('zone', 'location', 'client') then kids end,
      'method', 'Verified universe = active, source-verified client branches in this selection''s territory. Active (6 months) = a Force1 case in the last 6 months, matched by branch code; Coverage = active ÷ code-matchable branches; Never activated = no Force1 case since Jan-2026; Gone quiet = had Force1 cases but none in the last 6 months; Website-listed branches have no codes and are excluded from coverage. Same definitions as Business tracker → branch coverage.');

  elsif part = 'lifecycle' then
    select array_agg(distinct u) into units from (
      select c.recon_unit u from bi.case_store c where c.location_id in (select l.id from bi.location l where bi.loc_ok(l.id, l.recon_unit, f))
      union select l.recon_unit from bi.location l where bi.loc_ok(null, l.recon_unit, f)) q;
    if coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb then units := null; end if;
    with zm as materialized (select * from bi.zone_map(asof)), uz as materialized (select recon_unit, min(zone) zone from zm group by 1),
    r as materialized (select b.*, c.family, l.label loc_label,
                 case lvl when 'zone' then coalesce((select zone from zm where zm.location_id = b.location_id), (select zone from uz where uz.recon_unit = b.recon_unit))
                          when 'location' then b.location_id::text when 'client' then c.family else 'total' end cid
          from bi.branch_lifecycle_rows(units) b left join bi.client c on c.code = b.client_code left join bi.location l on l.id = b.location_id
          where bi.loc_ok(b.location_id, b.recon_unit, f) and bi.fam_ok(b.client_code, f)),
    t as (select 'TOTAL'::text k, * from r union all select coalesce(cid, '(not assigned)'), * from r where lvl in ('zone', 'location', 'client')),
    j as (select k, jsonb_build_object('branches_seen', count(*), 'active', count(*) filter (where status not in ('dormant', 'insufficient_data')),
            'new', count(*) filter (where status = 'new'), 'reactivated', count(*) filter (where status = 'reactivated'), 'growing', count(*) filter (where status = 'growing'),
            'stable', count(*) filter (where status = 'stable'), 'losing_traction', count(*) filter (where status = 'losing_traction'),
            'dormant', count(*) filter (where status = 'dormant'), 'insufficient_data', count(*) filter (where status = 'insufficient_data')) x from t group by k)
    select jsonb_build_object('part', part, 'total', (select x from j where k = 'TOTAL'),
      'children', case when lvl in ('zone', 'location', 'client') then (select coalesce(jsonb_agg(x || jsonb_build_object('id', k) order by (x->>'branches_seen')::int desc), '[]'::jsonb) from j where k <> 'TOTAL') end,
      'branches', case when lvl = 'branch' then (select coalesce(jsonb_agg(jsonb_build_object('client_code', client_code, 'client_family', family, 'branch_code', bcode,
                'code_norm', bi.norm_code(bcode), 'status', status, 'last3m', l3, 'prior3m', p3, 'last_seen', last_seen)), '[]'::jsonb) from r where bcode is not null) end,
      'priority', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
              select jsonb_build_object('client', client_code, 'client_family', family, 'branch', bname, 'branch_code', bcode, 'location', loc_label, 'status', status,
                'last3m', l3, 'prior3m', p3, 'peer_median_monthly', round(peer_med::numeric, 1), 'priority_cases_per_month', round(impact, 1),
                'action', case status when 'losing_traction' then 'Review with branch/client: volume down vs prior 3 months'
                  when 'dormant' then 'Recovery call: no cases in last 2 covered months'
                  when 'stable' then case when opp_monthly > 0 then 'Growth: below peer median for same client & location group' end
                  when 'reactivated' then 'Secure: branch resumed after a gap' when 'new' then 'Onboard: new branch, monitor ramp-up' end) x
              from r where status in ('losing_traction', 'dormant', 'stable', 'reactivated', 'new') and impact > 0
              order by impact desc limit 10) q),
      'method', 'Complete months only (current month excluded). Last 3 covered months vs prior 3 of the branch''s location group: new = first case in the last 2 covered months; dormant = no case in the last 2; reactivated = cases in the latest month after none in the previous 2; growing = last 3 ≥ 1.2 × prior 3 (and +3); losing traction = last 3 ≤ 0.7 × prior 3 (and −3); insufficient data = < 6 covered months or < 3 cases; else stable. Same rules as the branch priority list.')
      into res;
    return res;

  elsif part = 'revenue' then
    tot := bi.api_potential(m, f, 'revenue', 'total')->'rows'->0;
    if lvl in ('zone', 'location', 'client') then
      select coalesce(jsonb_agg(r || jsonb_build_object('id', case lvl when 'zone' then (select z.code from bi.zone_group z where z.label = r->>'group' limit 1)
                                     when 'location' then (select l.id::text from bi.location l where l.label = r->>'group' limit 1)
                                     else (select c.family from bi.client c where c.label = r->>'group' or c.code = r->>'group' limit 1) end)), '[]'::jsonb)
        into kids from jsonb_array_elements(bi.api_potential(m, f, 'revenue', lvl)->'rows') r;
    end if;
    return jsonb_build_object('part', part, 'month', m, 'total', tot, 'children', kids,
      'method', 'Revenue (₹) month to date from the Zonal Tracker; likely month end, range and status use the same method as cases.');

  elsif part = 'penalty' then
    with zm as materialized (select * from bi.zone_map(asof)),
    pen as (select x.*, case lvl when 'zone' then (select zone from zm where zm.location_id = x.location_id) when 'location' then x.location_id::text
                                 when 'client' then coalesce((select family from bi.client c where c.code = x.client_code), '(not client-specific)') else 'total' end cid
            from bi.penalty x join bi.location l on l.id = x.location_id
            where x.active and x.penalty_date between m and me and bi.loc_ok(x.location_id, l.recon_unit, f, x.penalty_date)
              and (x.client_code is null and f->>'client_family' is null or x.client_code is not null and bi.fam_ok(x.client_code, f)))
    select jsonb_build_object('amount', coalesce(sum(amount), 0), 'count', count(*)),
           (select coalesce(jsonb_agg(jsonb_build_object('id', cid, 'amount', a, 'count', n)), '[]'::jsonb) from (select cid, sum(amount) a, count(*) n from pen group by 1) q)
      into tot, kids from pen;
    return jsonb_build_object('part', part, 'month', m, 'total', tot, 'children', case when lvl in ('zone', 'location', 'client') then kids end,
      'method', 'Penalties charged to Crux in ₹ entered by admins; report only (revenue not reduced). Reasons are visible to admins in Upload centre.');
  else
    raise exception 'part must be tat, force1, coverage, lifecycle, revenue or penalty';
  end if;
end $function$;

-- drill: like-for-like total and branch activity of the month alongside the organic comparison
do $$
declare d text := pg_get_functiondef('bi.api_drill(date,jsonb,text,jsonb)'::regprocedure);
  a1 text := $a$'history', hist,$a$;
  n1 text := $n$'history', hist, 'lfl', (select jsonb_build_object('current', l->'total_current', 'previous', l->'total_previous', 'current_snapshot', l->'current_snapshot', 'comparison_snapshot', l->'comparison_snapshot') from (select bi.api_lfl(m, f, 'location') l offset 0) q),$n$;
  a2 text := $a$jsonb_build_object('complete', o->'complete', 'as_of', o->'as_of')$a$;
  n2 text := $n$jsonb_build_object('complete', o->'complete', 'as_of', o->'as_of', 'branches', o->'branches')$n$;
begin
  if position('''lfl''' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 or (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 then raise exception 'api_drill anchors not unique'; end if;
  execute replace(replace(d, a1, n1), a2, n2);
end $$;

-- branch detail: lifecycle status (same rules as the priority list) and TAT for the last 3 months
create or replace function bi.api_branch_detail(f jsonb)
returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
with k as (select coalesce(f->>'client_family', (select family from bi.client where code = f->>'client_code')) fam, bi.norm_code(f->>'branch_code') cn),
codes as (select code from bi.client, k where family = k.fam),
cs as (select c.* from bi.case_store c, k where c.client_code in (select code from codes) and bi.norm_code(c.branch_code) = k.cn),
mon as (select received_month m, count(*) n from cs group by 1),
mst as (select b.* from bi.client_branch_master b, k where b.client_family = k.fam and b.code_norm = k.cn order by (b.status = 'active') desc, b.verified_on desc limit 1),
act as (select a.* from bi.branch_activity a, k where a.fam = k.fam and a.code_norm = k.cn),
loc as (select coalesce((select location_id from mst), (select location_id from cs group by 1 order by count(*) desc limit 1)) id),
peer as (select percentile_cont(0.5) within group (order by a.n3 / 3.0) med, count(*) n
         from bi.branch_activity a join bi.client_branch_master b on b.client_family = a.fam and b.code_norm = a.code_norm and b.status = 'active', k
         where a.fam = k.fam and a.n3 > 0 and b.location_id = (select id from loc)),
cut3 as (select (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '2 months')::date c),
vc as (select v.* from bi.v_case v where v.case_id in (select case_id from cs where received_month >= (select c from cut3))),
vp as (select p.* from bi.v_point p where p.case_id in (select case_id from vc)),
lc as (select b.status, b.l3, b.p3, b.last_seen from bi.branch_lifecycle_rows(coalesce((select array_agg(distinct recon_unit) from cs), array[]::text[])) b, k
       where b.client_code in (select code from codes) and bi.norm_code(b.bcode) = k.cn order by b.total desc limit 1)
select jsonb_build_object(
  'client_family', (select fam from k), 'branch_code', f->>'branch_code',
  'master', (select jsonb_build_object('name', branch_name, 'ifsc', ifsc, 'address', address, 'district', district, 'state', state, 'pincode', pincode,
               'status', status, 'verification', verification_status, 'source', source, 'source_version', source_version, 'verified_on', verified_on,
               'first_seen', first_seen, 'type', branch_type) from mst),
  'location', (select label from bi.location where id = (select id from loc)),
  'months', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'cases', n) order by m), '[]'::jsonb) from mon),
  'activity', (select jsonb_build_object('first_month', first_m, 'last_month', last_m, 'cases_total', n, 'cases_last3', n3) from act),
  'peer_median_per_month', (select round(med::numeric, 1) from peer where n >= 5), 'peers', (select n from peer),
  'lifecycle', (select jsonb_build_object('status', status, 'last3m', l3, 'prior3m', p3, 'last_seen', last_seen) from lc),
  'coverage_status', case when (select last_m from act) is null then case when (select status from mst) = 'active' then 'never_activated' end
                          when (select last_m from act) >= (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date then 'active_6m' else 'gone_quiet_6m' end,
  'tat', jsonb_build_object('since', (select c from cut3),
     'case', (select jsonb_build_object('cases', count(*), 'completed', count(*) filter (where tat_flag = 'valid'), 'open', count(*) filter (where tat_flag = 'open'),
                'median', round(percentile_cont(0.5) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1),
                'p90', round(percentile_cont(0.9) within group (order by raw_tat_hours) filter (where tat_flag = 'valid')::numeric, 1),
                'sla_met_pct', round(avg(case when sla_met then 1.0 when sla_met = false then 0 end), 4), 'low_sample', count(*) filter (where tat_flag = 'valid') < 30) from vc),
     'document', (select jsonb_build_object('points', count(*) filter (where category = 'document'), 'n', count(doc_tat_hours),
                'median', round(percentile_cont(0.5) within group (order by doc_tat_hours)::numeric, 1), 'p90', round(percentile_cont(0.9) within group (order by doc_tat_hours)::numeric, 1),
                'low_sample', count(doc_tat_hours) < 30) from vp),
     'field', (select jsonb_build_object('points', count(*) filter (where category = 'field'), 'n', count(field_tat_hours),
                'median', round(percentile_cont(0.5) within group (order by field_tat_hours)::numeric, 1), 'p90', round(percentile_cont(0.9) within group (order by field_tat_hours)::numeric, 1),
                'low_sample', count(field_tat_hours) < 30) from vp),
     'tele', (select jsonb_build_object('points', count(*) filter (where category = 'tele'), 'n', count(tele_tat_hours), 'median', round(percentile_cont(0.5) within group (order by tele_tat_hours)::numeric, 1)) from vp)),
  'note', 'Force1 cases matched by client family and branch code (leading zeros ignored). Peer median = median monthly cases (last 3 months) of active branches of the same client in the same Crux location, shown when at least 5 exist. Status uses the branch priority rules (complete months); TAT covers cases received in the last 3 months and their points.')
$function$;

-- people: document and tele TAT next to field TAT (same definitions as the TAT section)
create or replace function bi.api_employees(p_month date, f jsonb default '{}'::jsonb)
returns jsonb language sql stable as $function$
select coalesce(jsonb_agg(x order by (x->>'points')::int desc),'[]') from (
 select jsonb_build_object('name',initcap(v.verified_by),'classification',coalesce(e.classification,'unclassified'),'override',coalesce(e.override,false),
   'points',count(*),'field',count(*) filter (where v.category='field'),'document',count(*) filter (where v.category='document'),'tele',count(*) filter (where v.category='tele'),
   'field_median_hours',round(percentile_cont(0.5) within group (order by v.field_tat_hours)::numeric,1),'field_tat_n',count(v.field_tat_hours),
   'doc_median_hours',round(percentile_cont(0.5) within group (order by v.doc_tat_hours)::numeric,1),'doc_tat_n',count(v.doc_tat_hours),
   'tele_median_hours',round(percentile_cont(0.5) within group (order by v.tele_tat_hours)::numeric,1),'tele_tat_n',count(v.tele_tat_hours),
   'units',string_agg(distinct v.recon_unit,', '),'verified_for_other_assignee',count(*) filter (where v.category='field' and v.assign_to is not null and v.assign_to<>v.verified_by)) x
 from bi.v_point v left join bi.employee e on e.name_key=v.verified_by
 where v.created_month=p_month and v.verified_by is not null and bi.loc_ok(v.location_id,v.recon_unit,f) and bi.fam_ok(v.client_code,f)
 group by v.verified_by, e.classification, e.override) q $function$;

-- public read entry point: new cases
do $$
declare d text := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
        anchor text := $a$when 'branch_detail' then$a$;
        addition text := $s$when 'drill_ops' then bi.api_drill_ops(m, f, coalesce(p_args->>'level', 'none'), coalesce(p_args->>'part', 'tat'))
      when 'tat_summary' then bi.tat_summary(m, f, coalesce(p_args->>'group', 'total'))
      $s$;
begin
  if position('when ''drill_ops''' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then raise exception 'anchor not unique'; end if;
  execute replace(d, anchor, addition || anchor);
end $$;
