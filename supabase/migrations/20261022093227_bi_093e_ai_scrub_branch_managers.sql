-- Applied to Supabase project via MCP on 20261022093227
-- bi_093e (22-Oct-2026): branch-manager names are masked like employee and stakeholder names before anything reaches the AI provider,
-- and an answer that names one is shown without AI wording.
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  o := array[
$o0$from bi.workforce_master) z$o0$,
$o1$(select coalesce(jsonb_agg(distinct upper(trim(stakeholder)))::text, '[]') from bi.location where coalesce(trim(stakeholder), '') <> '')$o1$];
  n := array[
$n0$from bi.workforce_master
          union all select regexp_split_to_table(upper(regexp_replace(coalesce(manager, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.branch_manager) z$n0$,
$n1$(select coalesce(jsonb_agg(distinct q.nm)::text, '[]') from (select upper(trim(stakeholder)) nm from bi.location where coalesce(trim(stakeholder), '') <> ''
                                                            union select upper(trim(manager)) from bi.branch_manager where active) q)$n1$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'bi_ai_gateway fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
