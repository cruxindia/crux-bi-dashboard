-- Applied to Supabase project via MCP on 20261014142519
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  if position('''run_status''' in d) = 0 then
    d2 := replace(d, '  elsif op = ''source_get'' then', '  elsif op = ''run_status'' then
    return (select to_jsonb(j) from bi.job_run j where id = (p->>''run_id'')::bigint);
  elsif op = ''source_get'' then');
    if d2 = d then raise exception 'anchor'; end if;
    execute d2;
  end if;
end $$;
