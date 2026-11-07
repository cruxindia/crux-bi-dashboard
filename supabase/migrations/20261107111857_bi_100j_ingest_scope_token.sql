-- Applied to Supabase project via MCP on 20261107111857
-- Wave 100: least-privilege token for an external system that sends data (the owner's new GitHub + Supabase tool, 7-Nov-2026).
-- A token with scope 'ingest' can call bi_ingest only (upload batches go through the same checks, audit log and cache refresh as
-- the upload centre); it cannot call admin functions, read admin views or change settings. Tokens are stored as SHA-256 hashes,
-- expire, and are revoked in bi.ingest_token. No token of this scope is issued by this migration.
create or replace function bi.token_label(p_token text, p_scope text) returns text language sql stable security definer
set search_path to 'bi', 'public', 'extensions' as $f$
  select t.label from bi.ingest_token t
   where p_token is not null and t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and not t.revoked and t.expires_at > now() and t.scope = p_scope
   limit 1 $f$;
revoke all on function bi.token_label(text, text) from public, anon, authenticated;

create or replace function public.bi_ingest(p_token text, p_action text, p_payload jsonb) returns jsonb language plpgsql
security definer set search_path to 'bi', 'public' as $function$
declare v_actor text; v_lab text;
begin
  if bi.token_ok(p_token) then v_actor := 'loader-token';
  elsif (select bi.token_label(p_token, 'ingest')) is not null then
    v_lab := bi.token_label(p_token, 'ingest'); v_actor := 'ingest-token: ' || left(v_lab, 60);
  elsif bi.app_role() = 'admin' then v_actor := bi.current_email();
  else raise exception 'not authorised' using errcode = '42501'; end if;
  return bi.ingest_as(v_actor, p_action, p_payload);
end $function$;
