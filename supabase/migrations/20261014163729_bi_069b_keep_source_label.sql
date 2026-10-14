-- Applied to Supabase project via MCP on 20261014163729
create or replace function bi.branch_lean_compact()
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare a int; b int;
begin
  update bi.client_branch_master set source_url = null, source_version = null, updated_by = null,
         source = case source_type when 'rbi_ifsc_directory' then 'RBI IFSC directory' else 'Official website' end
   where source_type in ('rbi_ifsc_directory', 'official_website') and (source_url is not null or source_version is not null or updated_by is not null);
  get diagnostics a = row_count;
  update bi.client_branch_history set new = null where change_type = 'added' and new is not null;
  get diagnostics b = row_count;
  return jsonb_build_object('master_rows_compacted', a, 'history_rows_compacted', b);
end $$;
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  d2 := replace(d, 'branch_type, location_id, zone_group, territory_basis, status, source_type, verified_on, first_seen, last_seen, last_seen_run,',
                   'branch_type, location_id, zone_group, territory_basis, status, source, source_type, verified_on, first_seen, last_seen, last_seen_run,');
  d2 := replace(d2, 'i.branch_type, i.location_id, i.zone_group, i.basis, ''active'', v_st, current_date, current_date, current_date, v_run,',
                    'i.branch_type, i.location_id, i.zone_group, i.basis, ''active'', case v_st when ''rbi_ifsc_directory'' then ''RBI IFSC directory'' else ''Official website'' end, v_st, current_date, current_date, current_date, v_run,');
  if d2 = d or position('''active'', case v_st' in d2) = 0 then raise exception 'anchor'; end if;
  execute d2;
end $$;
