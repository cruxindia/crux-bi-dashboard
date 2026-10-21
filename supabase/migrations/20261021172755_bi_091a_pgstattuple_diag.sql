-- Applied to Supabase project via MCP on 20261021172755
create extension if not exists pgstattuple with schema extensions;
revoke all on function extensions.pgstattuple_approx(regclass) from public, anon, authenticated;
