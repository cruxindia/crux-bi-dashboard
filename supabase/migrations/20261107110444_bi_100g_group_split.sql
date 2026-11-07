-- Applied to Supabase project via MCP on 20261107110444
-- Wave 100 (7-Nov-2026): the split inside each group (owner, 7-Nov 16:03 IST: "as a group it shows doing good but inside the
-- group max people are not performing good but only 1 or few are carrying the full burden so the split has to be seen").
-- Levels: zone -> teams (locations); branch manager -> accounts (location x client); team -> clients; team -> people (Force1).
-- Business levels compare each member with its own target to date (monthly target x the usual share of a month's business
-- reached by that working day); people are compared with the median of the same role in the same team (no targets exist).
create or replace function bi.api_split(p_month date, f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
declare v_lvl text := coalesce(nullif(p->>'level', ''), 'zone'); v_meas text := coalesce(nullif(p->>'measure', ''), 'revenue');
        v_req date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date;
        v_m date; v_asof date; v_share numeric := 1; v_k int; v_run bigint; r jsonb;
begin
  if v_lvl not in ('zone', 'bm', 'location', 'people') then raise exception 'level must be zone, bm, location or people'; end if;
  f := coalesce(f, '{}'::jsonb);
  if v_lvl = 'people' then
    select max(run) into v_run from bi.person_month;
    select max(month) into v_m from bi.person_month where run = v_run and month <= v_req and active_days > 0;
    with b as materialized (
      select coalesce(e.display_name, initcap(dm.val)) nm, coalesce(e.classification, 'unclassified') cls,
             pm.location_id, coalesce(l.label, pm.recon_unit, '(no location)') loc, pm.actions::numeric act, pm.active_wd
        from bi.person_month pm join bi.dim dm on dm.id = pm.emp_id
        left join bi.employee e on e.name_key = dm.val left join bi.location l on l.id = pm.location_id
       where pm.run = v_run and pm.month = v_m and pm.active_days > 0 and bi.loc_ok(pm.location_id, pm.recon_unit, f - 'client_family', v_m)),
    md as (select loc, cls, percentile_cont(0.5) within group (order by act) med from b group by 1, 2),
    mm as materialized (
      select b.loc || ' — ' || replace(b.cls, '_', ' ') grp, b.loc, b.cls, b.nm member, b.act, b.active_wd,
             b.act / nullif(sum(b.act) over (partition by b.loc, b.cls), 0) sh,
             b.act / nullif(md.med, 0) vs_med,
             row_number() over (partition by b.loc, b.cls order by b.act desc, b.nm) rk,
             count(*) over (partition by b.loc, b.cls) n,
             sum(b.act) over (partition by b.loc, b.cls order by b.act desc, b.nm rows unbounded preceding) cum,
             sum(b.act) over (partition by b.loc, b.cls) gact
        from b join md on md.loc = b.loc and md.cls = b.cls),
    g as (select grp, min(loc) loc, min(cls) cls, count(*) members, sum(act) act, max(member) filter (where rk = 1) top1,
                 max(sh) filter (where rk = 1) top1_share, min(rk) filter (where cum >= 0.5 * gact) n50,
                 sum(sh) filter (where rk <= ceil(n * 0.2)) top20_share,
                 percentile_cont(0.5) within group (order by act) med,
                 count(*) filter (where vs_med < 0.5) low, count(*) filter (where vs_med > 1.5) high
            from mm group by grp)
    select jsonb_build_object(
      'level', v_lvl, 'month', v_m, 'requested_month', v_req, 'measure', 'Force1 actions',
      'groups', coalesce((select jsonb_agg(jsonb_build_object('group', g.grp, 'location', g.loc, 'role', replace(g.cls, '_', ' '), 'members', g.members,
                 'total', g.act, 'top1', g.top1, 'top1_share', round(g.top1_share, 4), 'n50', g.n50,
                 'carry50', (select string_agg(member, ', ' order by rk) from mm where mm.grp = g.grp and mm.rk <= g.n50),
                 'top20_share', round(g.top20_share, 4), 'median', round(g.med::numeric, 1), 'low', g.low, 'high', g.high,
                 'carried', g.members >= 3 and (g.n50 = 1 or g.n50 <= ceil(g.members * 0.2)),
                 'flag', case when g.members >= 3 and (g.n50 = 1 or g.n50 <= ceil(g.members * 0.2)) then 'Carried by ' || g.n50 || ' of ' || g.members
                              when g.members >= 3 and g.low * 2 >= g.members then g.low || ' of ' || g.members || ' well below the team median' end)
                 order by g.act desc) from g), '[]'::jsonb),
      'members', coalesce((select jsonb_agg(jsonb_build_object('group', grp, 'member', member, 'role', replace(cls, '_', ' '), 'value', act,
                 'active_workdays', active_wd, 'per_day', round(act / nullif(active_wd, 0), 1), 'share', round(sh, 4),
                 'vs_median', round(vs_med::numeric, 2), 'rank', rk,
                 'status', case when vs_med < 0.5 then 'well below median' when vs_med > 1.5 then 'well above median' else 'around median' end)
                 order by grp, rk) from mm), '[]'::jsonb),
      'method', 'People: Force1 actions in the month (points created, verified or completed), each person in the team where most of their verified points were; compared within the same role (field executive / back office) in the same team. Carried = half of the team''s actions come from one person or from 20% of the people or fewer (teams of 3+). Well below median = under half the median of the same role in the same team. Force1 shows activity, not employment: leave, training or a role outside Force1 looks like low activity.')
      into r;
    return r;
  end if;

  select max(month) into v_m from bi.v_month_business where month <= v_req and coalesce(revenue, 0) > 0;
  select max(as_of) into v_asof from bi.v_month_business where month = v_m;
  if v_asof is not null and v_asof < (v_m + interval '1 month' - interval '1 day')::date then
    v_k := bi.workdays(v_m, v_asof);
    v_share := coalesce(bi.organic_share(v_m, v_k), v_k::numeric / nullif(bi.workdays(v_m, (v_m + interval '1 month' - interval '1 day')::date), 0), 1);
  end if;
  with b as materialized (
    select v.location_id, v.client_code, l.label loc, l.zone_group zg,
           case when v_meas = 'cases' then v.cases else v.revenue end act,
           case when v_meas = 'cases' then v.target_cases else v.revenue_target end tgt
      from bi.v_month_business v join bi.location l on l.id = v.location_id
     where v.month = v_m and bi.loc_ok(v.location_id, l.recon_unit, f, v_m) and bi.fam_ok(v.client_code, f)),
  mem as materialized (
    select case v_lvl when 'zone' then coalesce(zg, '(no zone)')
                      when 'bm' then coalesce(bi.branch_manager_code_at(location_id, client_code, coalesce(v_asof, (v_m + interval '1 month' - interval '1 day')::date)), '(not mapped)')
                      else loc end grp,
           case v_lvl when 'zone' then loc when 'bm' then loc || ' · ' || client_code else client_code end member,
           min(location_id) location_id, min(client_code) client_code,
           sum(coalesce(act, 0)) act, sum(coalesce(tgt, 0)) tgt
      from b group by 1, 2),
  mm as materialized (
    select m.*, m.tgt * v_share ttd, m.act / nullif(m.tgt * v_share, 0) ach,
           m.act / nullif(sum(m.act) over (partition by m.grp), 0) sh,
           row_number() over (partition by m.grp order by m.act desc, m.member) rk,
           count(*) over (partition by m.grp) n,
           sum(m.act) over (partition by m.grp order by m.act desc, m.member rows unbounded preceding) cum,
           sum(m.act) over (partition by m.grp) gact
      from mem m where m.act <> 0 or m.tgt <> 0),
  g as (select grp, count(*) members, sum(act) act, sum(tgt) tgt, sum(act) / nullif(sum(ttd), 0) ach,
               max(member) filter (where rk = 1) top1, max(sh) filter (where rk = 1) top1_share,
               min(rk) filter (where cum >= 0.5 * gact and gact > 0) n50, sum(sh) filter (where rk <= ceil(n * 0.2)) top20_share,
               percentile_cont(0.5) within group (order by ach) filter (where ach is not null) med_ach,
               count(*) filter (where ach >= 0.9) on_track, count(*) filter (where ach >= 0.6 and ach < 0.9) behind,
               count(*) filter (where ach < 0.6) far_behind, count(*) filter (where ach is null) no_target
          from mm group by grp)
  select jsonb_build_object(
    'level', v_lvl, 'month', v_m, 'requested_month', v_req, 'as_of', v_asof, 'measure', v_meas, 'share_to_date', round(v_share, 4),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('group', g.grp, 'members', g.members, 'actual', round(g.act), 'target', round(g.tgt),
               'achievement', round(g.ach, 4), 'top1', g.top1, 'top1_share', round(g.top1_share, 4), 'n50', g.n50,
               'carry50', (select string_agg(member, ', ' order by rk) from mm where mm.grp = g.grp and mm.rk <= g.n50),
               'top20_share', round(g.top20_share, 4), 'median_achievement', round(g.med_ach::numeric, 4),
               'on_track', g.on_track, 'behind', g.behind, 'far_behind', g.far_behind, 'no_target', g.no_target,
               'masked', g.ach >= 0.9 and (g.members - g.no_target) >= 3 and (g.behind + g.far_behind) * 2 > (g.members - g.no_target),
               'carried', g.members >= 3 and (g.n50 = 1 or g.n50 <= ceil(g.members * 0.2)),
               'flag', concat_ws('; ',
                  case when g.ach >= 0.9 and (g.members - g.no_target) >= 3 and (g.behind + g.far_behind) * 2 > (g.members - g.no_target)
                       then 'Group on track but ' || (g.behind + g.far_behind) || ' of ' || (g.members - g.no_target) || ' members behind' end,
                  case when g.ach < 0.9 and (g.members - g.no_target) >= 3 and (g.behind + g.far_behind) * 2 > (g.members - g.no_target)
                       then (g.behind + g.far_behind) || ' of ' || (g.members - g.no_target) || ' members behind' end,
                  case when g.members >= 3 and (g.n50 = 1 or g.n50 <= ceil(g.members * 0.2))
                       then 'Carried by ' || g.n50 || ' of ' || g.members end))
               order by g.act desc) from g), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object('group', grp, 'member', member, 'location_id', location_id, 'client_code', client_code,
               'value', round(act), 'target', round(tgt), 'target_to_date', round(ttd), 'achievement', round(ach, 4), 'share', round(sh, 4), 'rank', rk,
               'status', case when ach is null then 'no target' when ach >= 0.9 then 'on track' when ach >= 0.6 then 'behind' else 'far behind' end)
               order by grp, rk) from mm), '[]'::jsonb),
    'method', 'Each member is compared with its own target to date: monthly target x ' || round(v_share * 100, 1) || '% (the usual share of a month''s business reached by this working day' || case when v_share = 1 then ', month complete' else '' end || '). On track = 90% of target to date or more; behind = 60-90%; far behind = under 60%. Carried = half of the group''s ' || case when v_meas = 'cases' then 'cases' else 'revenue' end || ' comes from one member or from 20% of the members or fewer (groups of 3+). Flagged when more than half of the members with a target are behind, even if the group as a whole is on track. Zone members = teams (locations); branch manager members = accounts (location x client); team members = clients.')
    into r;
  return r;
end $fn$;
revoke all on function bi.api_split(date, jsonb, jsonb) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('bi.call_compute(text, jsonb)'::regprocedure);
begin
  if position('''split''' in d) > 0 then return; end if;
  if position('when ''organic'' then' in d) = 0 then raise exception 'call_compute anchor not found'; end if;
  d := replace(d, 'when ''organic'' then', 'when ''split'' then bi.api_split(m, f, coalesce(p_args->''p'', ''{}''::jsonb))
      when ''organic'' then');
  execute d;
end $m$;
