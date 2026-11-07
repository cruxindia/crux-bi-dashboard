-- Applied to Supabase project via MCP on 20261107133702
-- Wave 101b (owner 7-Nov 18:56 IST: "organic is tagged as BAU and potential stays as potential as a driving factor and must be
-- shown everywhere"): the all-branch figure is called POTENTIAL again (bi_101a had renamed it "organic business"); potential
-- by branch manager added (team x client family -> manager at the data date; family-level assignments, client-specific
-- assignments are not split here).
do $m$
declare d text := pg_get_functiondef('bi.api_market_potential(date, jsonb)'::regprocedure); o text;
begin
  o := d; d := replace(d, 'Organic business = current business + headroom.', 'Potential = current business + headroom.');
  if d = o then raise exception 'edit 1'; end if; o := d;
  d := replace(d, 'the organic business (this figure) is what every client branch could bring', 'the potential (this figure) is what every client branch could bring');
  if d = o then raise exception 'edit 2'; end if; o := d;
  d := replace(d, E'  ''top'', (select', $q$  'by_bm', (select coalesce(jsonb_agg(o order by (o->>'potential')::numeric desc), '[]'::jsonb) from (select jsonb_build_object('manager', bm, 'current', round(coalesce(sum(revenue) filter (where grp = 'current'), 0)), 'recover', round(coalesce(sum(revenue) filter (where grp = 'recover'), 0)), 'dormant', round(coalesce(sum(revenue) filter (where grp = 'dormant'), 0)), 'never_served', round(coalesce(sum(revenue) filter (where grp = 'never_served'), 0)), 'extend_team', round(coalesce(sum(revenue) filter (where grp = 'extend_team'), 0)), 'extend_no_team', round(coalesce(sum(revenue) filter (where grp = 'extend_no_team'), 0)), 'new_client', round(coalesce(sum(revenue) filter (where grp = 'new_client'), 0)), 'headroom', round(coalesce(sum(revenue) filter (where grp <> 'current'), 0)), 'potential', round(coalesce(sum(revenue), 0)), 'penetration', round(coalesce(sum(revenue) filter (where grp = 'current'), 0) / nullif(sum(revenue), 0), 4), 'current_cases', round(coalesce(sum(cases) filter (where grp = 'current'), 0)), 'potential_cases', round(coalesce(sum(cases), 0)), 'active_branches', coalesce(sum(branches) filter (where grp = 'current'), 0), 'dormant_branches', coalesce(sum(branches) filter (where grp = 'dormant'), 0), 'never_branches', coalesce(sum(branches) filter (where grp in ('never_served', 'extend_team', 'extend_no_team', 'new_client')), 0), 'no_team_branches', coalesce(sum(branches) filter (where layer = 'never_no_team'), 0)) o from (select c.*, coalesce(case when c.location_id is not null then bi.branch_manager_code_at(c.location_id, c.client_family, coalesce((select as_of from run), (select month from run))) end, '(no team / not mapped)') bm from c) cb group by bm) q),
  'top', (select$q$);
  if d = o then raise exception 'edit 3'; end if;
  execute d;
end $m$;
