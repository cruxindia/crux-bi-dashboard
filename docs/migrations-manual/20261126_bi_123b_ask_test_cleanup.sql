-- Wave 123b (26-Nov-2026): delete the Ask Crux questions sent by the wave 123 live tests (18:15–19:40 IST), as after every live test
-- (OPERATIONS "After testing Ask Crux on the live site"). Only rows the tests created: the listed messages and conversations started by the
-- test script. Kept: the owner's own questions of 26-Nov (1343–1345, marked disputed by 123a) and 1351–1353 (not from the test script).
-- Run in the SQL editor: do $x$ declare s text; begin select content into s from bi.repo_file where path='docs/migrations-manual/20261126_bi_123b_ask_test_cleanup.sql'; execute s; end $x$;
do $c$
declare v_ids bigint[]; v_conv uuid[]; n_msg int; n_orig int; n_mem int; n_conv int;
begin
  v_conv := array['0c6df0bc-5963-473e-8494-f3e7f56768a3','312665cd-8bde-4711-9f5c-fe8cf99e869a','36d549aa-c851-4dc4-b5b0-1e2ef088020a','389e7c5a-8d85-4942-8fa1-58eccba1a49c','4502c244-d303-4b77-b443-c1d726b20c65','563dfa10-3c68-478b-847a-fc162a0202eb','66a19174-e667-4cc6-937e-fd64cbbd9c87','6f663bcb-62f3-442b-b272-8a42f31d4e16','71da73cc-22db-4828-939e-eaaadcb01070','73b10af6-7de0-4ef0-ae43-9bebe7463071','8951fedf-f608-4ea9-ab08-0422bb337f1b','8aa4acd8-1b67-4794-a28c-0d3713699f65','92072a35-b439-409e-8e6f-7dfc2ca984aa','95fe4e94-7418-4438-a880-f32609d576f1','96447ca0-9c1a-4cc2-b7ab-fefe37cc95f2','ae388916-1e15-4e27-b597-26f9fabde5cc','c99d2537-df34-426d-876f-7a0481a1621f','fe1900c9-03cf-4ac2-81dc-4b8ac66407a2','fecba426-20fa-42fe-8d0d-d45d11565429']::uuid[];
  select array_agg(id) into v_ids from bi.ai_message
   where (id in (1346,1347,1348,1349,1350,1354,1355,1356,1357,1358,1359,1360,1361,1362,1363,1364,1365,1366,1367,1368,1369,1370,1371,1372,1373,1374,1375,1376) or conversation_id = any (v_conv)) and id >= 1346 and id not in (1351, 1352, 1353);
  if coalesce(cardinality(v_ids), 0) > 40 then raise exception '123b: % messages matched, more than the tests sent — stop', cardinality(v_ids); end if;
  delete from bi.agent_memory where (evidence->>'message_id') ~ '^\d+$' and (evidence->>'message_id')::bigint = any (v_ids);
  get diagnostics n_mem = row_count;
  delete from bi.ask_origin where message_id = any (v_ids) or conversation_id = any (v_conv);
  get diagnostics n_orig = row_count;
  delete from bi.ai_message where id = any (v_ids);
  get diagnostics n_msg = row_count;
  delete from bi.ai_conversation c where c.id = any (v_conv) and not exists (select 1 from bi.ai_message m where m.conversation_id = c.id);
  get diagnostics n_conv = row_count;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values ('wave-123b', 'ai_test_cleanup', 'bi.ai_message', 'wave 123 live tests', jsonb_build_object('messages', n_msg, 'origins', n_orig, 'memory', n_mem, 'conversations', n_conv));
  raise notice '123b: % messages, % origins, % memory findings, % conversations deleted', n_msg, n_orig, n_mem, n_conv;
end $c$;
-- Then revoke the temporary key of 26-Nov (it also expires by itself at about 00:20 IST on 27-Nov):
update bi.ingest_token set revoked = true, expires_at = least(expires_at, now()) where label = 'wave 123 temp 26-Nov (revoke after)';
