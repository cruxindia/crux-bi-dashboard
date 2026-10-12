-- Applied to Supabase project via MCP on 20261012054313

do $$
declare d text; auth_block text;
begin
  d := pg_get_functiondef('public.bi_ingest(text,text,jsonb)'::regprocedure);
  auth_block := $a$  if bi.token_ok(p_token) then v_actor := 'loader-token';
  elsif bi.app_role() = 'admin' then v_actor := bi.current_email();
  else raise exception 'not authorised' using errcode = '42501'; end if;$a$;
  if position(auth_block in d) = 0 then raise exception 'auth block not found; abort'; end if;
  d := replace(d, auth_block, $a$  v_actor := coalesce(nullif(p_actor,''), 'unknown');$a$);
  d := replace(d, 'FUNCTION public.bi_ingest(p_token text, p_action text, p_payload jsonb)',
                  'FUNCTION bi.ingest_as(p_actor text, p_action text, p_payload jsonb)');
  execute d;
end $$;
revoke all on function bi.ingest_as(text,text,jsonb) from public, anon, authenticated;

create or replace function public.bi_ingest(p_token text, p_action text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare v_actor text;
begin
  if bi.token_ok(p_token) then v_actor := 'loader-token';
  elsif bi.app_role() = 'admin' then v_actor := bi.current_email();
  else raise exception 'not authorised' using errcode = '42501'; end if;
  return bi.ingest_as(v_actor, p_action, p_payload);
end $$;

