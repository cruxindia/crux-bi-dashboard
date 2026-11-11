-- Applied to Supabase project via MCP on 20261111062420
-- wave 105h (owner 9-Nov-2026 19:25): "i don't want to give away which AI is being used ... Only reference of AI to be used is 'Ask Crux'.
-- And add 'Ask Crux' at every table and chart and tile everywhere ... Record which section gets asked more to bring improvement".
-- 1) nothing a viewer or admin sees names an AI model or vendor (bi.no_vendor, the same patterns as brand.ts in the edge function);
-- 2) bi.ask_origin records where each question was asked from (page, tile / table / chart and its title, answer path), used by the
--    admin learning page and by the chat and weekly review agents to aim improvements at what people ask about most.

create or replace function bi.no_vendor(t text) returns text language sql immutable parallel safe as $f$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(t,
    '\m(google\s+)?gemini([\s-]*[0-9]+(\.[0-9]+)*)?([\s-]+(pro|flash|lite|ultra|nano|embedding|exp|preview|thinking|latest|[0-9]+(\.[0-9]+)*)\M)*', 'Ask Crux', 'gi'),
    '\mor:[A-Za-z0-9_./:~-]+', 'Ask Crux', 'gi'),
    '\mopen\s?router(/[A-Za-z0-9_.:-]+)?', 'Ask Crux', 'gi'),
    '~?\mopen\s?ai\M(/[A-Za-z0-9_.:-]+)?', 'Ask Crux', 'gi'),
    '\m(chat\s?)?gpt(-[A-Za-z0-9_.]+)*(\s?[0-9][A-Za-z0-9_.]*)?\M', 'Ask Crux', 'gi'),
    '\manthropic\M', 'Ask Crux', 'gi'),
    '\mclaude([\s-]+(opus|sonnet|haiku|code|fable|mythos))?([\s-]*[0-9]+(\.[0-9]+)*)?\M', 'Ask Crux', 'gi'),
    '\m(meta[\s-]+)?llama[A-Za-z0-9_.-]*(:free)?', 'Ask Crux', 'gi'),
    '\m(deepseek|qwen|mistral|mixtral|gemma)[A-Za-z0-9_.-]*(:free)?', 'Ask Crux', 'gi'),
    '\m(google\s+)?(ai\s+studio|generative\s?language\s?api)\M', 'Ask Crux', 'gi'),
    'Ask Crux(\s*[,/+&]\s*Ask Crux|\s+Ask Crux)+', 'Ask Crux', 'g')
$f$;
comment on function bi.no_vendor(text) is 'wave 105h: replaces AI model / vendor names with "Ask Crux" (same patterns as supabase/functions/ask-crux/brand.ts and noVendor in the page).';

-- where questions are asked from
create table if not exists bi.ask_origin (
  id bigserial primary key,
  at timestamptz not null default now(),
  section text,                 -- page key (overview, rca, tat ...)
  page text,                    -- page label as shown in the menu
  kind text not null default 'panel' check (kind in ('panel', 'tile', 'table', 'chart', 'card', 'suggestion', 'next', 'menu', 'drill')),
  title text,                   -- the tile label / table or chart heading the Ask Crux button sat on
  path text,                    -- ai | memory | calculated | error
  message_id bigint,
  conversation_id uuid,
  admin boolean not null default false,
  ms int
);
alter table bi.ask_origin enable row level security;
create index if not exists ask_origin_at_idx on bi.ask_origin (at desc);
create index if not exists ask_origin_msg_idx on bi.ask_origin (message_id) where message_id is not null;
comment on table bi.ask_origin is 'wave 105h: one row per Ask Crux question — the page and the tile / table / chart it was asked from (owner: "Record which section gets asked more to bring improvement"). Written only by the ask-crux edge function (gateway op origin_log); read by admin functions.';

create or replace function bi.ask_origin_log(p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $f$
declare v_id bigint;
begin
  insert into bi.ask_origin(section, page, kind, title, path, message_id, conversation_id, admin, ms)
  values (left(nullif(btrim(p->>'section'), ''), 40), left(nullif(btrim(p->>'page'), ''), 80),
          case when p->>'kind' in ('panel', 'tile', 'table', 'chart', 'card', 'suggestion', 'next', 'menu', 'drill') then p->>'kind' else 'panel' end,
          left(nullif(btrim(p->>'title'), ''), 160), left(nullif(p->>'path', ''), 20),
          case when p->>'message_id' ~ '^\d{1,18}$' then (p->>'message_id')::bigint end,
          case when p->>'conversation_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p->>'conversation_id')::uuid end,
          coalesce((p->>'admin')::boolean, false), case when p->>'ms' ~ '^\d{1,9}$' then (p->>'ms')::int end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $f$;
revoke all on function bi.ask_origin_log(jsonb) from public, anon, authenticated;

-- counts by page and by element for a time window (used by the review agents and the admin learning page)
create or replace function bi.ask_origin_counts(p_since timestamptz, p_until timestamptz default now(), p_limit int default 20) returns jsonb language sql stable security definer set search_path = bi, public as $f$
  with o as (select o.*, m.helpful from bi.ask_origin o left join bi.ai_message m on m.id = o.message_id where o.at >= p_since and o.at < p_until)
  select jsonb_build_object(
    'total', (select count(*) from o),
    'pages', coalesce((select jsonb_agg(x order by (x->>'n')::int desc, x->>'section') from (
        select jsonb_build_object('section', section, 'page', max(page), 'n', count(*), 'from_elements', count(*) filter (where kind not in ('panel', 'menu')),
                                  'ai', count(*) filter (where path = 'ai'), 'memory', count(*) filter (where path = 'memory'), 'calculated', count(*) filter (where path = 'calculated'),
                                  'errors', count(*) filter (where path = 'error'), 'helpful', count(*) filter (where helpful), 'not_helpful', count(*) filter (where helpful is false),
                                  'last', max(at)) x
          from o group by section order by count(*) desc limit p_limit) z), '[]'::jsonb),
    'elements', coalesce((select jsonb_agg(x order by (x->>'n')::int desc, x->>'title') from (
        select jsonb_build_object('section', section, 'page', max(page), 'kind', kind, 'title', title, 'n', count(*),
                                  'helpful', count(*) filter (where helpful), 'not_helpful', count(*) filter (where helpful is false), 'last', max(at)) x
          from o where kind not in ('panel', 'menu') group by section, kind, title order by count(*) desc limit p_limit) z), '[]'::jsonb),
    'kinds', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from o group by kind) k), '{}'::jsonb))
$f$;
revoke all on function bi.ask_origin_counts(timestamptz, timestamptz, int) from public, anon, authenticated;

-- gateway op for the edge function (service role only)
do $m$
declare d text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if position('origin_log' in d) > 0 then return; end if;
  d := replace(d, $a$elsif op = 'pii_tokens' then$a$,
$a$elsif op = 'origin_log' then return bi.ask_origin_log(p);   -- wave 105h: where questions are asked from
  elsif op = 'pii_tokens' then$a$);
  if position('origin_log' in d) = 0 then raise exception 'gateway anchor not found'; end if;
  execute d;
end $m$;

-- AI status for the page (anyone can read it): no model or vendor names
create or replace function bi.api_ai_status() returns jsonb language sql stable security definer set search_path = bi, public as $f$
with cf as (select (select value from bi.ai_config where key = 'AGENT_MODEL') am, (select value from bi.ai_config where key = 'GEMINI_MODEL') gm,
                   (select value from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL') em)
select jsonb_build_object(
  'assistant', 'Ask Crux',
  'enabled', (select value from bi.ai_config where key = 'AI_ENABLED') = 'on',
  'agent_enabled', (select value from bi.ai_config where key = 'AGENT_ENABLED') = 'on',
  'key_present', (select value from bi.ai_config where key = 'KEY_PRESENT'),
  'engine_ready', (select coalesce(am, gm) is not null from cf),
  'engine_checked_at', (select verified_at from bi.ai_config where key = 'GEMINI_MODEL'),
  'backup_ready', coalesce((select value from bi.ai_config where key = 'AGENT_FALLBACK_MODEL'), '') <> '',
  'memory_ready', (select em is not null and em <> '' from cf),
  'memory_checked_at', (select verified_at from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL'),
  'daily_cap', (select value::int from bi.ai_config where key = 'AI_DAILY_CAP'),
  'today', (select jsonb_build_object('calls', count(*), 'ok', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
            'tokens', coalesce(sum(coalesce(prompt_tokens,0) + coalesce(output_tokens,0)), 0))
            from bi.ai_provider_usage where at > date_trunc('day', now())),
  'last_30d', (select jsonb_build_object('calls', count(*), 'ok', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
            'tokens', coalesce(sum(coalesce(prompt_tokens,0) + coalesce(output_tokens,0)), 0))
            from bi.ai_provider_usage where at > now() - interval '30 days'),
  'last_failure', (select jsonb_build_object('at', u.at, 'purpose', u.purpose, 'note', bi.no_vendor(u.note),
                     'engine', case when u.model in (cf.am, cf.gm) then 'main' when u.model = cf.em then 'memory' else 'backup' end)
                     from bi.ai_provider_usage u, cf where not u.ok order by u.at desc limit 1),
  'knowledge', (select jsonb_build_object('documents', (select count(*) from bi.kb_doc where retired_at is null),
            'chunks', count(*), 'embedded', count(*) filter (where embedding is not null)) from bi.kb_chunk where active),
  'last_engine_check', (select max(checked_at) from bi.ai_model_check))
$f$;

-- review input for the chat and weekly review agents: engines as main / backup, vendor names removed, where questions came from
create or replace function bi.agent_review_input(p jsonb) returns jsonb language sql stable security definer set search_path = bi, public as $f$
  with w as (select coalesce(nullif(p->>'since', '')::timestamptz, now() - interval '24 hours') ws, coalesce(nullif(p->>'until', '')::timestamptz, now()) wu),
       cf as (select (select value from bi.ai_config where key = 'AGENT_MODEL') am, (select value from bi.ai_config where key = 'GEMINI_MODEL') gm,
                     (select value from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL') em)
  select jsonb_build_object(
    'since', (select ws from w), 'until', (select wu from w),
    'messages', case when coalesce((p->>'origins_only')::boolean, false) then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'at', m.created_at, 'question', m.question,
        'source', case when m.intent = 'agent' then 'ai' else 'calculated' end, 'intent', m.intent, 'mode', m.mode,
        'engine', case when m.model is null then null when m.model in (cf.am, cf.gm) then 'main' else 'backup' end,
        'page', (select ao.section from bi.ask_origin ao where ao.message_id = m.id order by ao.id limit 1),
        'asked_from', (select ao.kind || coalesce(' "' || ao.title || '"', '') from bi.ask_origin ao where ao.message_id = m.id and ao.kind not in ('panel', 'menu') order by ao.id limit 1),
        'helpful', m.helpful, 'correction', m.correction,
        'figures', m.answer->'check'->>'figures',
        'untraced', case when jsonb_typeof(m.answer->'check'->'untraced') = 'array' then jsonb_array_length(m.answer->'check'->'untraced') end,
        'calls', m.trace->'usage'->>'calls',
        'tools', (select jsonb_agg(distinct st->>'tool') from jsonb_array_elements(case when jsonb_typeof(m.trace->'steps') = 'array' then m.trace->'steps' else '[]'::jsonb end) st),
        'answer_start', bi.no_vendor(left(coalesce(m.answer->>'answer', m.answer->>'narrative', ''), 300))) order by m.id)
      from (select m0.* from bi.ai_message m0, w where m0.created_at >= w.ws and m0.created_at < w.wu
              and coalesce(m0.question, '') <> '' and coalesce(m0.provider, '') <> 'memory' order by m0.id desc limit 200) m, cf), '[]'::jsonb) end,
    'reused', (select count(*) from bi.ai_message m, w where m.created_at >= w.ws and m.created_at < w.wu and m.mode = 'reused'),
    'errors', coalesce((select jsonb_agg(jsonb_build_object('engine', engine, 'purpose', purpose, 'note', note, 'n', n) order by n desc)
      from (select case when u.model in (cf.am, cf.gm) then 'main' when u.model = cf.em then 'memory' else 'backup' end engine, u.purpose,
                   bi.no_vendor(left(coalesce(u.note, ''), 140)) note, count(*) n
              from bi.ai_provider_usage u, w, cf where u.at >= w.ws and u.at < w.wu and not u.ok group by 1, 2, 3 order by 4 desc limit 15) e), '[]'::jsonb),
    'origins', (select bi.ask_origin_counts(w.ws, w.wu, 15) from w))
$f$;
revoke all on function bi.agent_review_input(jsonb) from public, anon, authenticated;

-- agent reports for the page: no model names; vendor names removed from report text (market-news headlines are quoted from the feeds and left as published)
create or replace function public.bi_agent_reports(p jsonb default '{}'::jsonb) returns jsonb language plpgsql stable security definer set search_path = bi, public as $f$
declare adm boolean := coalesce(bi.admin_ok(p->>'admin_key'), false);
begin
  if nullif(p->>'id', '') is not null then
    return (select jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at, 'status', status,
                                      'title', case when kind = 'market_news' then title else bi.no_vendor(title) end,
                                      'body_md', case when kind = 'market_news' then body_md else bi.no_vendor(body_md) end,
                                      'data', case when kind = 'market_news' then data else bi.no_vendor(data::text)::jsonb end)
              from bi.agent_report where id = (p->>'id')::bigint and (adm or audience = 'viewer'));
  end if;
  return jsonb_build_object('admin', adm,
    'latest', (select coalesce(jsonb_object_agg(kind, r), '{}'::jsonb) from (
        select distinct on (kind) kind, jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at,
                                                            'title', case when kind = 'market_news' then title else bi.no_vendor(title) end,
                                                            'body_md', case when kind = 'market_news' then body_md else bi.no_vendor(body_md) end,
                                                            'data', case when kind = 'market_news' then data else bi.no_vendor(data::text)::jsonb end) r
          from bi.agent_report where status = 'ok' and (adm or audience = 'viewer') order by kind, for_date desc, id desc) z),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'for_date', for_date, 'created_at', created_at, 'status', status,
                                                             'title', case when kind = 'market_news' then title else bi.no_vendor(title) end, 'usage', usage) order by created_at desc), '[]'::jsonb)
                  from (select * from bi.agent_report where adm or audience = 'viewer' order by created_at desc limit 40) h),
    'lessons', case when adm then (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'created_at', created_at, 'question', question, 'lesson', bi.no_vendor(lesson), 'status', status,
                                                                                 'report_id', report_id, 'decided_at', decided_at) order by id desc), '[]'::jsonb) from bi.ai_lesson) end);
end $f$;
revoke all on function public.bi_agent_reports(jsonb) from public;
grant execute on function public.bi_agent_reports(jsonb) to anon, authenticated;

-- admin learning page: no model names; where questions are asked from (last 30 days)
create or replace function public.bi_ask_learning(p_action text, p jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $f$
declare r jsonb; v_rows int;
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
      'recent', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'at', created_at, 'question', question, 'mode', coalesce(mode, 'fresh'), 'calls', calls,
                                                                'page', (select ao.section from bi.ask_origin ao where ao.message_id = z.id order by ao.id limit 1),
                                                                'asked_from', (select ao.kind || coalesce(' · ' || ao.title, '') from bi.ask_origin ao where ao.message_id = z.id order by ao.id limit 1),
                                                                'helpful', helpful, 'reuse_of', reuse_of, 'reuse_ok', reuse_ok) order by id desc), '[]'::jsonb)
                    from (select * from a order by id desc limit 40) z),
      'asked', bi.ask_origin_counts(now() - interval '30 days', now(), 25)) into r;
    return r;
  elsif p_action = 'lesson_toggle' then
    update bi.ai_message set lesson_active = coalesce((p->>'active')::boolean, false) where id = (p->>'id')::bigint and correction is not null;
    get diagnostics v_rows = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin', 'ai_ask_lesson_toggle', 'ai_message', p->>'id', jsonb_build_object('active', p->'active'));
    return jsonb_build_object('ok', v_rows = 1);
  elsif p_action = 'reuse_toggle' then
    update bi.ai_message set reuse_ok = coalesce((p->>'ok')::boolean, false) where id = (p->>'id')::bigint and intent = 'agent';
    get diagnostics v_rows = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin', 'ai_ask_reuse_toggle', 'ai_message', p->>'id', jsonb_build_object('ok', p->'ok'));
    return jsonb_build_object('ok', v_rows = 1);
  end if;
  return jsonb_build_object('error', 'unknown action');
end $f$;
