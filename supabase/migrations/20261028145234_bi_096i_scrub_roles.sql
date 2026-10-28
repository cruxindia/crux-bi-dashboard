-- Applied to Supabase project via MCP on 20261028145234
-- bi_096i (28-Oct-2026): names entered as operations handlers / collections owners are scrubbed before any text reaches the AI provider, like branch managers.
do $do$
declare d text; o text := $o$from bi.branch_manager) z$o$;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_ai_gateway fragment'; end if;
  execute replace(d, o, $n$from bi.branch_manager
          union all select regexp_split_to_table(upper(regexp_replace(coalesce(person, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.person_role) z$n$);
end $do$;
