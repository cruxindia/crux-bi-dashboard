-- Applied to Supabase project via MCP on 20261014163212
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.api_branch_coverage(jsonb)'::regprocedure);
  d2 := replace(d, 'where (m.location_id is null and coalesce(f, ''{}''::jsonb) - ''client_family'' = ''{}''::jsonb or bi.loc_ok(m.location_id, l.recon_unit, f)) and bi.fam_ok(m.fam, f)),',
    'where (m.location_id is null and coalesce(f, ''{}''::jsonb) - ''client_family'' = ''{}''::jsonb
         or m.location_id in (select l2.id from bi.location l2 where bi.loc_ok(l2.id, l2.recon_unit, f)))
    and m.fam in (select r.family from bi.client_family_research r where bi.fam_ok(r.family, f) union select c2.family from bi.client c2 where bi.fam_ok(c2.family, f))),');
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;
