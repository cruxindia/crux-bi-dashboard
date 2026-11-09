-- Applied to Supabase project via MCP on 20261109130217
-- wave 105f (owner 9-Nov-2026 18:05): agent team (daily brief, market news, chat review, weekly review); Gemini main AI, OpenRouter free backup, no paid use.
create table if not exists bi.agent_report (
  id bigserial primary key,
  kind text not null check (kind in ('daily_brief', 'market_news', 'chat_review', 'weekly_review')),
  for_date date not null,
  created_at timestamptz not null default now(),
  status text not null default 'ok' check (status in ('ok', 'failed')),
  title text,
  body_md text,
  data jsonb,
  usage jsonb,
  model text,
  audience text not null default 'admin' check (audience in ('viewer', 'admin')),
  unique (kind, for_date)
);
alter table bi.agent_report enable row level security;
comment on table bi.agent_report is 'wave 105f: reports written by the scheduled AI agents (one per kind per day; a re-run replaces it). audience viewer = shown on the dashboard to everyone.';

create table if not exists bi.ai_lesson (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  source text not null default 'chat_review',
  report_id bigint references bi.agent_report(id) on delete set null,
  question text not null,
  lesson text not null,
  status text not null default 'proposed' check (status in ('proposed', 'active', 'rejected')),
  q_embedding extensions.vector(768),
  decided_at timestamptz,
  decided_by text
);
alter table bi.ai_lesson enable row level security;
comment on table bi.ai_lesson is 'wave 105f: lessons proposed by the chat-review agent; used by Ask Crux only after an admin sets status active.';

create or replace function bi.agent_report_save(p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $f$
declare v_id bigint;
begin
  insert into bi.agent_report(kind, for_date, status, title, body_md, data, usage, model, audience)
  values (p->>'kind', coalesce(nullif(p->>'for_date', '')::date, (now() at time zone 'Asia/Kolkata')::date), coalesce(nullif(p->>'status', ''), 'ok'),
          left(p->>'title', 300), left(p->>'body_md', 60000), p->'data', p->'usage', p->>'model', coalesce(nullif(p->>'audience', ''), 'admin'))
  on conflict (kind, for_date) do update set created_at = now(), status = excluded.status, title = excluded.title, body_md = excluded.body_md,
    data = excluded.data, usage = excluded.usage, model = excluded.model, audience = excluded.audience
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $f$;
revoke all on function bi.agent_report_save(jsonb) from public, anon, authenticated;

create or replace function bi.agent_reports_recent(p jsonb) returns jsonb language sql stable security definer set search_path = bi, public as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at, 'title', title, 'data', data) order by for_date desc), '[]'::jsonb)
    from (select * from bi.agent_report where kind = coalesce(p->>'kind', kind) and status = 'ok'
            and for_date >= (now() at time zone 'Asia/Kolkata')::date - coalesce(nullif(p->>'days', '')::int, 7) order by for_date desc limit 31) r
$f$;
revoke all on function bi.agent_reports_recent(jsonb) from public, anon, authenticated;

create or replace function bi.agent_review_input(p jsonb) returns jsonb language sql stable security definer set search_path = bi, public as $f$
  with w as (select coalesce(nullif(p->>'since', '')::timestamptz, now() - interval '24 hours') ws, coalesce(nullif(p->>'until', '')::timestamptz, now()) wu)
  select jsonb_build_object(
    'since', (select ws from w), 'until', (select wu from w),
    'messages', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'at', m.created_at, 'question', m.question,
        'source', case when m.intent = 'agent' then 'ai' else 'calculated' end, 'intent', m.intent, 'mode', m.mode, 'model', m.model,
        'helpful', m.helpful, 'correction', m.correction,
        'figures', m.answer->'check'->>'figures',
        'untraced', case when jsonb_typeof(m.answer->'check'->'untraced') = 'array' then jsonb_array_length(m.answer->'check'->'untraced') end,
        'calls', m.trace->'usage'->>'calls',
        'tools', (select jsonb_agg(distinct st->>'tool') from jsonb_array_elements(case when jsonb_typeof(m.trace->'steps') = 'array' then m.trace->'steps' else '[]'::jsonb end) st),
        'answer_start', left(coalesce(m.answer->>'answer', m.answer->>'narrative', ''), 300)) order by m.id)
      from (select m0.* from bi.ai_message m0, w where m0.created_at >= w.ws and m0.created_at < w.wu
              and coalesce(m0.question, '') <> '' and coalesce(m0.provider, '') <> 'memory' order by m0.id desc limit 200) m), '[]'::jsonb),
    'reused', (select count(*) from bi.ai_message m, w where m.created_at >= w.ws and m.created_at < w.wu and m.mode = 'reused'),
    'errors', coalesce((select jsonb_agg(jsonb_build_object('model', model, 'purpose', purpose, 'note', note, 'n', n) order by n desc)
      from (select u.model, u.purpose, left(coalesce(u.note, ''), 140) note, count(*) n from bi.ai_provider_usage u, w where u.at >= w.ws and u.at < w.wu and not u.ok group by 1, 2, 3 order by 4 desc limit 15) e), '[]'::jsonb))
$f$;
revoke all on function bi.agent_review_input(jsonb) from public, anon, authenticated;

create or replace function bi.agent_lesson_propose(p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public, extensions as $f$
declare v_n int;
begin
  insert into bi.ai_lesson(source, report_id, question, lesson, q_embedding)
  select coalesce(p->>'source', 'chat_review'), nullif(p->>'report_id', '')::bigint, left(x->>'question', 500), left(x->>'lesson', 600), nullif(x->>'embedding', '')::extensions.vector
    from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) x
   where coalesce(btrim(x->>'question'), '') <> '' and coalesce(btrim(x->>'lesson'), '') <> ''
     and not exists (select 1 from bi.ai_lesson l where lower(l.lesson) = lower(left(x->>'lesson', 600)));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'stored', v_n);
end $f$;
revoke all on function bi.agent_lesson_propose(jsonb) from public, anon, authenticated;

create or replace function bi.ai_memory_search(p jsonb) returns jsonb language sql stable security definer set search_path = bi, public, extensions as $f$
  with q as (select (p->>'embedding')::extensions.vector v, coalesce(nullif(p->>'lesson_sim', '')::numeric, 0.72) ls)
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
        select x from (
          select jsonb_build_object('id', m.id, 'question', m.question, 'correction', left(m.correction, 500), 'sim', round((1 - (m.q_embedding <=> q.v))::numeric, 4)) x, m.q_embedding <=> q.v d
            from bi.ai_message m, q
           where m.correction is not null and length(btrim(m.correction)) >= 5 and m.lesson_active and m.q_embedding is not null and 1 - (m.q_embedding <=> q.v) >= q.ls
          union all
          select jsonb_build_object('id', -l.id, 'question', l.question, 'correction', left(l.lesson, 500), 'sim', round((1 - (l.q_embedding <=> q.v))::numeric, 4)) x, l.q_embedding <=> q.v d
            from bi.ai_lesson l, q
           where l.status = 'active' and l.q_embedding is not null and 1 - (l.q_embedding <=> q.v) >= q.ls) u
        order by d limit 3) s), '[]'::jsonb))
$f$;
revoke all on function bi.ai_memory_search(jsonb) from public, anon, authenticated;

do $m$
declare d text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if position('report_save' in d) > 0 then return; end if;
  d := replace(d, $a$elsif op = 'pii_tokens' then$a$,
$a$elsif op = 'report_save' then return bi.agent_report_save(p);   -- wave 105f: agent team
  elsif op = 'reports_recent' then return bi.agent_reports_recent(p);
  elsif op = 'review_input' then return bi.agent_review_input(p);
  elsif op = 'lesson_propose' then return bi.agent_lesson_propose(p);
  elsif op = 'pii_tokens' then$a$);
  if position('report_save' in d) = 0 then raise exception 'gateway anchor not found'; end if;
  execute d;
end $m$;

create or replace function public.bi_agent_reports(p jsonb default '{}'::jsonb) returns jsonb language plpgsql stable security definer set search_path = bi, public as $f$
declare adm boolean := coalesce(bi.admin_ok(p->>'admin_key'), false);
begin
  if nullif(p->>'id', '') is not null then
    return (select jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at, 'status', status, 'title', title, 'body_md', body_md, 'data', data, 'model', model)
              from bi.agent_report where id = (p->>'id')::bigint and (adm or audience = 'viewer'));
  end if;
  return jsonb_build_object('admin', adm,
    'latest', (select coalesce(jsonb_object_agg(kind, r), '{}'::jsonb) from (
        select distinct on (kind) kind, jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at, 'title', title, 'body_md', body_md,
                                                            'data', data, 'model', model) r
          from bi.agent_report where status = 'ok' and (adm or audience = 'viewer') order by kind, for_date desc, id desc) z),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at, 'status', status, 'title', title,
                                                             'model', model, 'usage', usage) order by created_at desc), '[]'::jsonb)
                  from (select * from bi.agent_report where adm or audience = 'viewer' order by created_at desc limit 40) h),
    'lessons', case when adm then (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'created_at', created_at, 'question', question, 'lesson', lesson, 'status', status,
                                                                                 'report_id', report_id, 'decided_at', decided_at) order by id desc), '[]'::jsonb) from bi.ai_lesson) end);
end $f$;
revoke all on function public.bi_agent_reports(jsonb) from public;
grant execute on function public.bi_agent_reports(jsonb) to anon, authenticated;

create or replace function public.bi_agent_admin(p_action text, p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $f$
declare v_rows int;
begin
  if not coalesce(bi.admin_ok(p->>'admin_key'), false) then return jsonb_build_object('error', 'admin key required'); end if;
  if p_action = 'lesson_decide' then
    if coalesce(p->>'status', '') not in ('active', 'rejected', 'proposed') then return jsonb_build_object('error', 'status must be active, rejected or proposed'); end if;
    update bi.ai_lesson set status = p->>'status', decided_at = now(), decided_by = left(coalesce(nullif(p->>'by', ''), 'admin'), 60),
           lesson = coalesce(nullif(btrim(p->>'lesson'), ''), lesson)
     where id = (p->>'id')::bigint;
    get diagnostics v_rows = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail)
    values (left(coalesce(nullif(p->>'by', ''), 'admin'), 60), 'ai_agent_lesson', 'ai_lesson', p->>'id', jsonb_build_object('status', p->>'status', 'edited', nullif(btrim(p->>'lesson'), '') is not null));
    return jsonb_build_object('ok', v_rows = 1);
  end if;
  return jsonb_build_object('error', 'unknown action');
end $f$;
revoke all on function public.bi_agent_admin(text, jsonb) from public;
grant execute on function public.bi_agent_admin(text, jsonb) to anon, authenticated;

insert into bi.ai_config(key, value, note, updated_at, updated_by) values
  ('AGENTS_ENABLED', 'on', 'wave 105f: scheduled AI agents (daily brief, market news, chat review, weekly review); off = the scheduled runs do nothing.', now(), 'wave 105f'),
  ('OPENROUTER_PAID_ALLOWED', 'off', 'wave 105f: owner 9-Nov "no paid use" — only OpenRouter free models (openrouter/free or :free) may be called; any other model is refused in code.', now(), 'wave 105f'),
  ('AGENT_NEWS_QUERIES', '["RBI KYC verification banks","home loan disbursement India banks","MSME loan India banks","bank loan fraud India","digital lending RBI guidelines"]',
   'wave 105f: extra Google News searches for the market agent (client banks are added automatically from the top clients by revenue).', now(), 'wave 105f')
on conflict (key) do nothing;
update bi.ai_config set value = 'gemini-2.5-flash,or:openrouter/free', updated_at = now(), updated_by = 'wave 105f',
       note = 'wave 105f: backup models in order. or: = OpenRouter (free models only, providers barred from training on the data).'
 where key = 'AGENT_FALLBACK_MODEL';

select cron.schedule('bi-agent-chat-review', '40 23 * * *', $$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"chat_review"}'::jsonb)$$);
select cron.schedule('bi-agent-daily-brief', '50 0 * * *', $$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"daily_brief"}'::jsonb)$$);
select cron.schedule('bi-agent-market-news', '10 1 * * *', $$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"market_news"}'::jsonb)$$);
select cron.schedule('bi-agent-weekly-review', '30 1 * * 1', $$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"weekly_review"}'::jsonb)$$);

create or replace function public.bi_repo_export_times(p_token text) returns jsonb language plpgsql security definer set search_path = bi, public, extensions as $f$
begin
  if not exists (select 1 from bi.export_token where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and not revoked and expires_at > now()) then
    raise exception 'not authorised' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_object_agg(path, extract(epoch from updated_at)::bigint), '{}'::jsonb) from bi.repo_file);
end $f$;
revoke all on function public.bi_repo_export_times(text) from public;
grant execute on function public.bi_repo_export_times(text) to anon, authenticated;
