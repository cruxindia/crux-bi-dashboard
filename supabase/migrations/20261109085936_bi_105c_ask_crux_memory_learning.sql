-- Applied to Supabase project via MCP on 20261109085936
-- wave 105c (owner 9-Nov-2026 14:26): Ask Crux memory and learning from feedback (see repo migration file for the full note).
alter table bi.ai_message
  add column if not exists q_embedding extensions.vector(768),
  add column if not exists ctx_key text,
  add column if not exists mode text,
  add column if not exists reuse_of bigint,
  add column if not exists plan jsonb,
  add column if not exists lesson_active boolean not null default true,
  add column if not exists reuse_ok boolean not null default true;
comment on column bi.ai_message.q_embedding is 'wave 105c: embedding of the question with names replaced by stable codes (Ask Crux memory)';
comment on column bi.ai_message.ctx_key is 'wave 105c: page month | filters | viewer/admin — answers are reused only in the same context';
comment on column bi.ai_message.mode is 'wave 105c: fresh | adapted (earlier answer updated with re-run look-ups) | reused (earlier answer returned, no AI call)';
comment on column bi.ai_message.reuse_of is 'wave 105c: the earlier message an adapted or reused answer came from';
comment on column bi.ai_message.plan is 'wave 105c: the look-ups (tool + arguments, names as stable codes) that produced the answer; re-run when adapting';
comment on column bi.ai_message.lesson_active is 'wave 105c: a 👎 correction on this message is shown to the AI as a lesson for similar questions (admin can switch off)';
comment on column bi.ai_message.reuse_ok is 'wave 105c: false = never reuse or adapt this answer (admin)';

create or replace function bi.ai_agent_log(p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public, extensions as $f$
declare c uuid := nullif(p->>'conversation_id', '')::uuid; mid bigint;
begin
  if c is null or not exists (select 1 from bi.ai_conversation x where x.id = c) then
    insert into bi.ai_conversation(context) values (coalesce(p->'context', '{}'::jsonb)) returning id into c;
  end if;
  insert into bi.ai_message(conversation_id, question, intent, filters, answer, data_version, provider, model, trace, q_embedding, ctx_key, mode, reuse_of, plan)
  values (c, left(coalesce(p->>'question', ''), 500), coalesce(p->>'intent', 'agent'), coalesce(p->'filters', '{}'::jsonb), coalesce(p->'answer', '{}'::jsonb),
          bi.cache_version(), p->>'provider', p->>'model', p->'trace', nullif(p->>'embedding', '')::extensions.vector, p->>'ctx_key',
          coalesce(nullif(p->>'mode', ''), 'fresh'), nullif(p->>'reuse_of', '')::bigint, p->'plan')
  returning id into mid;
  return jsonb_build_object('message_id', mid, 'conversation_id', c);
end $f$;
revoke all on function bi.ai_agent_log(jsonb) from public, anon, authenticated;

create or replace function bi.ai_memory_search(p jsonb) returns jsonb language sql stable security definer set search_path = bi, public, extensions as $f$
  with q as (select (p->>'embedding')::extensions.vector v)
  select jsonb_build_object(
    'current_version', bi.cache_version(),
    'answers', coalesce((select jsonb_agg(x order by (x->>'sim')::numeric desc) from (
        select jsonb_build_object('id', m.id, 'question', m.question, 'answer', m.answer, 'data_version', m.data_version, 'same_ctx', m.ctx_key is not distinct from p->>'ctx_key',
                                  'helpful', m.helpful, 'plan', m.plan, 'mode', m.mode, 'created_at', m.created_at, 'sim', round((1 - (m.q_embedding <=> q.v))::numeric, 4)) x
          from bi.ai_message m, q
         where m.intent = 'agent' and m.q_embedding is not null and coalesce(m.mode, 'fresh') <> 'reused' and m.reuse_ok
           and coalesce(m.helpful, true) and coalesce(m.status, '') <> 'disputed'
           and coalesce(jsonb_array_length(case when jsonb_typeof(m.answer->'check'->'untraced') = 'array' then m.answer->'check'->'untraced' end), 0) = 0
           and 1 - (m.q_embedding <=> q.v) >= coalesce(nullif(p->>'min_sim', '')::numeric, 0.7)
         order by m.q_embedding <=> q.v limit least(coalesce(nullif(p->>'k', '')::int, 5), 10)) s), '[]'::jsonb),
    'lessons', coalesce((select jsonb_agg(x order by (x->>'sim')::numeric desc) from (
        select jsonb_build_object('id', m.id, 'question', m.question, 'correction', left(m.correction, 500), 'sim', round((1 - (m.q_embedding <=> q.v))::numeric, 4)) x
          from bi.ai_message m, q
         where m.correction is not null and length(btrim(m.correction)) >= 5 and m.lesson_active and m.q_embedding is not null
           and 1 - (m.q_embedding <=> q.v) >= coalesce(nullif(p->>'lesson_sim', '')::numeric, 0.72)
         order by m.q_embedding <=> q.v limit 3) s), '[]'::jsonb))
$f$;
revoke all on function bi.ai_memory_search(jsonb) from public, anon, authenticated;

do $m$
declare d text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if position('memory_search' in d) > 0 then return; end if;
  d := replace(d, $a$elsif op = 'pii_tokens' then$a$,
$a$elsif op = 'memory_search' then return bi.ai_memory_search(p);   -- wave 105c: Ask Crux memory
  elsif op = 'memory_pending' then
    return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'question', m.question, 'context', cv.context) order by m.id)
                       from (select * from bi.ai_message m where m.intent = 'agent' and m.q_embedding is null order by m.id limit least(coalesce(nullif(p->>'limit', '')::int, 50), 100)) m
                       left join bi.ai_conversation cv on cv.id = m.conversation_id), '[]'::jsonb);
  elsif op = 'memory_set' then
    update bi.ai_message m set q_embedding = (x->>'embedding')::extensions.vector, ctx_key = coalesce(m.ctx_key, x->>'ctx_key'), mode = coalesce(m.mode, 'fresh')
      from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) x where m.id = (x->>'id')::bigint;
    get diagnostics used = row_count;
    return jsonb_build_object('ok', true, 'stored', used);
  elsif op = 'pii_tokens' then$a$);
  if position('memory_search' in d) = 0 then raise exception 'gateway anchor not found'; end if;
  execute d;
end $m$;

create or replace function public.bi_ask_learning(p_action text, p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $f$
declare r jsonb; n int;
begin
  if not bi.admin_ok(p->>'admin_key') then return jsonb_build_object('error', 'admin key required'); end if;
  if p_action = 'summary' then
    with a as (select m.*, coalesce(nullif(m.trace->'usage'->>'calls', '')::int, 0) calls from bi.ai_message m where m.intent = 'agent' and m.created_at > now() - interval '30 days'),
         f as (select avg(calls) av from a where coalesce(mode, 'fresh') = 'fresh' and calls > 0)
    select jsonb_build_object(
      'by_mode', (select coalesce(jsonb_agg(jsonb_build_object('mode', md, 'answers', n, 'ai_calls', c, 'helpful', h, 'not_helpful', nh) order by md), '[]'::jsonb)
                    from (select coalesce(mode, 'fresh') md, count(*) n, sum(calls) c, count(*) filter (where helpful) h, count(*) filter (where helpful is false) nh from a group by 1) q),
      'avg_calls_fresh', (select round(av, 2) from f),
      'calls_saved_est', (select round(coalesce(sum(greatest((select av from f) - calls, 0)), 0), 1) from a where mode in ('reused', 'adapted')),
      'memory_size', (select count(*) from bi.ai_message where intent = 'agent' and q_embedding is not null and reuse_ok),
      'lessons', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'at', m.created_at, 'question', m.question, 'correction', m.correction, 'active', m.lesson_active) order by m.id desc), '[]'::jsonb)
                    from bi.ai_message m where m.correction is not null),
      'recent', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'at', created_at, 'question', question, 'mode', coalesce(mode, 'fresh'), 'model', model, 'calls', calls,
                                                                'helpful', helpful, 'reuse_of', reuse_of, 'reuse_ok', reuse_ok) order by id desc), '[]'::jsonb)
                    from (select * from a order by id desc limit 40) z)) into r;
    return r;
  elsif p_action = 'lesson_toggle' then
    update bi.ai_message set lesson_active = coalesce((p->>'active')::boolean, false) where id = (p->>'id')::bigint and correction is not null;
    get diagnostics n = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin', 'ask_lesson_toggle', 'ai_message', p->>'id', jsonb_build_object('active', p->'active'));
    return jsonb_build_object('ok', n = 1);
  elsif p_action = 'reuse_toggle' then
    update bi.ai_message set reuse_ok = coalesce((p->>'ok')::boolean, false) where id = (p->>'id')::bigint and intent = 'agent';
    get diagnostics n = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin', 'ask_reuse_toggle', 'ai_message', p->>'id', jsonb_build_object('ok', p->'ok'));
    return jsonb_build_object('ok', n = 1);
  end if;
  return jsonb_build_object('error', 'unknown action');
end $f$;
revoke all on function public.bi_ask_learning(text, jsonb) from public;
grant execute on function public.bi_ask_learning(text, jsonb) to anon, authenticated;

insert into bi.ai_config(key, value, note, updated_at, updated_by) values
  ('MEMORY_ENABLED', 'on', 'wave 105c: Ask Crux memory — reuse / adapt earlier answers to the same or similar question (off = always answer fresh).', now(), 'wave 105c'),
  ('MEMORY_REUSE_SIM', '0.97', 'wave 105c: similarity at or above which the same checked answer is reused (same page context, data unchanged; no AI call).', now(), 'wave 105c'),
  ('MEMORY_ADAPT_SIM', '0.85', 'wave 105c: similarity at or above which an earlier answer is adapted (its look-ups re-run on today''s data, one AI call).', now(), 'wave 105c')
on conflict (key) do nothing;
