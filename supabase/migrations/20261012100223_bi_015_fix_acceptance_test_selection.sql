-- Applied to Supabase project via MCP on 20261012100223
do $$ declare d text; begin
 d := pg_get_functiondef('bi.run_acceptance_tests()'::regprocedure);
 d := replace(d, 'select case_id into d from bi.fact_point group by case_id having count(*) > 3 limit 1;',
   'select p.case_id into d from bi.fact_point p where exists (select 1 from bi.fact_case c where c.case_id=p.case_id) group by p.case_id having count(*) > 3 limit 1;');
 d := replace(d, $a$from bi.import_batch where file_name like 'Nashik_2026-07%' and status in ('committed','superseded');$a$,
   $a$from bi.import_batch where file_name like 'Nashik_2026-07%' and source_category='case' and status in ('committed','superseded');$a$);
 execute d; end $$;
