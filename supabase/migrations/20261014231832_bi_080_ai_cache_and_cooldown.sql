-- Applied to Supabase project via MCP on 20261014231832
-- bi_080: Ask Crux reuses an already-checked AI summary for the same question, answer and data version (no provider call),
-- and every Edge Function instance skips the primary model for 15 minutes after it reported an exhausted quota (HTTP 429).
do $$
declare d text := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure); n text;
begin
  if position('narrative_cache' in d) > 0 then return; end if;
  n := regexp_replace(d, $r$return jsonb_build_object\('ok', used < cap, 'used', used, 'cap', cap\);(\s*)elsif op = 'kb_pending'$r$,
    $s$return jsonb_build_object('ok', used < cap, 'used', used, 'cap', cap,
      'primary_cool', exists (select 1 from bi.ai_provider_usage u where u.model = (select value from bi.ai_config where key = 'GEMINI_MODEL') and u.http_status = 429 and u.at > now() - interval '15 minutes'));
  elsif op = 'narrative_cache' then
    return (select jsonb_build_object('narrative', m.answer->>'narrative', 'model', m.model, 'message_id', m.id)
              from bi.ai_message m
             where lower(btrim(m.question)) = lower(btrim(p->>'question')) and m.answer->>'answer' = p->>'answer'
               and m.data_version is not distinct from nullif(p->>'data_version', '')::bigint and m.provider = 'gemini' and m.answer ? 'narrative'
             order by m.id desc limit 1);\1elsif op = 'kb_pending'$s$);
  if n = d then raise exception 'budget anchor not found'; end if;
  d := n;
  n := replace(d, $x$else purpose not like 'embed%' end$x$, $x$else purpose not like 'embed%' and purpose <> 'ask_cached' end$x$);
  if n = d then raise exception 'budget count anchor not found'; end if;
  execute n;
end $$;
