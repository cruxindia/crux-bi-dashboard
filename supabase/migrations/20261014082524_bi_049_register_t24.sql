-- Applied to Supabase project via MCP on 20261014082524
-- bi_049: register T24 (master imports, coverage, attrition) in the acceptance suite
do $do$
declare d text := pg_get_functiondef('bi.run_acceptance_tests()'::regprocedure);
begin
  if position('T24' in d) = 0 then
    d := replace(d, 'test:=''T23 daily update table commit and correction round-trip''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;',
      'test:=''T23 daily update table commit and correction round-trip''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;' || chr(10) || chr(10) ||
      '  -- T24 master imports (branch + workforce), coverage and attrition maths (rolled back)' || chr(10) ||
      '  j := bi.test_master_data();' || chr(10) ||
      '  test:=''T24 master data import, branch coverage and attrition''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;');
    if position('T24' in d) = 0 then raise exception 'run_acceptance_tests patch failed'; end if;
    execute d;
  end if;
end $do$;
