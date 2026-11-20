-- Applied to Supabase project via MCP on 20261120071939
-- wave 117a (20-Nov-2026, owner 12:42 IST: "when I ask or follow up on a reply, it works on that message as a new message and doesn't consider it as a
-- conversation and factor changes"). Ask Crux reads more of the conversation: up to 10 earlier turns (was 6, and the function asked for 3), each answer
-- up to 4,000 characters (was 1,500), plus the look-ups behind each answer (so "same for Pune" can repeat them), whether the answer was a detailed report
-- and the question Ask Crux asked back (clarify). Function body only; counted replacements; old body kept in bi.fn_backup.
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '117a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('public.bi_ai_gateway(jsonb)'::regprocedure, array[
  $r$jsonb_build_object('question', h.question, 'answer', left(coalesce(h.answer->>'answer', ''), 1500))$r$,
  $r$jsonb_build_object('question', h.question, 'answer', left(coalesce(h.answer->>'answer', ''), 4000), 'plan', h.plan,
                     'detailed', coalesce(h.answer->'detailed', 'false'::jsonb), 'clarify', h.answer->'clarify')$r$,
  $r$(select m.id, m.question, m.answer from bi.ai_message m where m.conversation_id = nullif(p->>'conversation_id', '')::uuid$r$,
  $r$(select m.id, m.question, m.answer, m.plan from bi.ai_message m where m.conversation_id = nullif(p->>'conversation_id', '')::uuid$r$,
  $r$order by m.id desc limit least(coalesce(nullif(p->>'n', '')::int, 3), 6)) h);$r$,
  $r$order by m.id desc limit least(coalesce(nullif(p->>'n', '')::int, 3), 10)) h);$r$], array[1, 1, 1]);
