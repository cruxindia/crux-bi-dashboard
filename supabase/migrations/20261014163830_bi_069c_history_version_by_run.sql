-- Applied to Supabase project via MCP on 20261014163830
create or replace function bi.branch_lean_compact()
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare a int; b int; c int;
begin
  update bi.client_branch_master set source_url = null, source_version = null, updated_by = null,
         source = case source_type when 'rbi_ifsc_directory' then 'RBI IFSC directory' else 'Official website' end
   where source_type in ('rbi_ifsc_directory', 'official_website') and (source_url is not null or source_version is not null or updated_by is not null);
  get diagnostics a = row_count;
  update bi.client_branch_history set new = null where change_type = 'added' and new is not null;
  get diagnostics b = row_count;
  -- the source version of a history event is the version of its run (bi.job_run)
  update bi.client_branch_history h set source_version = null from bi.job_run j where j.id = h.run_id and h.source_version is not null and h.source_version = j.source_version;
  get diagnostics c = row_count;
  return jsonb_build_object('master_rows_compacted', a, 'history_rows_compacted', b, 'history_versions_by_run', c);
end $$;
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  d2 := replace(d, 'select branch_uid, v_fam, ''added'', v_run, v_ver from ins where not coalesce', 'select branch_uid, v_fam, ''added'', v_run, null from ins where not coalesce');
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;
