-- Applied to Supabase project via MCP on 20261109091406
-- wave 105d (9-Nov-2026): Ask Crux memory calibration and a side-effect fix (see repo file for full notes).
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
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin', 'ai_ask_lesson_toggle', 'ai_message', p->>'id', jsonb_build_object('active', p->'active'));
    return jsonb_build_object('ok', n = 1);
  elsif p_action = 'reuse_toggle' then
    update bi.ai_message set reuse_ok = coalesce((p->>'ok')::boolean, false) where id = (p->>'id')::bigint and intent = 'agent';
    get diagnostics n = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin', 'ai_ask_reuse_toggle', 'ai_message', p->>'id', jsonb_build_object('ok', p->'ok'));
    return jsonb_build_object('ok', n = 1);
  end if;
  return jsonb_build_object('error', 'unknown action');
end $f$;
revoke all on function public.bi_ask_learning(text, jsonb) from public;
grant execute on function public.bi_ask_learning(text, jsonb) to anon, authenticated;

update bi.ai_config set value = '0.92', updated_at = now(), updated_by = 'wave 105d',
  note = 'wave 105d: similarity at or above which the same checked answer is reused (also needs the same content words, same page context, data unchanged; no AI call).'
 where key = 'MEMORY_REUSE_SIM';
update bi.ai_config set updated_at = now(), updated_by = 'wave 105d',
  note = 'wave 105c/d: similarity at or above which an earlier answer is adapted (also needs the same entities, numbers, period and direction words; its look-ups re-run on today''s data).'
 where key = 'MEMORY_ADAPT_SIM';
