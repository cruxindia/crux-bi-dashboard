-- Applied to Supabase project via MCP on 20261014140353
create or replace function public.bi_ai_gateway(p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public, extensions as $$
declare op text := p->>'op'; v_run uuid; used int; cap int;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'forbidden'; end if;
  if op = 'config' then
    return (select jsonb_object_agg(key, value) from bi.ai_config);
  elsif op = 'auth' then
    return jsonb_build_object('ok',
      exists (select 1 from bi.ingest_token t where t.token_hash = encode(extensions.digest(coalesce(p->>'token',''), 'sha256'), 'hex')
              and not t.revoked and t.expires_at > now()
              and t.scope = any (case when jsonb_typeof(p->'scopes') = 'array' then array(select jsonb_array_elements_text(p->'scopes')) else array['admin'] end)));
  elsif op = 'key_present' then
    update bi.ai_config set value = case when (p->>'present')::boolean then 'yes' else 'no' end, updated_at = now(), updated_by = 'edge'
     where key = 'KEY_PRESENT' and value is distinct from case when (p->>'present')::boolean then 'yes' else 'no' end;
    return jsonb_build_object('ok', true);
  elsif op = 'models' then
    v_run := coalesce((p->>'run_id')::uuid, gen_random_uuid());
    insert into bi.ai_model_check(run_id, provider, model, display_name, version, methods, input_token_limit, output_token_limit, role, test_ok, test_ms, test_note)
    select v_run, coalesce(m->>'provider', 'gemini'), m->>'model', m->>'display_name', m->>'version',
           array(select jsonb_array_elements_text(coalesce(m->'methods', '[]'))), nullif(m->>'input_token_limit','')::int,
           nullif(m->>'output_token_limit','')::int, m->>'role', (m->>'test_ok')::boolean, nullif(m->>'test_ms','')::int, left(m->>'test_note', 300)
    from jsonb_array_elements(coalesce(p->'models', '[]')) m;
    if coalesce(p->>'generation', '') <> '' then
      update bi.ai_config set value = p->>'generation', verified_at = now(), updated_at = now(), updated_by = 'models.list check',
        note = 'Validated: listed by models.list with generateContent and passed a synthetic request.' where key = 'GEMINI_MODEL';
    end if;
    if coalesce(p->>'embedding', '') <> '' then
      update bi.ai_config set value = p->>'embedding', verified_at = now(), updated_at = now(), updated_by = 'models.list check',
        note = 'Validated: listed by models.list with embedContent and returned a vector of the requested size.' where key = 'GEMINI_EMBEDDING_MODEL';
      update bi.kb_chunk set embedding = null, embed_model = null, embed_dim = null, embedded_at = null
       where embed_model is not null and embed_model <> p->>'embedding';
    end if;
    return jsonb_build_object('ok', true, 'run_id', v_run);
  elsif op = 'budget' then
    cap := coalesce(nullif((select value from bi.ai_config where key = case when p->>'purpose' = 'embed' then 'EMBED_DAILY_CAP' else 'AI_DAILY_CAP' end), '')::int, 200);
    select count(*) into used from bi.ai_provider_usage
     where at > date_trunc('day', now()) and (case when p->>'purpose' = 'embed' then purpose like 'embed%' else purpose not like 'embed%' end);
    return jsonb_build_object('ok', used < cap, 'used', used, 'cap', cap);
  elsif op = 'kb_pending' then
    return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'content', c.content) order by c.id)
      from (select c.* from bi.kb_chunk c join bi.kb_doc d on d.id = c.doc_id
            where d.retired_at is null and d.approved and c.active and (c.embedding is null or c.embed_model is distinct from p->>'model')
            order by c.id limit least(coalesce((p->>'limit')::int, 50), 100)) c), '[]');
  elsif op = 'kb_store' then
    update bi.kb_chunk c set embedding = (x->>'embedding')::extensions.vector, embed_model = p->>'model',
       embed_dim = (p->>'dim')::int, embedded_at = now()
      from jsonb_array_elements(coalesce(p->'items', '[]')) x where c.id = (x->>'id')::bigint;
    get diagnostics used = row_count;
    return jsonb_build_object('ok', true, 'stored', used);
  elsif op = 'kb_search' then
    return coalesce((select jsonb_agg(jsonb_build_object('title', d.title, 'kind', d.kind, 'source', d.source_ref, 'content', c.content,
              'similarity', round((1 - (c.embedding <=> (p->>'embedding')::extensions.vector))::numeric, 3)) order by c.embedding <=> (p->>'embedding')::extensions.vector)
      from (select * from bi.kb_chunk where embed_model = p->>'model' and embedding is not null and active
            order by embedding <=> (p->>'embedding')::extensions.vector limit least(coalesce((p->>'k')::int, 4), 8)) c
      join bi.kb_doc d on d.id = c.doc_id and d.retired_at is null and d.approved
      where 1 - (c.embedding <=> (p->>'embedding')::extensions.vector) >= coalesce((p->>'min_sim')::numeric, 0.5)), '[]');
  end if;
  raise exception 'unknown op %', op;
end $$;

create or replace function public.bi_ai_record(p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare cap int := coalesce(nullif(p->>'daily_cap','')::int, 200); used int;
begin
  if p->>'op' = 'budget' then
    select count(*) into used from bi.ai_provider_usage where provider = p->>'provider' and at > date_trunc('day', now()) and purpose not like 'embed%';
    return jsonb_build_object('ok', used < cap, 'used', used, 'cap', cap);
  end if;
  insert into bi.ai_provider_usage(provider, model, purpose, message_id, ok, ms, input_chars, output_chars, note, http_status, retries, prompt_tokens, output_tokens)
  values (p->>'provider', p->>'model', p->>'purpose', nullif(p->>'message_id','')::bigint, (p->>'ok')::boolean, (p->>'ms')::int,
          (p->>'in')::int, (p->>'out')::int, left(p->>'note', 300), nullif(p->>'http_status','')::int, nullif(p->>'retries','')::int,
          nullif(p->>'prompt_tokens','')::int, nullif(p->>'output_tokens','')::int);
  if (p->>'ok')::boolean and p->>'message_id' is not null and p ? 'narrative' then
    update bi.ai_message set provider = p->>'provider', model = p->>'model',
      answer = answer || jsonb_build_object('narrative', p->>'narrative', 'knowledge', coalesce(p->'knowledge', '[]'::jsonb))
     where id = (p->>'message_id')::bigint;
  end if;
  return jsonb_build_object('ok', true);
end $$;

alter table bi.ingest_token add column if not exists scope text not null default 'admin';
create or replace function bi.token_ok(p_token text)
returns boolean language sql stable security definer set search_path = bi, public, extensions as $$
  select p_token is not null and exists(select 1 from bi.ingest_token where token_hash = encode(extensions.digest(p_token,'sha256'),'hex')
         and not revoked and expires_at > now() and scope = 'admin') $$;

create or replace function bi.api_ai_status()
returns jsonb language sql stable security definer set search_path = bi, public as $$
select jsonb_build_object(
  'enabled', (select value from bi.ai_config where key = 'AI_ENABLED') = 'on',
  'key_present', (select value from bi.ai_config where key = 'KEY_PRESENT'),
  'model', (select value from bi.ai_config where key = 'GEMINI_MODEL'),
  'model_verified_at', (select verified_at from bi.ai_config where key = 'GEMINI_MODEL'),
  'embedding_model', nullif((select value from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL'), ''),
  'embedding_verified_at', (select verified_at from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL'),
  'daily_cap', (select value::int from bi.ai_config where key = 'AI_DAILY_CAP'),
  'today', (select jsonb_build_object('calls', count(*), 'ok', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
            'tokens', coalesce(sum(coalesce(prompt_tokens,0) + coalesce(output_tokens,0)), 0))
            from bi.ai_provider_usage where at > date_trunc('day', now())),
  'last_30d', (select jsonb_build_object('calls', count(*), 'ok', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
            'tokens', coalesce(sum(coalesce(prompt_tokens,0) + coalesce(output_tokens,0)), 0))
            from bi.ai_provider_usage where at > now() - interval '30 days'),
  'last_failure', (select jsonb_build_object('at', at, 'purpose', purpose, 'note', note) from bi.ai_provider_usage where not ok order by at desc limit 1),
  'knowledge', (select jsonb_build_object('documents', (select count(*) from bi.kb_doc where retired_at is null),
            'chunks', count(*), 'embedded', count(*) filter (where embedding is not null)) from bi.kb_chunk where active),
  'last_model_check', (select max(checked_at) from bi.ai_model_check))
$$;
