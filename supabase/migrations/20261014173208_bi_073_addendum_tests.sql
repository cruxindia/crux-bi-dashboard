-- Applied to Supabase project via MCP on 20261014173208
-- bi_073: acceptance tests for the addendum (branch master, monthly monitor, research completeness, AI gateway, Ask Crux).
-- Every test that writes runs inside a sub-transaction that is rolled back.
create or replace function bi.run_addendum_tests()
returns table(test text, passed boolean, detail jsonb)
language plpgsql security definer set search_path to 'bi', 'public', 'extensions' as $function$
declare j jsonb; j2 jsonb; j3 jsonb; v_run bigint; n int; ok boolean; err text; c jsonb; r jsonb; t record; s1 timestamptz; s2 timestamptz;
        row1 jsonb := jsonb_build_array(jsonb_build_object('uid', 'TEST:T29', 'code', 'T29X', 'name', 'T29 TEST BRANCH', 'address', 'TEST ROAD, PUNE 411001',
                        'district', 'PUNE', 'state', 'MAHARASHTRA', 'branch_type', 'branch'));
begin
  -- T29 monitor apply: a new source branch is added once with history; re-applying the same source changes nothing
  ok := false; err := null;
  begin
    v_run := (bi.branch_admin('test', jsonb_build_object('op', 'run_start', 'job', 'test_branch_monitor', 'trigger', 'acceptance_test', 'source_version', 'T29', 'force', true))->>'run_id')::bigint;
    j := bi.branch_admin('test', jsonb_build_object('op', 'apply', 'run_id', v_run, 'family', 'SBI', 'source_type', 'rbi_ifsc_directory', 'source_version', 'T29', 'rows', row1));
    j2 := bi.branch_admin('test', jsonb_build_object('op', 'apply', 'run_id', v_run, 'family', 'SBI', 'source_type', 'rbi_ifsc_directory', 'source_version', 'T29', 'rows', row1));
    select count(*) into n from bi.client_branch_history where branch_uid = 'TEST:T29';
    ok := (j->>'added')::int = 1 and (j2->>'added')::int = 0 and (j2->>'updated')::int = 0 and (j2->>'unchanged')::int = 1 and n = 1
          and exists (select 1 from bi.client_branch_master where branch_uid = 'TEST:T29' and location_id = (select id from bi.location where label = 'Pune') and verification_status = 'source_verified');
    raise exception 'rollback_t29';
  exception when others then err := sqlerrm; end;
  test := 'T29 monitor apply adds a new source branch once, with history; re-run is idempotent';
  passed := ok and err = 'rollback_t29' and not exists (select 1 from bi.client_branch_master where branch_uid = 'TEST:T29');
  detail := jsonb_build_object('first', j, 'second', j2, 'history_rows', n, 'error', nullif(err, 'rollback_t29')); return next;

  -- T30 failed or unreadable source: review item, nothing marked missing, master not marked current
  ok := false; err := null; s1 := (select max(finished_at) from bi.job_run where job = 'branch_monitor' and status = 'succeeded');
  begin
    v_run := (bi.branch_admin('test', jsonb_build_object('op', 'run_start', 'job', 'test_branch_monitor', 'trigger', 'acceptance_test', 'source_version', 'T30', 'force', true))->>'run_id')::bigint;
    select count(*) into n from bi.client_branch_master where client_family = 'AXIS' and status = 'active';
    j := bi.branch_admin('test', jsonb_build_object('op', 'finish_family', 'run_id', v_run, 'family', 'AXIS', 'source_type', 'rbi_ifsc_directory', 'source_version', 'T30', 'ok', false, 'error', jsonb_build_object('error', 'simulated outage')));
    ok := (j->>'ok')::boolean = false
          and (select count(*) from bi.client_branch_master where client_family = 'AXIS' and status = 'active') = n
          and exists (select 1 from bi.branch_review where client_family = 'AXIS' and issue = 'source_unavailable' and status = 'open');
    raise exception 'rollback_t30';
  exception when others then err := sqlerrm; end;
  s2 := (select max(finished_at) from bi.job_run where job = 'branch_monitor' and status = 'succeeded');
  test := 'T30 source failure opens a review, changes no branch and does not refresh "last successful run"';
  passed := ok and err = 'rollback_t30' and s1 is not distinct from s2;
  detail := jsonb_build_object('result', j, 'active_axis', n, 'error', nullif(err, 'rollback_t30')); return next;

  -- T31 territory lookup: district rule, unknown state
  select row_to_json(x)::jsonb into j from bi.territory_of('MAHARASHTRA'::text, 'PUNE'::text, null::text) x;
  select row_to_json(x)::jsonb into j2 from bi.territory_of('NOWHERE'::text, 'X'::text, null::text) x;
  test := 'T31 territory lookup maps a district to its Crux location and leaves unknown places unmapped';
  passed := (j->>'location_id')::int = (select id from bi.location where label = 'Pune') and j->>'basis' is not null and j2 is null;
  detail := jsonb_build_object('pune', j, 'unknown', j2); return next;

  -- T32 coverage totals reconcile with the by-client rows
  c := bi.api_branch_coverage('{}');
  select coalesce(sum((x->>'verified_active')::int), 0) sv, coalesce(sum((x->>'active_with_crux_6m')::int), 0) sa, coalesce(sum((x->>'never_activated')::int), 0) sn
    into t from jsonb_array_elements(c->'by_client') x;
  test := 'T32 branch coverage totals = sum of clients; coverage = active ÷ verified';
  passed := (c->'totals'->>'verified_active')::int = t.sv
        and (c->'totals'->>'active_with_crux_6m')::int <= (c->'totals'->>'verified_active')::int
        and abs((c->'totals'->>'coverage_6m')::numeric - round((c->'totals'->>'active_with_crux_6m')::numeric / nullif((c->'totals'->>'verified_active')::numeric, 0), 4)) < 0.0001;
  detail := jsonb_build_object('totals', c->'totals', 'sum_verified_by_client', t.sv); return next;

  -- T33 research completeness adds up
  r := bi.api_branch_research('{}');
  select coalesce(sum(value::int), 0) into n from jsonb_each_text(r->'by_status');
  test := 'T33 research completeness: statuses add up to clients × live locations';
  passed := n = (r->>'combinations')::int and (r->>'combinations')::int = (r->>'clients_in_scope')::int * (r->>'live_locations')::int
        and (r->>'researched')::int = coalesce((r->'by_status'->>'verified')::int, 0) + coalesce((r->'by_status'->>'researched_none_in_territory')::int, 0) + coalesce((r->'by_status'->>'not_applicable')::int, 0);
  detail := jsonb_build_object('by_status', r->'by_status', 'combinations', r->'combinations', 'clients', r->'clients_in_scope', 'locations', r->'live_locations', 'researched', r->'researched'); return next;

  -- T34 service-only RPCs refuse other callers; the job token cannot act as an admin key
  ok := true;
  begin perform public.bi_ai_gateway('{"op":"config"}'); ok := false; exception when others then if sqlerrm !~* 'forbidden' then ok := false; end if; end;
  begin perform public.bi_branch_job('{"op":"scope"}'); ok := false; exception when others then if sqlerrm !~* 'forbidden' then ok := false; end if; end;
  test := 'T34 AI gateway and job RPCs refuse non-service callers; job token is not an admin key';
  passed := ok and not bi.admin_ok((select decrypted_secret from vault.decrypted_secrets where name = 'bi_job_token' limit 1))
            and exists (select 1 from vault.decrypted_secrets where name = 'bi_job_token');
  detail := jsonb_build_object('note', 'secret values are never returned'); return next;

  -- T35 knowledge base: every active chunk embedded with the configured model and dimension
  test := 'T35 RAG chunks embedded with the configured model and dimension';
  passed := not exists (select 1 from bi.kb_chunk where active and (embedding is null or embed_model is distinct from (select value from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL')
                 or embed_dim is distinct from (select value::int from bi.ai_config where key = 'EMBED_DIM')))
        and exists (select 1 from bi.kb_chunk where active);
  detail := jsonb_build_object('active_chunks', (select count(*) from bi.kb_chunk where active), 'model', (select value from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL')); return next;

  -- T36 Ask Crux SQL answer states its scope and uses the dashboard's figures (rolled back: no conversation kept)
  ok := false; err := null;
  begin
    j := public.bi_ask('How is Gujarat doing this month?', '{}', null);
    ok := j->>'answer' like 'Scope: Gujarat%' and j->>'scope' is not null;
    raise exception 'rollback_t36';
  exception when others then err := sqlerrm; end;
  test := 'T36 Ask Crux answer carries its scope (zone filter parsed)';
  passed := ok and err = 'rollback_t36';
  detail := jsonb_build_object('answer', left(j->>'answer', 200), 'intent', j->>'intent', 'error', nullif(err, 'rollback_t36')); return next;
end $function$;
