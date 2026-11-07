-- Applied to Supabase project via MCP on 20261107105011
-- Wave 100: branch coverage reads the OD-010 family rule for branches in shared districts (bi_100a). Text edits with guards.
do $m$
declare d text := pg_get_functiondef('bi.api_branch_coverage(jsonb)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, E'  from bi.branch_cov_mv v\n  left join bi.branch_activity a',
    E'  from (select m.branch_uid, m.fam, coalesce(m.location_id, fr.location_id) location_id, m.code_norm, m.client_code, m.branch_code, m.vs, m.status, m.website\n          from bi.branch_cov_mv m left join bi.v_branch_family_rule fr on fr.branch_uid = m.branch_uid) v\n  left join bi.branch_activity a');
  if d = o then raise exception 'coverage edit 1 not applied'; end if; o := d;
  d := replace(d, 'from na join bi.client_branch_master b on b.branch_uid = na.branch_uid left join bi.location l on l.id = b.location_id)',
    'from na join bi.client_branch_master b on b.branch_uid = na.branch_uid left join bi.v_branch_family_rule fr2 on fr2.branch_uid = b.branch_uid left join bi.location l on l.id = coalesce(b.location_id, fr2.location_id))');
  if d = o then raise exception 'coverage edit 2 not applied'; end if; o := d;
  d := replace(d, 'until reviewed and excluded from coverage.'')',
    'until reviewed and excluded from coverage. Districts shared by two Crux teams (Nagpur; Lucknow and the rest of UP): a branch belongs to the team that handles its client in the October-2026 tracker (both teams: the larger target); other clients there have no team yet and are counted under the zone.'')');
  if d = o then raise exception 'coverage edit 3 not applied'; end if;
  execute d;
end $m$;

