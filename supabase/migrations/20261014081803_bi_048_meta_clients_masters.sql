-- Applied to Supabase project via MCP on 20261014081803
-- bi_048: api_meta lists valid clients (for upload templates) and master-data row counts
do $do$
declare d text := pg_get_functiondef('bi.api_meta()'::regprocedure);
begin
  if position('''clients''' in d) = 0 then
    d := replace(d, ' ''client_families'',(select jsonb_agg(distinct family) from bi.client),',
      ' ''client_families'',(select jsonb_agg(distinct family) from bi.client),' || chr(10) ||
      ' ''clients'',(select jsonb_agg(jsonb_build_object(''code'',code,''label'',label,''family'',family) order by code) from bi.client),' || chr(10) ||
      ' ''masters'',jsonb_build_object(''branch_rows'',(select count(*) from bi.client_branch_master),''branch_last_update'',(select max(updated_at) from bi.client_branch_master),''workforce_rows'',(select count(*) from bi.workforce_master),''workforce_last_update'',(select max(updated_at) from bi.workforce_master)),');
    if position('''clients''' in d) = 0 then raise exception 'api_meta patch failed'; end if;
    execute d;
  end if;
end $do$;
