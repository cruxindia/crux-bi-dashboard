-- Applied to Supabase project via MCP on 20261014075357
create or replace function bi.test_matrix_roundtrip() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $$
declare s date := (select max(snapshot_date) from bi.zt_snapshot); d date; cells jsonb; v jsonb; c1 jsonb; c2 jsonb; r jsonb; pan numeric; expect numeric;
        arch int; newval numeric; oldval numeric; loc text; cli text; ok boolean := false; err text;
begin
  d := s + 1; if extract(isodow from d) = 7 then d := d + 1; end if;
  select jsonb_agg(jsonb_build_object('date', d, 'location', location_label, 'client', client_label, 'mtd', mtd_cases + case when sheet_row = (select min(sheet_row) from bi.zt_row where snapshot_date = s and row_type = 'leaf') then 5 else 0 end))
    into cells from bi.zt_row where snapshot_date = s and row_type = 'leaf';
  select location_label, client_label, mtd_cases into loc, cli, oldval from bi.zt_row where snapshot_date = s and row_type = 'leaf' order by sheet_row limit 1;
  begin
    perform bi.matrix_save('test', jsonb_build_object('cells', cells, 'control', jsonb_build_array(jsonb_build_object('date', d, 'mtd', (select sum(mtd_cases) + 5 from bi.zt_row where snapshot_date = s and row_type = 'leaf')))));
    v := bi.matrix_validate(d);
    c1 := bi.matrix_commit('test', d, true, 'acceptance test T23');
    select (x->>'mtd')::numeric into pan from jsonb_array_elements(bi.api_tracker_sheet(d, '{}', null, 0)->'rows') x where x->>'t' = 'summary' and lower(x->>'loc') = 'pan india';
    expect := (select sum(mtd_cases) from bi.zt_row where snapshot_date = s and row_type = 'leaf') + 5;
    r := bi.matrix_reopen('test', d, 'acceptance test correction');
    perform bi.matrix_save('test', jsonb_build_object('cells', jsonb_build_array(jsonb_build_object('date', d, 'location', loc, 'client', cli, 'mtd', oldval + 7)),
                                                       'control', jsonb_build_array(jsonb_build_object('date', d, 'mtd', expect + 2))));
    c2 := bi.matrix_commit('test', d, true, 'acceptance test correction');
    select count(*) into arch from bi.zt_snapshot_archive where snapshot_date = d;
    select mtd_cases into newval from bi.zt_row where snapshot_date = d and row_type = 'leaf' and location_label = loc and client_label = cli;
    ok := (v->>'errors')::int = 0 and (c1->>'committed')::boolean and pan = expect and (r->>'reopened')::boolean
          and (c2->>'committed')::boolean and (c2->>'correction')::boolean and (c2->>'changed')::int = 1 and arch = 1 and newval = oldval + 7
          and not exists (select 1 from bi.zt_reopen where snapshot_date = d and active);
    raise exception 'rollback_t23';
  exception when others then
    err := sqlerrm;
  end;
  return jsonb_build_object('passed', ok and err = 'rollback_t23', 'date', d, 'validation_errors', v->'errors', 'validation_warnings', v->'warnings', 'commit', c1, 'pan_india_after_commit', pan, 'expected', expect,
     'correction', c2, 'archived_versions', arch, 'corrected_value', newval, 'original_value', oldval, 'error', nullif(err, 'rollback_t23'));
end $$;

do $do$
declare d text := pg_get_functiondef('bi.run_acceptance_tests'::regproc);
begin
  if position('T23' in d) = 0 then
    d := replace(d, E'detail:=j; return next;\nend $function$',
      E'detail:=j; return next;\n\n  -- T23 daily update table: enter, validate, commit, reopen, correct, archive (rolled back)\n  j := bi.test_matrix_roundtrip();\n  test:=''T23 daily update table commit and correction round-trip''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;\nend $function$');
    if position('T23' in d) = 0 then raise exception 'T23 patch failed'; end if;
    execute d;
  end if;
end $do$;
