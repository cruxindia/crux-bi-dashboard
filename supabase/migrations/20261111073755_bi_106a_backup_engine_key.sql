-- Applied to Supabase project via MCP on 20261111073755
-- wave 106a (owner 11-Nov-2026 13:01: "How do I add this key and where? And start the AI"): the backup engine key can be saved by an admin
-- from the dashboard (Admin → Database health → Ask Crux status) or as an Edge Function secret. It is stored encrypted in Supabase Vault
-- (name ai_backup_key), is never returned to any page, and ask-crux reads it through the service-role gateway (op secret) when the
-- Edge Function secret OPENROUTER_API_KEY is not set (an Edge Function secret, when present, wins).
create or replace function public.bi_ai_key_put(p_admin_key text, p_value text, p_by text default 'admin') returns jsonb language plpgsql security definer set search_path = bi, public, vault as $f$
declare v_id uuid; v text := btrim(coalesce(p_value, ''));
begin
  if not coalesce(bi.admin_ok(p_admin_key), false) then return jsonb_build_object('error', 'admin key required'); end if;
  if v !~ '^sk-or-v1-[0-9a-f]{64}$' then return jsonb_build_object('error', 'that does not look like a backup engine key (it should start with sk-or-v1- and be 73 characters)'); end if;
  select id into v_id from vault.secrets where name = 'ai_backup_key';
  if v_id is null then perform vault.create_secret(v, 'ai_backup_key', 'Ask Crux backup engine key (wave 106a); read only by ask-crux through the service-role gateway');
  else perform vault.update_secret(v_id, v, 'ai_backup_key', 'Ask Crux backup engine key (wave 106a); read only by ask-crux through the service-role gateway'); end if;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (left(coalesce(nullif(p_by, ''), 'admin'), 60), 'ai_key_backup_saved', 'vault', 'ai_backup_key', jsonb_build_object('length', length(v), 'replaced', v_id is not null));
  update bi.ai_config set value = 'yes', updated_at = now(), updated_by = 'bi_ai_key_put' where key = 'BACKUP_KEY_PRESENT';
  if not found then insert into bi.ai_config(key, value, note, updated_at, updated_by) values ('BACKUP_KEY_PRESENT', 'yes', 'wave 106a: a backup engine key is stored in Vault (ai_backup_key)', now(), 'bi_ai_key_put'); end if;
  return jsonb_build_object('ok', true, 'replaced', v_id is not null);
end $f$;
revoke all on function public.bi_ai_key_put(text, text, text) from public;
grant execute on function public.bi_ai_key_put(text, text, text) to anon, authenticated;

create or replace function bi.ai_secret(p jsonb) returns jsonb language sql stable security definer set search_path = bi, public, vault as $f$
  select jsonb_build_object('value', (select decrypted_secret from vault.decrypted_secrets where name = 'ai_backup_key' and p->>'name' = 'ai_backup_key'))
$f$;
revoke all on function bi.ai_secret(jsonb) from public, anon, authenticated;

do $m$
declare d text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if position('op = ''secret''' in d) > 0 then return; end if;
  d := replace(d, $a$elsif op = 'pii_tokens' then$a$,
$a$elsif op = 'secret' then return bi.ai_secret(p);   -- wave 106a: backup engine key from Vault (service role only)
  elsif op = 'pii_tokens' then$a$);
  if position('op = ''secret''' in d) = 0 then raise exception 'gateway anchor not found'; end if;
  execute d;
end $m$;

-- status shows whether a backup key is stored (never the key)
create or replace function bi.api_ai_status() returns jsonb language sql stable security definer set search_path = bi, public as $f$
with cf as (select (select value from bi.ai_config where key = 'AGENT_MODEL') am, (select value from bi.ai_config where key = 'GEMINI_MODEL') gm,
                   (select value from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL') em)
select jsonb_build_object(
  'assistant', 'Ask Crux',
  'enabled', (select value from bi.ai_config where key = 'AI_ENABLED') = 'on',
  'agent_enabled', (select value from bi.ai_config where key = 'AGENT_ENABLED') = 'on',
  'key_present', (select value from bi.ai_config where key = 'KEY_PRESENT'),
  'backup_key_present', coalesce((select value from bi.ai_config where key = 'BACKUP_KEY_PRESENT'), 'no'),
  'engine_ready', (select coalesce(am, gm) is not null from cf),
  'engine_checked_at', (select verified_at from bi.ai_config where key = 'GEMINI_MODEL'),
  'backup_ready', coalesce((select value from bi.ai_config where key = 'AGENT_FALLBACK_MODEL'), '') <> '',
  'memory_ready', (select em is not null and em <> '' from cf),
  'memory_checked_at', (select verified_at from bi.ai_config where key = 'GEMINI_EMBEDDING_MODEL'),
  'daily_cap', (select value::int from bi.ai_config where key = 'AI_DAILY_CAP'),
  'today', (select jsonb_build_object('calls', count(*), 'ok', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
            'tokens', coalesce(sum(coalesce(prompt_tokens,0) + coalesce(output_tokens,0)), 0))
            from bi.ai_provider_usage where at > date_trunc('day', now())),
  'last_30d', (select jsonb_build_object('calls', count(*), 'ok', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
            'tokens', coalesce(sum(coalesce(prompt_tokens,0) + coalesce(output_tokens,0)), 0))
            from bi.ai_provider_usage where at > now() - interval '30 days'),
  'last_failure', (select jsonb_build_object('at', u.at, 'purpose', u.purpose, 'note', bi.no_vendor(u.note),
                     'engine', case when u.model in (cf.am, cf.gm) then 'main' when u.model = cf.em then 'memory' else 'backup' end)
                     from bi.ai_provider_usage u, cf where not u.ok order by u.at desc limit 1),
  'knowledge', (select jsonb_build_object('documents', (select count(*) from bi.kb_doc where retired_at is null),
            'chunks', count(*), 'embedded', count(*) filter (where embedding is not null)) from bi.kb_chunk where active),
  'last_engine_check', (select max(checked_at) from bi.ai_model_check))
$f$;
delete from bi.api_cache where fn = 'ai_status';
