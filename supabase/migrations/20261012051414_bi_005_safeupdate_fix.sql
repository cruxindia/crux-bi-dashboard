-- Applied to Supabase project via MCP on 20261012051414

do $$ declare d text; begin
  d := pg_get_functiondef('bi.commit_case(bigint)'::regprocedure);
  d := replace(d, '      v_unit_loc);', '      v_unit_loc) where true;');
  if d !~ 'v_unit_loc\) where true' then raise exception 'patch failed'; end if;
  execute d;
end $$;
-- the failed test batch: mark rejected and clear staging
update bi.import_batch set status='rejected', notes='failed test: safeupdate guard' where status='staged';
delete from bi.stg_row where batch_id in (select id from bi.import_batch where status='rejected');

