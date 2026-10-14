-- Applied to Supabase project via MCP on 20261014112838
create or replace function bi.test_penalty() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare loc int; d date := (select max(snapshot_date) from bi.zt_snapshot); a1 jsonb; a2 jsonb; rep jsonb; pub jsonb; v jsonb; rep2 jsonb; noreason text; ok boolean := false; err text;
begin
  select location_id into loc from bi.zt_row where snapshot_date = d and row_type = 'leaf' and location_id is not null order by sheet_row limit 1;
  begin
    begin perform bi.penalty_admin('test', jsonb_build_object('op', 'add', 'date', d, 'location_id', loc, 'amount', 500)); exception when others then noreason := sqlerrm; end;
    a1 := bi.penalty_admin('test', jsonb_build_object('op', 'add', 'date', d, 'location_id', loc, 'client_code', 'SBI', 'amount', '1,250.50', 'reason', 'T26 late report penalty', 'reference', 'L-1'));
    a2 := bi.penalty_admin('test', jsonb_build_object('op', 'add', 'date', d, 'location_id', loc, 'amount', 749.50, 'reason', 'T26 quality penalty'));
    rep := bi.api_penalty(d, '{}');
    pub := public.bi_call('penalty', jsonb_build_object('month', date_trunc('month', d)::date));
    v := bi.penalty_admin('test', jsonb_build_object('op', 'void', 'id', (a2->>'id')::bigint, 'reason', 'T26 entered twice'));
    rep2 := bi.api_penalty(d, '{}');
    ok := noreason like 'A reason%' and (a1->>'added')::boolean and (rep->'grand'->>'total')::numeric = 2000 and (rep->'grand'->>'count')::int = 2
      and (rep->'summary'->(loc::text)->>'total')::numeric = 2000
      and exists (select 1 from jsonb_array_elements(rep->'rows') r where r->>'date' = d::text and (r->>'total')::numeric = 2000)
      and (pub->>'reasons_hidden')::boolean and not exists (select 1 from jsonb_array_elements(pub->'entries') e where e ? 'reason')
      and (v->>'voided')::boolean and (rep2->'grand'->>'total')::numeric = 1250.50;
    raise exception 'rollback_t26';
  exception when others then err := sqlerrm;
  end;
  return jsonb_build_object('passed', ok and err = 'rollback_t26' and not exists (select 1 from bi.penalty where reason like 'T26%'),
    'missing_reason_error', noreason, 'grand', rep->'grand', 'after_cancel', rep2->'grand', 'public_reasons_hidden', pub->'reasons_hidden', 'error', nullif(err, 'rollback_t26'));
end $fn$;

do $do$
declare d text := pg_get_functiondef('bi.run_acceptance_tests()'::regprocedure);
begin
  if position('T26' in d) = 0 then
    d := replace(d, 'test:=''T25 mid-month rate change applies from its date only''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;',
      'test:=''T25 mid-month rate change applies from its date only''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;' || chr(10) || chr(10) ||
      '  -- T26 penalties: reason required, totals, cancel, public view hides reasons (rolled back)' || chr(10) ||
      '  j := bi.test_penalty();' || chr(10) ||
      '  test:=''T26 penalty sheet: admin entry with reason, totals and cancel''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;');
    if position('T26' in d) = 0 then raise exception 'run_acceptance_tests patch failed'; end if;
    execute d;
  end if;
end $do$;
