-- Applied to Supabase project via MCP on 20261014142746
alter function public.bi_admin(text, jsonb) set statement_timeout = '120s';
alter function public.bi_branch_job(jsonb) set statement_timeout = '120s';
alter function public.bi_ai_gateway(jsonb) set statement_timeout = '30s';
