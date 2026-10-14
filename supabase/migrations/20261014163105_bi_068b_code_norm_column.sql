-- Applied to Supabase project via MCP on 20261014163105
alter table bi.client_branch_master add column if not exists code_norm text generated always as (bi.norm_code(branch_code)) stored;
create index if not exists client_branch_master_fam_code on bi.client_branch_master(client_family, code_norm);
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.api_branch_coverage(jsonb)'::regprocedure);
  d2 := replace(d, 'and s.bk = bi.norm_code(m.branch_code)', 'and s.bk = m.code_norm');
  d2 := replace(d2, 'and not exists (select 1 from m where m.fam = s.fam and bi.norm_code(m.branch_code) = s.bk)', 'and not exists (select 1 from bi.client_branch_master b where b.client_family = s.fam and b.code_norm = s.bk)');
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;
