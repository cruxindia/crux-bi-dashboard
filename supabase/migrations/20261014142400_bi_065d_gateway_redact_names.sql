-- Applied to Supabase project via MCP on 20261014142400
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  d2 := replace(d, 'return (select jsonb_object_agg(key, value) from bi.ai_config);',
    'return (select jsonb_object_agg(key, value) from bi.ai_config) || jsonb_build_object(''REDACT_NAMES'',
       (select coalesce(jsonb_agg(distinct upper(trim(stakeholder)))::text, ''[]'') from bi.location where coalesce(trim(stakeholder), '''') <> ''''));');
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;
