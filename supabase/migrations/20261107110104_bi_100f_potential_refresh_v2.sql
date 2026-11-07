-- Applied to Supabase project via MCP on 20261107110104
-- Wave 100: potential_refresh v2 — active = a case in the last three months (as bi_100d); branches whose Force1 cases sit on a
-- zone roll-up location take their team from the branch master / OD-010 rule; roll-up zone used as the zone otherwise.
create or replace function bi.potential_refresh() returns jsonb language plpgsql security definer
set search_path to 'bi', 'public' set statement_timeout to '280s' as $f$
declare v_m date; v_asof date; v_k int; v_share numeric := 1; v_run bigint; v_rate_all numeric; v_med_all numeric;
        v_t0 timestamptz := clock_timestamp(); v_tot jsonb; v_src bigint := bi.potential_source_version();
begin
  select max(month) into v_m from bi.v_month_business where coalesce(revenue, 0) > 0;
  if v_m is null then return jsonb_build_object('error', 'no tracker months'); end if;
  select max(as_of) into v_asof from bi.v_month_business where month = v_m;
  if v_asof is not null and v_asof < (v_m + interval '1 month' - interval '1 day')::date then
    v_k := bi.workdays(v_m, v_asof);
    v_share := coalesce(bi.organic_share(v_m, v_k), 1);
    if v_share <= 0.2 or v_share > 1 then v_share := 1; end if;
  end if;

  -- tracker history, location x client x month (latest month projected to month end)
  create temp table _pm on commit drop as
    select h.location_id, h.client_code, coalesce(c.family, h.client_code) fam, h.month,
           sum(coalesce(h.revenue, 0)) / case when h.month = v_m then v_share else 1 end rev,
           sum(coalesce(h.cases, 0)) / case when h.month = v_m then v_share else 1 end cases,
           sum(coalesce(h.target_cases, 0)) tgt
      from bi.v_month_business h left join bi.client c on c.code = h.client_code
     where h.location_id is not null and h.month <= v_m and h.month >= (v_m - interval '30 months')::date
     group by 1, 2, 3, 4;

  create temp table _pair on commit drop as
  with b as (select location_id, client_code, fam, min(month) m0 from _pm group by 1, 2, 3),
  d as (select b.location_id, b.client_code, b.fam, g::date mm, coalesce(p.rev, 0) rev, coalesce(p.cases, 0) cases, coalesce(p.tgt, 0) tgt
          from b cross join lateral generate_series(b.m0, v_m, interval '1 month') g
          left join _pm p on p.location_id = b.location_id and p.client_code = b.client_code and p.month = g::date),
  w as (select d.*, avg(rev) over w3 r3, avg(cases) over w3 c3, count(*) over w3 k
          from d window w3 as (partition by location_id, client_code order by mm rows between 2 preceding and current row))
  select location_id, client_code, fam,
         coalesce(max(rev) filter (where mm = v_m), 0) now_rev, coalesce(max(cases) filter (where mm = v_m), 0) now_cases,
         coalesce(max(tgt) filter (where mm = v_m), 0) tgt,
         max(r3) filter (where k = 3) best3_rev, max(c3) filter (where k = 3) best3_cases
    from w group by 1, 2, 3;

  create temp table _rate on commit drop as
    select location_id, fam, sum(now_rev) / nullif(sum(now_cases), 0) r from _pair where now_cases > 0 group by 1, 2;
  create temp table _frate on commit drop as
    select fam, sum(now_rev) / nullif(sum(now_cases), 0) r from _pair where now_cases > 0 group by 1;
  select sum(now_rev) / nullif(sum(now_cases), 0) into v_rate_all from _pair where now_cases > 0;

  -- Force1 branch activity with the team that handled most of its cases
  create temp table _act on commit drop as
  with s as materialized (
    select c.family fam, bi.norm_code(s.branch_code) code, s.location_id, s.received_month mm, count(*) n
      from bi.case_store s join bi.client c on c.code = s.client_code
     where s.branch_code is not null and s.received_month <= v_m group by 1, 2, 3, 4),
  lm as (select fam, code, location_id, sum(n) n from s group by 1, 2, 3),
  loc as (select distinct on (fam, code) fam, code, location_id from lm order by fam, code, (location_id is null), n desc, location_id)
  select s.fam, s.code, max(loc.location_id) location_id, max(s.mm) last_m, min(s.mm) first_m, sum(s.n) n, count(distinct s.mm) months,
         coalesce(sum(s.n) filter (where s.mm >= (v_m - interval '2 months')::date), 0) n3
    from s join loc on loc.fam = s.fam and loc.code = s.code group by 1, 2;

  -- verified, code-matchable client branch universe (same rules as Branch coverage), team from the master or the OD-010 rule
  create temp table _uni on commit drop as
    select distinct on (b.client_family, b.code_norm) b.branch_uid, b.client_family fam, b.code_norm code,
           coalesce(b.location_id, fr.location_id) location_id, b.zone_group
      from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid
     where b.status = 'active' and coalesce(b.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')
       and coalesce(b.source_type, '') <> 'official_website' and coalesce(b.branch_type, 'branch') <> 'office'
       and b.code_norm is not null and b.client_family is not null
     order by b.client_family, b.code_norm, (coalesce(b.location_id, fr.location_id) is null), b.branch_uid;

  -- a branch whose cases sit on a zone roll-up (e.g. Lucknow / ROUP Zone, shared by two teams) takes the team from the master
  -- or the OD-010 rule when it has one
  update _act a set location_id = u.location_id from _uni u, bi.location lr
   where lr.id = a.location_id and lr.is_rollup and u.fam = a.fam and u.code = a.code and u.location_id is not null;

  create temp table _peer on commit drop as
    select fam, location_id, percentile_cont(0.5) within group (order by n3 / 3.0) med, count(*) k from _act
     where last_m >= (v_m - interval '2 months')::date and n3 > 0 and location_id is not null group by 1, 2;
  create temp table _fpeer on commit drop as
    select fam, percentile_cont(0.5) within group (order by n3 / 3.0) med, count(*) k from _act
     where last_m >= (v_m - interval '2 months')::date and n3 > 0 group by 1;
  select percentile_cont(0.5) within group (order by n3 / 3.0) into v_med_all from _act
   where last_m >= (v_m - interval '2 months')::date and n3 > 0;

  -- client families each team already serves (latest month: cases or a target)
  create temp table _served on commit drop as
    select distinct location_id, fam from _pair where now_cases > 0 or tgt > 0;

  create temp table _br on commit drop as
  with x as (
    select 'dormant'::text layer, u.branch_uid, a.fam, a.code, coalesce(a.location_id, u.location_id) location_id,
           coalesce(l.zone_group, l.rollup_zone, u.zone_group) zone_group, a.n::numeric / greatest(a.months, 1) cases, a.last_m
      from _act a left join _uni u on u.fam = a.fam and u.code = a.code
      left join bi.location l on l.id = coalesce(a.location_id, u.location_id)
     where a.last_m < (v_m - interval '2 months')::date
    union all
    select case when u.location_id is null then 'never_no_team' when sv.fam is not null then 'never_served' else 'never_not_served' end,
           u.branch_uid, u.fam, u.code, u.location_id, coalesce(l.zone_group, u.zone_group),
           coalesce(case when pe.k >= 5 then pe.med end, case when fp.k >= 5 then fp.med end, v_med_all, 1)::numeric, null::date
      from _uni u left join _act a on a.fam = u.fam and a.code = u.code
      left join bi.location l on l.id = u.location_id
      left join _served sv on sv.location_id = u.location_id and sv.fam = u.fam
      left join _peer pe on pe.fam = u.fam and pe.location_id = u.location_id
      left join _fpeer fp on fp.fam = u.fam
     where a.fam is null)
  select x.*, x.cases * coalesce(case when x.layer in ('dormant', 'never_served') then r.r end, fr.r, v_rate_all) revenue
    from x left join _rate r on r.location_id = x.location_id and r.fam = x.fam left join _frate fr on fr.fam = x.fam;

  insert into bi.potential_run (month, as_of, inputs)
  values (v_m, v_asof, jsonb_build_object('share_to_date', round(v_share, 4), 'workday', v_k, 'rate_all', round(v_rate_all, 1),
          'median_cases_all', round(v_med_all::numeric, 2), 'tracker_pairs', (select count(*) from _pair),
          'force1_branches', (select count(*) from _act), 'universe', (select count(*) from _uni),
          'website_listed_excluded', (select count(*) from bi.client_branch_master where status = 'active' and source_type = 'official_website'),
          'source_version', v_src))
  returning run_id into v_run;

  insert into bi.potential_cell (run_id, zone_group, location_id, client_family, layer, branches, cases, revenue)
  select v_run, l.zone_group, p.location_id, p.fam, 'current', max(ac.k), sum(p.now_cases), sum(p.now_rev)
    from _pair p left join bi.location l on l.id = p.location_id
    left join (select location_id, fam, count(*) k from _act where last_m >= (v_m - interval '2 months')::date group by 1, 2) ac
           on ac.location_id = p.location_id and ac.fam = p.fam
   group by 2, 3, 4 having sum(p.now_rev) > 0 or sum(p.now_cases) > 0;

  insert into bi.potential_cell (run_id, zone_group, location_id, client_family, layer, branches, cases, revenue)
  select v_run, zone_group, location_id, fam, layer, count(*), sum(cases), sum(revenue) from _br group by 2, 3, 4, 5;

  insert into bi.potential_cell (run_id, zone_group, location_id, client_family, layer, branches, cases, revenue)
  select v_run, l.zone_group, g.location_id, g.fam, 'recover', null,
         greatest(g.c - coalesce(d.c, 0), 0), greatest(g.r - coalesce(d.r, 0), 0)
    from (select location_id, fam, sum(greatest(coalesce(best3_cases, 0) - now_cases, 0)) c, sum(greatest(coalesce(best3_rev, 0) - now_rev, 0)) r
            from _pair group by 1, 2) g
    left join (select location_id, fam, sum(cases) c, sum(revenue) r from _br where layer = 'dormant' group by 1, 2) d
           on d.location_id = g.location_id and d.fam = g.fam
    left join bi.location l on l.id = g.location_id
   where greatest(g.r - coalesce(d.r, 0), 0) > 0;

  insert into bi.potential_top (run_id, layer, zone_group, location_id, client_family, branch_uid, code_norm, cases, revenue, last_m)
  select v_run, layer, zone_group, location_id, fam, branch_uid, code, cases, revenue, last_m
    from (select b.*, row_number() over (partition by layer, zone_group, location_id order by revenue desc, code) r1,
                 row_number() over (partition by layer, fam order by revenue desc, code) r2 from _br b) z
   where r1 <= 25 or r2 <= 25;

  delete from bi.potential_cell where run_id < v_run;
  delete from bi.potential_top where run_id < v_run;

  select jsonb_object_agg(layer, jsonb_build_object('branches', b, 'cases', round(c), 'revenue', round(r))) into v_tot
    from (select layer, sum(branches) b, sum(cases) c, sum(revenue) r from bi.potential_cell where run_id = v_run group by 1) q;
  update bi.potential_run set totals = v_tot where run_id = v_run;

  insert into bi.refresh_state (name, refreshed_at, source_version, rows, ms)
  values ('potential', now(), v_src, (select count(*) from bi.potential_cell where run_id = v_run),
          (extract(epoch from clock_timestamp() - v_t0) * 1000)::int)
  on conflict (name) do update set refreshed_at = excluded.refreshed_at, source_version = excluded.source_version,
                                   rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('run_id', v_run, 'month', v_m, 'as_of', v_asof, 'totals', v_tot,
                            'ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::int);
end $f$;
