-- Applied to Supabase project via MCP on 20261029051243
-- bi_097g2 (29-Oct-2026): qualify the previous-message columns (the plpgsql variable "intent" made the bare column name ambiguous).
do $do$
declare d text; o text := $o$  else select filters, intent into prev, prev_intent from bi.ai_message where conversation_id = conv order by id desc limit 1; end if;$o$;
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_ask3 fragment'; end if;
  execute replace(d, o, $n$  else select pm.filters, pm.intent into prev, prev_intent from bi.ai_message pm where pm.conversation_id = conv order by pm.id desc limit 1; end if;$n$);
end $do$;
