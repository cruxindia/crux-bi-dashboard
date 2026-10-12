-- Applied to Supabase project via MCP on 20261012113028
do $do$ declare d text; begin
 d := pg_get_functiondef('bi.run_acceptance_tests()'::regprocedure);
 if position('end $function$' in d) = 0 then raise exception 'function end not found'; end if;
 d := replace(d, 'end $function$', $blk$
  -- T19 Force1 utilisation: API totals = independent counts
  select (j2->'totals'->>'f1_field')::numeric, (j2->'totals'->>'manual_field')::numeric, (j2->'totals'->>'field_execs')::numeric,
         (j2->'totals'->>'back_office_staff')::numeric
    into a, b, c, d from (select bi.api_force1('2026-07-01','{}') j2) x;
  test:='T19 Force1 utilisation (field vs back office) reconciles';
  passed:= a = (select count(*) from bi.v_point where created_month='2026-07-01' and processing_route='in_force_by_field_executive')
       and b = (select count(*) from bi.v_point where created_month='2026-07-01' and processing_route='back_office_update_likely_outside_force')
       and c = (select count(distinct verified_by) from bi.v_point where created_month='2026-07-01' and verifier_class='field_executive')
       and d = (select count(distinct verified_by) from bi.v_point where created_month='2026-07-01' and verifier_class='back_office');
  detail:=jsonb_build_object('f1_field',a,'manual_field',b,'field_execs',c,'back_office_staff',d,'field_utilisation',round(a/nullif(a+b,0),4)); return next;
end $function$$blk$);
 execute d;
end $do$;
