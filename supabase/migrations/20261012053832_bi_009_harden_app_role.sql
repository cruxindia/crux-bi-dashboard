-- Applied to Supabase project via MCP on 20261012053832

-- Role resolution must not trust JWT email claims or default "verified" to true.
create or replace function bi.app_role() returns text
language sql stable security definer set search_path = bi, public, auth as $$
  select a.role
  from auth.users u
  join bi.app_user a on a.email = lower(u.email) and a.active
  where u.id = auth.uid()
    and u.email_confirmed_at is not null
    and u.deleted_at is null
    and coalesce(u.banned_until, '-infinity'::timestamptz) < now()
$$;
create or replace function bi.current_email() returns text
language sql stable security definer set search_path = bi, public, auth as $$
  select coalesce(lower((select email from auth.users where id = auth.uid())), '')
$$;
revoke all on function bi.app_role() from public, anon, authenticated;
revoke all on function bi.current_email() from public, anon, authenticated;

