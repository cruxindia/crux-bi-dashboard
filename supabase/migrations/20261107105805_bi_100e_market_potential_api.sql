-- Applied to Supabase project via MCP on 20261107105805
create or replace function bi.api_market_potential(p_month date, f jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $fn$
with run as (select * from bi.potential_run where run_id = (select max(run_id) from bi.potential_run)),
cf as (select distinct client_family from bi.potential_cell where run_id = (select run_id from run) and layer = 'current' and revenue > 0),
c as (
  select c.layer, c.branches, c.cases, c.revenue, c.client_family, c.location_id, l.label location,
         coalesce(c.zone_group, l.zone_group) zg,
         case when c.layer in ('current', 'recover', 'dormant', 'never_served') then c.layer
              when cf.client_family is null then 'new_client'
              when c.layer = 'never_not_served' then 'extend_team' else 'extend_no_team' end grp
    from bi.potential_cell c join run on run.run_id = c.run_id
    left join bi.location l on l.id = c.location_id
    left join cf on cf.client_family = c.client_family
   where (f->>'client_family' is null or c.client_family = f->>'client_family')
     and case when c.location_id is not null then bi.loc_ok(c.location_id, null, coalesce(f, '{}'::jsonb))
              else coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb
                   or (f->>'location_id' is null and f->>'stakeholder' is null
                       and (f->>'zone_group' is null or c.zone_group = f->>'zone_group')
                       and (f->>'region' is null or exists (select 1 from bi.location lz where lz.zone_group = c.zone_group and lz.region = f->>'region'))) end),
t as (select p.*, b.branch_code, b.branch_name, coalesce(b.centre, b.city) city, b.district, b.state, l.label location,
             case when p.layer in ('dormant', 'never_served') then p.layer when cf.client_family is null then 'new_client'
                  when p.layer = 'never_not_served' then 'extend_team' else 'extend_no_team' end grp
        from bi.potential_top p join run on run.run_id = p.run_id
        left join bi.client_branch_master b on b.branch_uid = p.branch_uid
        left join bi.location l on l.id = p.location_id
        left join cf on cf.client_family = p.client_family
       where (f->>'client_family' is null or p.client_family = f->>'client_family')
         and case when p.location_id is not null then bi.loc_ok(p.location_id, null, coalesce(f, '{}'::jsonb))
                  else coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb
                       or (f->>'location_id' is null and f->>'stakeholder' is null
                           and (f->>'zone_group' is null or p.zone_group = f->>'zone_group')) end)
select jsonb_build_object(
  'month', (select month from run), 'as_of', (select as_of from run), 'computed_at', (select computed_at from run),
  'inputs', (select inputs from run),
  'total', (select jsonb_build_object('current', round(coalesce(sum(revenue) filter (where grp = 'current'), 0)), 'recover', round(coalesce(sum(revenue) filter (where grp = 'recover'), 0)), 'dormant', round(coalesce(sum(revenue) filter (where grp = 'dormant'), 0)), 'never_served', round(coalesce(sum(revenue) filter (where grp = 'never_served'), 0)), 'extend_team', round(coalesce(sum(revenue) filter (where grp = 'extend_team'), 0)), 'extend_no_team', round(coalesce(sum(revenue) filter (where grp = 'extend_no_team'), 0)), 'new_client', round(coalesce(sum(revenue) filter (where grp = 'new_client'), 0)), 'headroom', round(coalesce(sum(revenue) filter (where grp <> 'current'), 0)), 'potential', round(coalesce(sum(revenue), 0)), 'penetration', round(coalesce(sum(revenue) filter (where grp = 'current'), 0) / nullif(sum(revenue), 0), 4), 'current_cases', round(coalesce(sum(cases) filter (where grp = 'current'), 0)), 'potential_cases', round(coalesce(sum(cases), 0)), 'active_branches', coalesce(sum(branches) filter (where grp = 'current'), 0), 'dormant_branches', coalesce(sum(branches) filter (where grp = 'dormant'), 0), 'never_branches', coalesce(sum(branches) filter (where grp in ('never_served', 'extend_team', 'extend_no_team', 'new_client')), 0), 'no_team_branches', coalesce(sum(branches) filter (where layer = 'never_no_team'), 0)) from c),
  'by_zone', (select coalesce(jsonb_agg(o order by (o->>'potential')::numeric desc), '[]'::jsonb) from (select jsonb_build_object('zone_group', zg, 'current', round(coalesce(sum(revenue) filter (where grp = 'current'), 0)), 'recover', round(coalesce(sum(revenue) filter (where grp = 'recover'), 0)), 'dormant', round(coalesce(sum(revenue) filter (where grp = 'dormant'), 0)), 'never_served', round(coalesce(sum(revenue) filter (where grp = 'never_served'), 0)), 'extend_team', round(coalesce(sum(revenue) filter (where grp = 'extend_team'), 0)), 'extend_no_team', round(coalesce(sum(revenue) filter (where grp = 'extend_no_team'), 0)), 'new_client', round(coalesce(sum(revenue) filter (where grp = 'new_client'), 0)), 'headroom', round(coalesce(sum(revenue) filter (where grp <> 'current'), 0)), 'potential', round(coalesce(sum(revenue), 0)), 'penetration', round(coalesce(sum(revenue) filter (where grp = 'current'), 0) / nullif(sum(revenue), 0), 4), 'current_cases', round(coalesce(sum(cases) filter (where grp = 'current'), 0)), 'potential_cases', round(coalesce(sum(cases), 0)), 'active_branches', coalesce(sum(branches) filter (where grp = 'current'), 0), 'dormant_branches', coalesce(sum(branches) filter (where grp = 'dormant'), 0), 'never_branches', coalesce(sum(branches) filter (where grp in ('never_served', 'extend_team', 'extend_no_team', 'new_client')), 0), 'no_team_branches', coalesce(sum(branches) filter (where layer = 'never_no_team'), 0)) o from c group by zg) q),
  'by_location', (select coalesce(jsonb_agg(o order by (o->>'potential')::numeric desc), '[]'::jsonb) from (select jsonb_build_object('location_id', location_id, 'location', coalesce(location, 'No team yet'), 'zone_group', zg, 'current', round(coalesce(sum(revenue) filter (where grp = 'current'), 0)), 'recover', round(coalesce(sum(revenue) filter (where grp = 'recover'), 0)), 'dormant', round(coalesce(sum(revenue) filter (where grp = 'dormant'), 0)), 'never_served', round(coalesce(sum(revenue) filter (where grp = 'never_served'), 0)), 'extend_team', round(coalesce(sum(revenue) filter (where grp = 'extend_team'), 0)), 'extend_no_team', round(coalesce(sum(revenue) filter (where grp = 'extend_no_team'), 0)), 'new_client', round(coalesce(sum(revenue) filter (where grp = 'new_client'), 0)), 'headroom', round(coalesce(sum(revenue) filter (where grp <> 'current'), 0)), 'potential', round(coalesce(sum(revenue), 0)), 'penetration', round(coalesce(sum(revenue) filter (where grp = 'current'), 0) / nullif(sum(revenue), 0), 4), 'current_cases', round(coalesce(sum(cases) filter (where grp = 'current'), 0)), 'potential_cases', round(coalesce(sum(cases), 0)), 'active_branches', coalesce(sum(branches) filter (where grp = 'current'), 0), 'dormant_branches', coalesce(sum(branches) filter (where grp = 'dormant'), 0), 'never_branches', coalesce(sum(branches) filter (where grp in ('never_served', 'extend_team', 'extend_no_team', 'new_client')), 0), 'no_team_branches', coalesce(sum(branches) filter (where layer = 'never_no_team'), 0)) o from c group by location_id, location, zg) q),
  'by_client', (select coalesce(jsonb_agg(o order by (o->>'potential')::numeric desc), '[]'::jsonb) from (select jsonb_build_object('client_family', client_family, 'current', round(coalesce(sum(revenue) filter (where grp = 'current'), 0)), 'recover', round(coalesce(sum(revenue) filter (where grp = 'recover'), 0)), 'dormant', round(coalesce(sum(revenue) filter (where grp = 'dormant'), 0)), 'never_served', round(coalesce(sum(revenue) filter (where grp = 'never_served'), 0)), 'extend_team', round(coalesce(sum(revenue) filter (where grp = 'extend_team'), 0)), 'extend_no_team', round(coalesce(sum(revenue) filter (where grp = 'extend_no_team'), 0)), 'new_client', round(coalesce(sum(revenue) filter (where grp = 'new_client'), 0)), 'headroom', round(coalesce(sum(revenue) filter (where grp <> 'current'), 0)), 'potential', round(coalesce(sum(revenue), 0)), 'penetration', round(coalesce(sum(revenue) filter (where grp = 'current'), 0) / nullif(sum(revenue), 0), 4), 'current_cases', round(coalesce(sum(cases) filter (where grp = 'current'), 0)), 'potential_cases', round(coalesce(sum(cases), 0)), 'active_branches', coalesce(sum(branches) filter (where grp = 'current'), 0), 'dormant_branches', coalesce(sum(branches) filter (where grp = 'dormant'), 0), 'never_branches', coalesce(sum(branches) filter (where grp in ('never_served', 'extend_team', 'extend_no_team', 'new_client')), 0), 'no_team_branches', coalesce(sum(branches) filter (where layer = 'never_no_team'), 0)) o from c group by client_family) q),
  'top', (select coalesce(jsonb_agg(jsonb_build_object('group', grp, 'client_family', client_family, 'branch_code', branch_code, 'branch', branch_name,
                   'city', city, 'district', district, 'state', state, 'location', coalesce(location, 'No team yet'), 'zone_group', zone_group,
                   'cases', round(cases, 1), 'revenue', round(revenue), 'last_case_month', last_m) order by revenue desc), '[]'::jsonb)
           from (select * from t order by revenue desc, code_norm limit 40) z),
  'groups', jsonb_build_object(
     'current', 'Current business (latest month, projected to month end)',
     'recover', 'Back to own best: each location x client returns to its best three-month average since Apr-2024 (tracker history)',
     'dormant', 'Reactivate dormant branches: branches that sent cases since Jan-2026 but none in the last three months, at their own average while active',
     'never_served', 'Activate never-active branches of clients the team already serves',
     'extend_team', 'Extend a client Crux already has to a team that does not serve it yet',
     'extend_no_team', 'Extend a client Crux already has to branches in a zone with no Crux team for that area yet',
     'new_client', 'New clients: banks with no Crux business anywhere yet (needs empanelment)'),
  'method', 'Potential = current business + headroom. Universe: active, source-verified client branches and processing centres in the client branch master that can be matched by branch code (administrative offices and website-only lists excluded), plus Force1 branches not in the master. Active branch = at least one Force1 case in the last three months; dormant = cases since Jan-2026 but none in the last three months; never active = no Force1 case since Jan-2026. Never-active branches are valued at the median monthly cases of active branches of the same client in the same team (at least 5), else of the same client PAN India (at least 5), else of all active branches. Back-to-best uses the location x client tracker history (old tracker from Apr-2024 and the monthly trackers), less the dormant-branch value of the same location x client so nothing is counted twice. Revenue per case: the location x client rate in the latest month, else the client''s PAN India rate, else the overall rate. Team for branches in districts shared by two teams: the October-2026 tracker rule (OD-010). Organic is different: it is the trend expectation of the current business; potential is the market headroom across every branch. Indicative, not a forecast.')
$fn$;
revoke all on function bi.api_market_potential(date, jsonb) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('bi.call_compute(text, jsonb)'::regprocedure);
begin
  if position('''market_potential''' in d) > 0 then return; end if;
  if position('when ''organic'' then' in d) = 0 then raise exception 'call_compute anchor not found'; end if;
  d := replace(d, 'when ''organic'' then', 'when ''market_potential'' then bi.api_market_potential(m, f)
      when ''organic'' then');
  execute d;
end $m$;

select cron.schedule('bi-potential-refresh', '45 20,22 * * *', $c$set statement_timeout = '290s'; select bi.potential_refresh_if_stale()$c$);
