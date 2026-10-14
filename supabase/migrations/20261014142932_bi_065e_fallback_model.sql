-- Applied to Supabase project via MCP on 20261014142932
insert into bi.ai_config(key, value, note) values ('GEMINI_FALLBACK_MODEL', '', 'Validated stable Flash-Lite model used only when the main model is overloaded (HTTP 429/5xx).') on conflict (key) do nothing;
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  d2 := replace(d, '    if coalesce(p->>''embedding'', '''') <> '''' then',
    '    if coalesce(p->>''fallback'', '''') <> '''' then
      update bi.ai_config set value = p->>''fallback'', verified_at = now(), updated_at = now(), updated_by = ''models.list check'',
        note = ''Validated fallback: listed with generateContent and passed a synthetic request.'' where key = ''GEMINI_FALLBACK_MODEL'';
    end if;
    if coalesce(p->>''embedding'', '''') <> '''' then');
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;
