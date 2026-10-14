-- Applied to Supabase project via MCP on 20261014140323
create table if not exists bi.ai_config(
  key text primary key,
  value text not null default '',
  note text,
  verified_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by text);
alter table bi.ai_config enable row level security;
insert into bi.ai_config(key, value, note) values
 ('GEMINI_MODEL', 'gemini-flash-latest', 'Owner-supplied candidate. Replaced by the validated stable Flash model after the models.list check.'),
 ('GEMINI_EMBEDDING_MODEL', '', 'Set after the models.list check (must support embedContent).'),
 ('EMBED_DIM', '768', 'Requested output dimensionality; vectors are L2-normalised before storage.'),
 ('AI_ENABLED', 'on', 'on = Gemini rewords validated answers; off = deterministic answers only.'),
 ('AI_DAILY_CAP', '200', 'Max generation calls per UTC day, all users together.'),
 ('EMBED_DAILY_CAP', '600', 'Max embedding requests per UTC day.'),
 ('AI_TIMEOUT_MS', '20000', 'Per-request provider timeout.'),
 ('AI_MAX_RETRIES', '2', 'Retries on 429 / 5xx / timeout with capped backoff.'),
 ('KEY_PRESENT', 'unknown', 'Written by the Edge Function: whether GEMINI_API_KEY is configured (never the value).')
on conflict (key) do nothing;

alter table bi.ai_provider_usage
  add column if not exists http_status int,
  add column if not exists retries int,
  add column if not exists prompt_tokens int,
  add column if not exists output_tokens int;

create table if not exists bi.ai_model_check(
  id bigserial primary key,
  checked_at timestamptz not null default now(),
  run_id uuid not null,
  provider text not null,
  model text not null,
  display_name text,
  version text,
  methods text[],
  input_token_limit int,
  output_token_limit int,
  role text not null check (role in ('generation_candidate','embedding_candidate','selected_generation','selected_embedding','rejected')),
  test_ok boolean,
  test_ms int,
  test_note text);
alter table bi.ai_model_check enable row level security;
create index if not exists ai_model_check_run on bi.ai_model_check(run_id);

create table if not exists bi.kb_doc(
  id bigserial primary key,
  doc_key text not null unique,
  kind text not null check (kind in ('definition','method','procedure','qa','market')),
  title text not null,
  body text not null,
  source_ref text not null,
  approved boolean not null default true,
  content_hash text not null,
  updated_at timestamptz not null default now(),
  retired_at timestamptz);
alter table bi.kb_doc enable row level security;

create table if not exists bi.kb_chunk(
  id bigserial primary key,
  doc_id bigint not null references bi.kb_doc(id),
  chunk_no int not null,
  content text not null,
  content_hash text not null,
  embedding extensions.vector(768),
  embed_model text,
  embed_dim int,
  embedded_at timestamptz,
  active boolean not null default true,
  unique (doc_id, chunk_no));
alter table bi.kb_chunk enable row level security;

create or replace function bi.kb_put(p_key text, p_kind text, p_title text, p_body text, p_source text)
returns bigint language plpgsql security definer set search_path = bi, public, extensions as $$
declare v_id bigint; v_hash text := encode(extensions.digest(p_title || E'\n' || p_body, 'sha256'), 'hex'); v_old text;
  cur text := ''; n int := 0; para text; v_txt text;
begin
  select id, content_hash into v_id, v_old from bi.kb_doc where doc_key = p_key;
  if v_id is not null and v_old = v_hash then
    update bi.kb_doc set retired_at = null where id = v_id and retired_at is not null;
    return v_id;
  end if;
  insert into bi.kb_doc(doc_key, kind, title, body, source_ref, content_hash)
  values (p_key, p_kind, p_title, p_body, p_source, v_hash)
  on conflict (doc_key) do update set kind = excluded.kind, title = excluded.title, body = excluded.body,
     source_ref = excluded.source_ref, content_hash = excluded.content_hash, updated_at = now(), retired_at = null
  returning id into v_id;
  foreach para in array regexp_split_to_array(p_body || E'\n\n\u0001', E'\n\s*\n') loop
    if para = E'\u0001' or (length(cur) > 0 and length(cur) + length(para) > 1200) then
      if length(cur) > 0 then
        n := n + 1; v_txt := p_title || E'\n' || cur;
        insert into bi.kb_chunk(doc_id, chunk_no, content, content_hash, active)
        values (v_id, n, v_txt, encode(extensions.digest(v_txt, 'sha256'), 'hex'), true)
        on conflict (doc_id, chunk_no) do update set content = excluded.content, content_hash = excluded.content_hash, active = true,
          embedding = case when bi.kb_chunk.content_hash = excluded.content_hash then bi.kb_chunk.embedding end,
          embed_model = case when bi.kb_chunk.content_hash = excluded.content_hash then bi.kb_chunk.embed_model end,
          embed_dim = case when bi.kb_chunk.content_hash = excluded.content_hash then bi.kb_chunk.embed_dim end,
          embedded_at = case when bi.kb_chunk.content_hash = excluded.content_hash then bi.kb_chunk.embedded_at end;
      end if;
      cur := '';
      continue when para = E'\u0001';
    end if;
    cur := case when cur = '' then para else cur || E'\n\n' || para end;
  end loop;
  update bi.kb_chunk set active = false where doc_id = v_id and chunk_no > n and active;
  return v_id;
end $$;
