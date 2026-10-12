-- Applied to Supabase project via MCP on 20261012103341
grant execute on function public.bi_call(text, jsonb) to anon, authenticated;
grant execute on function public.bi_admin(text, jsonb) to anon, authenticated;
grant execute on function public.bi_ingest(text, text, jsonb) to anon, authenticated;
