-- Wave 121b (25-Nov-2026): extra free AI keys ("key pool") that admins add on the dashboard.
-- Owner 25-Nov 16:43: "where can I add free API keys, as now tokens of the keys are getting over fast".
-- Keys are stored encrypted in Vault (gemini_key_pool_1 … _20) and never shown again; the page sees only a label, the last 4 characters,
-- when it was added and how it is doing. Ask Crux and the agents use a pool key only when their own key (or the main key) has used up its
-- allowance or is refused — the next pool key is tried, one that ran out rests for 15 minutes. Additive; old bodies in bi.fn_backup ('121b').

create table if not exists bi.ai_key_pool (
  slot int primary key check (slot between 1 and 20),
  label text not null default '',
  key_tail text not null,
  added_by text,
  added_at timestamptz not null default now());
alter table bi.ai_key_pool enable row level security;   -- read only through the functions below
comment on table bi.ai_key_pool is 'wave 121b: extra free AI keys (the keys themselves are in Vault as gemini_key_pool_<slot>)';

create or replace function public.bi_ai_pool_put(p_admin_key text, p_value text, p_label text default '', p_by text default 'admin')
returns jsonb language plpgsql security definer set search_path to 'bi', 'public', 'vault' as $$
declare v text := btrim(coalesce(p_value, '')); s int; nm text;
begin
  if not coalesce(bi.admin_ok(p_admin_key), false) then return jsonb_build_object('error', 'admin key required'); end if;
  if v !~ '^AIza[0-9A-Za-z_-]{35}$' then return jsonb_build_object('error', 'that does not look like a free AI key (it starts with AIza and is 39 characters)'); end if;
  if exists (select 1 from vault.decrypted_secrets where (name ~ '^gemini_key_' or name = 'ai_backup_key') and decrypted_secret = v) then
    return jsonb_build_object('error', 'this key is already stored — a second copy adds no allowance');
  end if;
  select min(g) into s from generate_series(1, 20) g where not exists (select 1 from bi.ai_key_pool k where k.slot = g);
  if s is null then return jsonb_build_object('error', 'all 20 places are used — remove a key first'); end if;
  nm := 'gemini_key_pool_' || s;
  delete from vault.secrets where name = nm;
  perform vault.create_secret(v, nm, 'Ask Crux extra key (wave 121b); read only by ask-crux through the service-role gateway');
  insert into bi.ai_key_pool(slot, label, key_tail, added_by) values (s, left(btrim(coalesce(p_label, '')), 60), right(v, 4), left(coalesce(nullif(p_by, ''), 'admin'), 60));
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (left(coalesce(nullif(p_by, ''), 'admin'), 60), 'ai_key_pool_added', 'vault', nm, jsonb_build_object('slot', s, 'label', left(btrim(coalesce(p_label, '')), 60)));
  return jsonb_build_object('ok', true, 'slot', s);
end $$;

create or replace function public.bi_ai_pool_drop(p_admin_key text, p_slot int, p_by text default 'admin')
returns jsonb language plpgsql security definer set search_path to 'bi', 'public', 'vault' as $$
begin
  if not coalesce(bi.admin_ok(p_admin_key), false) then return jsonb_build_object('error', 'admin key required'); end if;
  if not exists (select 1 from bi.ai_key_pool where slot = p_slot) then return jsonb_build_object('error', 'no key in that place'); end if;
  delete from vault.secrets where name = 'gemini_key_pool_' || p_slot;
  delete from bi.ai_key_pool where slot = p_slot;
  delete from bi.ai_key_check where key_name = 'gemini_key_pool_' || p_slot;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (left(coalesce(nullif(p_by, ''), 'admin'), 60), 'ai_key_pool_removed', 'vault', 'gemini_key_pool_' || p_slot, jsonb_build_object('slot', p_slot));
  return jsonb_build_object('ok', true);
end $$;

-- the page's list (admin): no key, only label, last 4 characters, use today and the last check
create or replace function public.bi_ai_pool_list(p_admin_key text)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $$
begin
  if not coalesce(bi.admin_ok(p_admin_key), false) then return jsonb_build_object('error', 'admin key required'); end if;
  return jsonb_build_object('keys', coalesce((select jsonb_agg(jsonb_build_object('slot', k.slot, 'label', k.label, 'ends_with', k.key_tail, 'added_at', k.added_at, 'added_by', k.added_by,
      'calls_today', (select count(*) from bi.ai_provider_usage u where u.agent_id = 'pool_' || k.slot and u.at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'),
      'failed_today', (select count(*) from bi.ai_provider_usage u where u.agent_id = 'pool_' || k.slot and not u.ok and u.at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'),
      'checked_at', c.checked_at, 'check_ok', c.ok, 'check_note', c.note) order by k.slot)
      from bi.ai_key_pool k left join bi.ai_key_check c on c.key_name = 'gemini_key_pool_' || k.slot), '[]'::jsonb),
    'places', 20,
    -- why calls failed in the last 7 days (all keys): busy model vs allowance used up vs other
    'failures_7d', (select jsonb_build_object('busy_or_timeout', count(*) filter (where http_status in (0, 503)), 'allowance_used_up', count(*) filter (where http_status = 429),
                      'retired_model', count(*) filter (where http_status = 404), 'other', count(*) filter (where coalesce(http_status, -1) not in (0, 503, 429, 404)), 'calls', (select count(*) from bi.ai_provider_usage where at > now() - interval '7 days'))
                    from bi.ai_provider_usage where at > now() - interval '7 days' and not ok));
end $$;

-- service role (ask-crux): the pool keys
create or replace function bi.ai_pool_keys()
returns jsonb language sql stable security definer set search_path to 'bi', 'public', 'vault' as $$
  select coalesce(jsonb_agg(jsonb_build_object('slot', k.slot, 'key', s.decrypted_secret) order by k.slot), '[]'::jsonb)
    from bi.ai_key_pool k join vault.decrypted_secrets s on s.name = 'gemini_key_pool_' || k.slot
$$;
revoke all on function bi.ai_pool_keys() from public, anon, authenticated;

create or replace function pg_temp.patch(p regprocedure, olds text[], news text[]) returns void language plpgsql as $$
declare d text := pg_get_functiondef(p); i int; k int;
begin
  insert into bi.fn_backup(fn, def, wave) values (p::text, d, '121b');
  for i in 1 .. array_length(olds, 1) loop
    k := (length(d) - length(replace(d, olds[i], ''))) / length(olds[i]);
    if k <> 1 then raise exception 'patch %: piece % found % times', p, i, k; end if;
    d := replace(d, olds[i], news[i]);
  end loop;
  execute d;
end $$;

select pg_temp.patch('public.bi_ai_gateway(jsonb)'::regprocedure,
  array[$a$  elsif op = 'agent_keys' then return bi.ai_agent_keys();   -- wave 109b: one Gemini key per agent (Vault)$a$],
  array[$a$  elsif op = 'agent_keys' then return bi.ai_agent_keys();   -- wave 109b: one Gemini key per agent (Vault)
  elsif op = 'pool_keys' then return bi.ai_pool_keys();   -- wave 121b: extra keys added by admins (Vault)$a$]);
select pg_temp.patch('bi.ai_secret(jsonb)'::regprocedure,
  array[$a$p->>'name' ~ '^gemini_key_(process|pdm|pd)_[1-9][0-9]?$'$a$],
  array[$a$p->>'name' ~ '^gemini_key_(process|pdm|pd|pool)_[1-9][0-9]?$'$a$]);
select pg_temp.patch('bi.ai_key_check_put(jsonb)'::regprocedure,
  array[$a$r->>'key_name' ~ '^gemini_key_(process|pdm|pd)_[1-9][0-9]?$'$a$],
  array[$a$r->>'key_name' ~ '^gemini_key_(process|pdm|pd|pool)_[1-9][0-9]?$'$a$]);
