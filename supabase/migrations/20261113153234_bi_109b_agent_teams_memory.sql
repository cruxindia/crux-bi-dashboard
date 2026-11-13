-- Applied to Supabase project via MCP on 20261113153234
-- wave 109b (13-Nov-2026, owner 17:52 IST): 26 Gemini keys (owner's separate projects) form agent teams; each agent uses its own key.
-- Shared memory of findings and decisions between agents, with evidence, so they stay grounded and consistent.
-- Keys live only in Vault (names gemini_key_<team>_<n>); only the service role (Edge Function) can read them, through bi_ai_gateway.

-- usage rows carry the agent whose key was used (null = the main key), so each key has its own daily count
alter table bi.ai_provider_usage add column if not exists agent_id text;
create index if not exists ai_provider_usage_agent_day on bi.ai_provider_usage (agent_id, at) where agent_id is not null;
insert into bi.ai_config (key, value, note, updated_at, updated_by) values ('AGENT_KEY_DAILY_CAP', '200', 'wave 109b: AI calls per day per agent key (each key is a separate project with its own quota)', now(), 'wave 109b')
on conflict (key) do nothing;

create table if not exists bi.ai_agent (
  agent_id text primary key, team text not null, title text not null, role text not null, key_name text not null,
  enabled boolean not null default true, job_kind text, audience text not null default 'admin', sort int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
alter table bi.ai_agent enable row level security;
revoke all on bi.ai_agent from anon, authenticated;
comment on table bi.ai_agent is 'Agent register: one Gemini key (Vault name) per agent; team, role and the job it runs. Wave 109b.';

insert into bi.ai_agent (agent_id, team, title, role, key_name, enabled, job_kind, audience, sort) values
 ('process_1', 'Ask Crux', 'Ask Crux analyst — dashboard users', 'Answers questions asked on the dashboard (viewers).', 'gemini_key_process_1', true, null, 'all', 11),
 ('process_2', 'Ask Crux', 'Ask Crux analyst — management and admin', 'Answers questions asked with the admin key, so management never waits behind other users.', 'gemini_key_process_2', true, null, 'admin', 12),
 ('process_3', 'Ask Crux', 'Ask Crux deep analysis', 'Takes multi-part "why / compare / plan" questions with a larger look-up budget.', 'gemini_key_process_3', true, null, 'all', 13),
 ('process_4', 'Ask Crux', 'Memory curator', 'After each answer, records the finding (scope, figures, as-of) in the shared memory so later answers and agents build on it.', 'gemini_key_process_4', true, null, 'admin', 14),
 ('process_5', 'Ask Crux', 'Ask Crux quality review', 'Daily review of the questions asked: wrong measure, failed or slow answers; proposes lessons for admin approval.', 'gemini_key_process_5', true, 'chat_review', 'admin', 15),
 ('process_6', 'Ask Crux', 'Tile and table explainer', 'Answers questions asked from a tile, table or chart on a page.', 'gemini_key_process_6', true, null, 'all', 16),
 ('process_7', 'Ask Crux', 'Reserve analyst 1', 'Spare; not used until enabled.', 'gemini_key_process_7', false, null, 'admin', 17),
 ('process_8', 'Ask Crux', 'Reserve analyst 2', 'Spare; not used until enabled.', 'gemini_key_process_8', false, null, 'admin', 18),
 ('process_9', 'Ask Crux', 'Reserve analyst 3', 'Spare; not used until enabled.', 'gemini_key_process_9', false, null, 'admin', 19),
 ('pdm_1', 'Management', 'Morning brief', 'Daily briefing notes on the Overview for everyone.', 'gemini_key_pdm_1', true, 'daily_brief', 'all', 21),
 ('pdm_2', 'Management', 'Target and pace watch', 'Daily: which zones, teams and clients will miss the month, the pace needed per working day, and what changed since yesterday.', 'gemini_key_pdm_2', true, 'target_watch', 'admin', 22),
 ('pdm_3', 'Management', 'Zone review — West', 'Rest of Maharashtra, Mumbai & Goa, Gujarat, Bhopal/MP: business vs target and BAU, root cause, branches and units, actions.', 'gemini_key_pdm_3', true, 'zone_west', 'admin', 23),
 ('pdm_4', 'Management', 'Zone review — North and East', 'Delhi, Lucknow, Patna, Punjab, Kolkata, Guwahati, Odisha.', 'gemini_key_pdm_4', true, 'zone_north_east', 'admin', 24),
 ('pdm_5', 'Management', 'Zone review — South', 'Bengaluru, Hyderabad, Tamil Nadu.', 'gemini_key_pdm_5', true, 'zone_south', 'admin', 25),
 ('pdm_6', 'Management', 'Client review', 'Top client families: business, potential, units (RACPC etc.), risks and asks for the relationship team.', 'gemini_key_pdm_6', true, 'client_review', 'admin', 26),
 ('pdm_7', 'Management', 'Weekly review', 'Monday review of the week for admins.', 'gemini_key_pdm_7', true, 'weekly_review', 'admin', 27),
 ('pdm_8', 'Management', 'Month-close summary', 'After a month closes: the month for the MD in one page — result, causes, decisions taken, next month.', 'gemini_key_pdm_8', true, 'month_close', 'admin', 28),
 ('pd_1', 'Process & data', 'Data readiness and anomaly watch', 'Daily: missing or late uploads, sudden drops or jumps, figures that do not reconcile.', 'gemini_key_pd_1', true, 'data_watch', 'admin', 31),
 ('pd_2', 'Process & data', 'Branch network and potential', 'RACPC, Mini RACPC, RAC and branch counts, dormant and never-active units worth a visit, potential gap.', 'gemini_key_pd_2', true, 'branch_network', 'admin', 32),
 ('pd_3', 'Process & data', 'Force1 and TAT operations', 'Force1 use, case and field TAT, backlog and SLA by zone and client.', 'gemini_key_pd_3', true, 'ops_watch', 'admin', 33),
 ('pd_4', 'Process & data', 'Collections and receivables', 'Outstanding, ageing over 90/180 days, collections vs billing, who to chase.', 'gemini_key_pd_4', true, 'collections_watch', 'admin', 34),
 ('pd_5', 'Process & data', 'Market and client news', 'Bank and lending news that affects Crux clients.', 'gemini_key_pd_5', true, 'market_news', 'all', 35),
 ('pd_6', 'Process & data', 'Decision-log auditor', 'Checks new findings against earlier decisions and figures; marks contradictions and closes what is superseded.', 'gemini_key_pd_6', true, 'decision_audit', 'admin', 36),
 ('pd_7', 'Process & data', 'Second-opinion checker', 'Re-checks high-stakes answers and reports (figures, scope, count vs value) before they are shown.', 'gemini_key_pd_7', true, null, 'admin', 37),
 ('pd_8', 'Process & data', 'Reserve 1', 'Spare; not used until enabled.', 'gemini_key_pd_8', false, null, 'admin', 38),
 ('pd_9', 'Process & data', 'Reserve 2', 'Spare; not used until enabled.', 'gemini_key_pd_9', false, null, 'admin', 39)
on conflict (agent_id) do nothing;

create table if not exists bi.agent_memory (
  id bigserial primary key, at timestamptz not null default now(), agent_id text not null, team text,
  kind text not null check (kind in ('finding', 'decision', 'question', 'handoff', 'correction', 'note')),
  topics text[] not null default '{}', scope jsonb not null default '{}', content text not null, figures jsonb, evidence jsonb,
  data_version bigint, as_of date, status text not null default 'open' check (status in ('open', 'confirmed', 'superseded', 'rejected', 'closed')),
  supersedes bigint references bi.agent_memory(id), decided_by text, expires_at timestamptz,
  audience text not null default 'admin' check (audience in ('all', 'admin')));
create index if not exists agent_memory_topics on bi.agent_memory using gin (topics);
create index if not exists agent_memory_at on bi.agent_memory (at desc);
alter table bi.agent_memory enable row level security;
revoke all on bi.agent_memory from anon, authenticated;
comment on table bi.agent_memory is 'Shared memory of the agent teams: findings, decisions, open questions and hand-offs with topics (zone:X, client:Y, team:N, unit:RACPC, metric:target), figures, evidence (look-ups and data version) and status. Wave 109b.';

create table if not exists bi.ai_key_check (
  key_name text primary key, checked_at timestamptz not null default now(), ok boolean not null, http_status int, note text);
alter table bi.ai_key_check enable row level security;
revoke all on bi.ai_key_check from anon, authenticated;

-- Vault reads: the backup key as before, plus the agent keys (service role only, through the gateway)
create or replace function bi.ai_secret(p jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public', 'vault' as $f$
  select jsonb_build_object('value', (select decrypted_secret from vault.decrypted_secrets
     where name = p->>'name' and (p->>'name' = 'ai_backup_key' or p->>'name' ~ '^gemini_key_(process|pdm|pd)_[1-9][0-9]?$')))
$f$;

create or replace function bi.ai_agent_keys() returns jsonb language sql stable security definer set search_path to 'bi', 'public', 'vault' as $f$
  select coalesce(jsonb_object_agg(a.agent_id, jsonb_build_object('key', s.decrypted_secret, 'team', a.team, 'title', a.title, 'job_kind', a.job_kind)), '{}'::jsonb)
    from bi.ai_agent a join vault.decrypted_secrets s on s.name = a.key_name where a.enabled
$f$;

create or replace function bi.agent_memory_read(p jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with q as (select m.* from bi.agent_memory m
     where m.status in ('open', 'confirmed') and (m.expires_at is null or m.expires_at > now())
       and (coalesce(jsonb_array_length(p->'topics'), 0) = 0 or m.topics && array(select lower(jsonb_array_elements_text(p->'topics'))))
       and (p->>'team' is null or m.team = p->>'team')
       and (m.audience = 'all' or p->>'audience' = 'admin')
     order by (m.kind = 'decision') desc, (m.status = 'confirmed') desc, m.at desc
     limit least(greatest(coalesce((p->>'limit')::int, 20), 1), 80))
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'at', to_char(at at time zone 'Asia/Kolkata', 'DD-Mon-YYYY HH24:MI'), 'agent', agent_id, 'kind', kind, 'status', status,
           'topics', topics, 'scope', scope, 'as_of', as_of, 'content', content, 'figures', figures) order by at desc), '[]'::jsonb) from q
$f$;

create or replace function bi.agent_memory_write(p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare it jsonb; n int := 0; v_id bigint; v_ver bigint := bi.cache_version();
begin
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    if coalesce(trim(it->>'content'), '') = '' or (it->>'kind') not in ('finding', 'decision', 'question', 'handoff', 'correction', 'note') then continue; end if;
    insert into bi.agent_memory (agent_id, team, kind, topics, scope, content, figures, evidence, data_version, as_of, status, supersedes, decided_by, expires_at, audience)
    values (coalesce(p->>'agent_id', it->>'agent_id', 'unknown'), (select team from bi.ai_agent where agent_id = coalesce(p->>'agent_id', it->>'agent_id')), it->>'kind',
            array(select lower(jsonb_array_elements_text(coalesce(it->'topics', '[]'::jsonb)))), coalesce(it->'scope', '{}'::jsonb), left(it->>'content', 2000),
            it->'figures', coalesce(it->'evidence', p->'evidence'), v_ver, nullif(it->>'as_of', '')::date,
            case when it->>'status' in ('open', 'confirmed', 'closed') then it->>'status' else 'open' end, nullif(it->>'supersedes', '')::bigint, it->>'decided_by',
            case when it->>'kind' in ('finding', 'note') then now() + interval '45 days' end,
            case when coalesce(it->>'audience', p->>'audience') = 'all' then 'all' else 'admin' end)
    returning id into v_id;
    if nullif(it->>'supersedes', '') is not null then update bi.agent_memory set status = 'superseded' where id = (it->>'supersedes')::bigint and status in ('open', 'confirmed'); end if;
    n := n + 1;
  end loop;
  for it in select * from jsonb_array_elements(coalesce(p->'status_updates', '[]'::jsonb)) loop
    update bi.agent_memory set status = it->>'status', decided_by = coalesce(it->>'decided_by', p->>'agent_id')
     where id = (it->>'id')::bigint and it->>'status' in ('confirmed', 'superseded', 'rejected', 'closed');
  end loop;
  return jsonb_build_object('written', n);
end $f$;

create or replace function bi.ai_key_check_put(p jsonb) returns jsonb language sql security definer set search_path to 'bi', 'public' as $f$
  with x as (insert into bi.ai_key_check (key_name, checked_at, ok, http_status, note)
             select r->>'key_name', now(), (r->>'ok')::boolean, nullif(r->>'http_status', '')::int, left(r->>'note', 300) from jsonb_array_elements(coalesce(p->'results', '[]'::jsonb)) r
             where r->>'key_name' ~ '^gemini_key_(process|pdm|pd)_[1-9][0-9]?$'
             on conflict (key_name) do update set checked_at = excluded.checked_at, ok = excluded.ok, http_status = excluded.http_status, note = excluded.note returning 1)
  select jsonb_build_object('stored', count(*)) from x
$f$;

-- admin view of the teams (no keys): register, last key check, memory counts, latest decisions
create or replace function bi.api_agent_team() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  select jsonb_build_object(
    'agents', (select coalesce(jsonb_agg(jsonb_build_object('agent_id', a.agent_id, 'team', a.team, 'title', a.title, 'role', a.role, 'enabled', a.enabled, 'job_kind', a.job_kind, 'audience', a.audience,
                 'key_ok', k.ok, 'key_checked', to_char(k.checked_at at time zone 'Asia/Kolkata', 'DD-Mon HH24:MI'), 'key_note', k.note,
                 'calls_today', (select count(*) from bi.ai_provider_usage u where u.agent_id = a.agent_id and u.at > date_trunc('day', now())),
                 'calls_7d', (select count(*) from bi.ai_provider_usage u where u.agent_id = a.agent_id and u.at > now() - interval '7 days'),
                 'fails_7d', (select count(*) from bi.ai_provider_usage u where u.agent_id = a.agent_id and u.at > now() - interval '7 days' and not u.ok),
                 'memory_items', (select count(*) from bi.agent_memory m where m.agent_id = a.agent_id)) order by a.sort), '[]'::jsonb)
               from bi.ai_agent a left join bi.ai_key_check k on k.key_name = a.key_name),
    'memory', (select jsonb_build_object('total', count(*), 'open', count(*) filter (where status = 'open'), 'confirmed', count(*) filter (where status = 'confirmed'),
                 'decisions', count(*) filter (where kind = 'decision'), 'superseded', count(*) filter (where status = 'superseded')) from bi.agent_memory),
    'recent', (select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) from (select jsonb_build_object('id', id, 'at', to_char(at at time zone 'Asia/Kolkata', 'DD-Mon HH24:MI'),
                 'agent', agent_id, 'kind', kind, 'status', status, 'topics', topics, 'content', content) x from bi.agent_memory order by id desc limit 30) q));
$f$;

-- gateway ops for the Edge Function (service role)
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $f$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $f$;
select pg_temp.patch('public.bi_ai_gateway(jsonb)'::regprocedure, array[
  E'  elsif op = ''secret'' then return bi.ai_secret(p);   -- wave 106a: backup engine key from Vault (service role only)',
  E'  elsif op = ''secret'' then return bi.ai_secret(p);   -- wave 106a: backup engine key from Vault; wave 109b: agent keys too (service role only)\n  elsif op = ''agent_keys'' then return bi.ai_agent_keys();   -- wave 109b: one Gemini key per agent (Vault)\n  elsif op = ''memory_read'' then return bi.agent_memory_read(p);\n  elsif op = ''memory_write'' then return bi.agent_memory_write(p);\n  elsif op = ''key_check_put'' then return bi.ai_key_check_put(p);',
  E'else ''AI_DAILY_CAP'' end), '''')::int, 200);',
  E'else case when coalesce(p->>''agent'', '''') <> '''' then ''AGENT_KEY_DAILY_CAP'' else ''AI_DAILY_CAP'' end end), '''')::int, 200);   -- wave 109b: each agent key has its own daily cap',
  E'     where at > date_trunc(''day'', now()) and (case when p->>''purpose'' = ''embed''',
  E'     where at > date_trunc(''day'', now()) and agent_id is not distinct from nullif(p->>''agent'', '''') and (case when p->>''purpose'' = ''embed'''], array[1, 1, 1]);

select pg_temp.patch('public.bi_ai_record(jsonb)'::regprocedure, array[
  E'insert into bi.ai_provider_usage(provider, model, purpose, message_id, ok, ms, input_chars, output_chars, note, http_status, retries, prompt_tokens, output_tokens)',
  E'insert into bi.ai_provider_usage(provider, model, purpose, message_id, ok, ms, input_chars, output_chars, note, http_status, retries, prompt_tokens, output_tokens, agent_id)',
  E'nullif(p->>''prompt_tokens'','''')::int, nullif(p->>''output_tokens'','''')::int);',
  E'nullif(p->>''prompt_tokens'','''')::int, nullif(p->>''output_tokens'','''')::int, nullif(p->>''agent'', ''''));'], array[1, 1]);

-- unit names: "RACPAC" spelling and SBI's "SMECC" (SME credit centre) were missed (13-Nov check of Gujarat SBI)
create or replace function bi.unit_type(p_name text, p_type text) returns text language sql immutable parallel safe set search_path to 'pg_catalog' as $f$
  select case
    when p_name ~* 'mini\s*-?\s*rac\s*pa?c' then 'Mini RACPC'
    when p_name ~* 'rac\s*pa?c' then 'RACPC'
    when p_name ~* 'rasme\s*c|rasmec' then 'RASMECCC'
    when p_name ~* 'smecc|\msme\s+ccc?\M' then 'SMECCC'
    when p_name ~* '\msarc\M' then 'SARC'
    when p_name ~* '\mrac\M' then 'RAC'
    when p_name ~* '\mracc\M' then 'RACC'
    when p_name ~* 'cpc' then 'Other CPC'
    when coalesce(p_type, 'branch') = 'processing_centre' then 'Other processing centre'
    when coalesce(p_type, 'branch') = 'office' then 'Office'
    when p_name ~* '\mm?sme\M' then 'SME branch'
    else 'Branch' end $f$;
do $d$
declare v text := pg_get_viewdef('ai.branches'::regclass, true); n int;
begin
  n := (length(v) - length(replace(v, $q$'mini\s*-?\s*racpc'::text$q$, ''))) / length($q$'mini\s*-?\s*racpc'::text$q$);
  if n <> 1 then raise exception 'ai.branches: mini pattern found % times', n; end if;
  v := replace(v, $q$'mini\s*-?\s*racpc'::text$q$, $q$'mini\s*-?\s*rac\s*pa?c'::text$q$);
  v := replace(v, $q$WHEN u.branch_name ~* 'racpc'::text$q$, $q$WHEN u.branch_name ~* 'rac\s*pa?c'::text$q$);
  v := replace(v, $q$'smeccc|sme\s*ccc'::text$q$, $q$'smecc|\msme\s+ccc?\M'::text$q$);
  if strpos(v, $q$'rac\s*pa?c'::text$q$) = 0 or strpos(v, $q$'smecc|\msme\s+ccc?\M'::text$q$) = 0 then raise exception 'ai.branches: patterns not replaced'; end if;
  execute 'create or replace view ai.branches as ' || v;
end $d$;
