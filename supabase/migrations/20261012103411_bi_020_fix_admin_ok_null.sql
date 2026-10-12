-- Applied to Supabase project via MCP on 20261012103411
create or replace function bi.admin_ok(p_key text) returns boolean
language sql stable security definer set search_path = bi, public as $$
  select coalesce(bi.app_role() = 'admin', false) or coalesce(bi.token_ok(p_key), false) $$;
revoke all on function bi.admin_ok(text) from public, anon, authenticated;
