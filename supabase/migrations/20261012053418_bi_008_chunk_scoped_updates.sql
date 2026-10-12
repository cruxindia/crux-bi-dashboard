-- Applied to Supabase project via MCP on 20261012053418

do $$ declare d text; begin
  d := pg_get_functiondef('bi.commit_point(bigint)'::regprocedure);
  d := replace(d, 'and p.last_batch=p_batch and p.updated_at=now();', 'and p.point_id in (select point_id from _p);');
  d := replace(d, 'from bi.fact_point where last_batch=p_batch and updated_at=now() and point_type is not null', 'from _p where point_type is not null');
  if position('p.updated_at=now()' in d)>0 or position('select point_id from _p' in d)=0 or position('from _p where point_type' in d)=0 then raise exception 'point patch failed'; end if;
  execute d;
  d := pg_get_functiondef('bi.commit_case(bigint)'::regprocedure);
  d := replace(d, 'and c.last_batch=p_batch and c.updated_at=now();', 'and c.case_id in (select case_id from _n);');
  if position('c.updated_at=now()' in d)>0 or position('select case_id from _n' in d)=0 then raise exception 'case patch failed'; end if;
  execute d;
  d := pg_get_functiondef('bi.relocate_cases(bigint)'::regprocedure);
  d := replace(d, 'c.last_batch=p_batch and c.updated_at=now()', 'c.case_id in (select case_id from _n)');
  if position('c.updated_at=now()' in d)>0 then raise exception 'relocate patch failed'; end if;
  execute d;
end $$;
with o as (update bi.import_batch set status='rejected', notes='interrupted load (timeout)' where status='staged' returning id)
delete from bi.stg_row where batch_id in (select id from o);

