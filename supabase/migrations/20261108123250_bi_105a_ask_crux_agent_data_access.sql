-- Applied to Supabase project via MCP on 20261108123250
-- wave 105a (owner 8-Nov-2026): Ask Crux v4 — AI agent data access. Owner choice: build now on the current (free-tier) Gemini key; business figures may go to Gemini, people's names never do.
create schema if not exists ai;
revoke all on schema ai from public;
comment on schema ai is 'wave 105: curated read-only views for the Ask Crux AI agent. No personal-data columns. Queried only through ai.run_select (service role).';

create or replace view ai.teams as
  select l.id team_id, l.label team, l.code team_code, coalesce(l.zone_group, l.rollup_zone) zone_group, l.region, l.tier, l.is_rollup
    from bi.location l;
comment on view ai.teams is 'Teams (also called locations) and their zone group. is_rollup = zone roll-up row, not a team.';

create or replace view ai.clients as
  select c.code client_code, c.label client_name, c.family client_family, c.product, c.summary_under from bi.client c;
comment on view ai.clients is 'Client codes (a bank product line, e.g. SBI_HL) and their client family (the bank, e.g. SBI).';

create or replace view ai.monthly_business as
  select v.month, v.location_id team_id, l.label team, coalesce(l.zone_group, l.rollup_zone) zone_group, v.client_code, c.family client_family,
         v.cases, v.revenue, v.target_cases, v.revenue_target, v.as_of
    from bi.v_month_business v left join bi.location l on l.id = v.location_id left join bi.client c on c.code = v.client_code;
comment on view ai.monthly_business is 'Business per month x team x client from the Zonal Tracker (month-end figure; the current month is month to date as of as_of). Revenue in rupees. target_cases / revenue_target = the tracker target.';

create or replace view ai.tracker_daily as
  select r.snapshot_date, s.report_month as month, r.zone_group, r.location_id team_id, l.label team, r.client_code, c.family client_family,
         r.target_cases, r.mtd_cases, r.rate, r.revenue_target, r.revenue_actual mtd_revenue
    from bi.zt_row r join bi.zt_snapshot s on s.snapshot_date = r.snapshot_date
    left join bi.location l on l.id = r.location_id left join bi.client c on c.code = r.client_code
   where r.row_type = 'leaf';
comment on view ai.tracker_daily is 'Daily Zonal Tracker report rows (team x client), cumulative month to date at each report date. Day-on-day additions = difference between consecutive report dates of the same month.';

create or replace view ai.cases as
  select cs.case_id, cs.client_code, c.family client_family, cs.branch_code, cs.location_id team_id, cs.status,
         (cs.received_at at time zone 'Asia/Kolkata')::date received_on, (cs.completed_at at time zone 'Asia/Kolkata')::date completed_on,
         (cs.due_at at time zone 'Asia/Kolkata')::date due_on, cs.received_month, cs.points_declared,
         round((extract(epoch from (cs.completed_at - cs.received_at)) / 3600.0)::numeric, 1) raw_tat_hours
    from bi.case_store cs left join bi.client c on c.code = cs.client_code;
comment on view ai.cases is 'Force1 case records (operations). raw_tat_hours is received to completed without the dashboard''s validity rules; use the operations tool for official TAT.';

create or replace view ai.branches as
  with pr as (select x.month, array(select jsonb_array_elements_text(coalesce(x.inputs->'inactive_clients', '[]'::jsonb))) inact
                from bi.potential_run x order by x.run_id desc limit 1),
       uni as (select distinct on (b.client_family, b.code_norm) b.client_family, b.code_norm, b.branch_code, b.branch_name, b.city, b.district,
                      b.state, b.pincode, coalesce(b.location_id, fr.location_id) team_id, b.zone_group, b.branch_type
                 from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid cross join pr
                where b.status = 'active' and coalesce(b.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')
                  and coalesce(b.source_type, '') <> 'official_website' and coalesce(b.branch_type, 'branch') <> 'office'
                  and b.code_norm is not null and b.client_family is not null and b.client_family <> all (pr.inact)
                order by b.client_family, b.code_norm, (coalesce(b.location_id, fr.location_id) is null), b.branch_uid)
  select u.client_family, u.branch_code, u.branch_name, u.city, u.district, u.state, u.pincode, u.team_id, l.label team,
         coalesce(l.zone_group, l.rollup_zone, u.zone_group) zone_group, a.first_m first_case_month, a.last_m last_case_month,
         coalesce(a.n, 0) cases_total, coalesce(a.n3, 0) cases_last_3_months,
         case when a.code_norm is null then 'never active' when a.last_m >= (pr.month - interval '2 months')::date then 'active' else 'dormant' end crux_status,
         pr.month status_month
    from uni u cross join pr left join bi.branch_activity a on a.fam = u.client_family and a.code_norm = u.code_norm
    left join bi.location l on l.id = u.team_id;
comment on view ai.branches is 'Client bank branches in scope (same universe and status rule as the dashboard branch list): active = a case in the last 3 months up to status_month, dormant = cases before that, never active = no case ever.';

create or replace view ai.potential as
  select c.zone_group, c.location_id team_id, l.label team, c.client_family, c.layer, c.branches, c.cases, c.revenue, r.month basis_month, r.run_id
    from bi.potential_cell c join (select x.run_id, x.month from bi.potential_run x order by x.run_id desc limit 1) r on r.run_id = c.run_id
    left join bi.location l on l.id = c.location_id;
comment on view ai.potential is 'Monthly business potential by zone x team x client family (latest run). layer: current, recover (back to best 3 months), dormant (reactivate dormant branches), never_served (never-active branches of clients the team serves), never_not_served (clients Crux has, not served by this team), never_no_team (no team covers the area). Revenue in rupees per month.';

create or replace view ai.outstanding as
  select a.location_id team_id, l.label team, coalesce(l.zone_group, l.rollup_zone) zone_group, a.family client_family, a.inv_month invoice_month,
         a.n invoices, a.gross, a.net, a.os outstanding, u.as_of
    from bi.fin_os_agg a join (select x.id, x.as_of from bi.fin_upload x where x.kind = 'outstanding' and x.status = 'committed' order by x.as_of desc, x.id desc limit 1) u on u.id = a.upload_id
    left join bi.location l on l.id = a.location_id;
comment on view ai.outstanding is 'Unpaid invoices (receivables) by team x client family x invoice month from the latest committed outstanding workbook (as_of). outstanding = amount still unpaid, rupees.';

create or replace view ai.collections as
  select a.location_id team_id, l.label team, coalesce(l.zone_group, l.rollup_zone) zone_group, a.family client_family, a.rcpt_month receipt_month,
         a.n receipts, a.amount collected, u.as_of
    from bi.fin_rcpt_agg a join (select x.id, x.as_of from bi.fin_upload x where x.kind = 'collection' and x.status = 'committed' order by x.as_of desc, x.id desc limit 1) u on u.id = a.upload_id
    left join bi.location l on l.id = a.location_id;
comment on view ai.collections is 'Money collected by team x client family x receipt month from the latest committed collection workbook (as_of). Rupees.';

do $r$ begin
  if not exists (select 1 from pg_roles where rolname = 'ai_reader') then create role ai_reader nologin noinherit; end if;
end $r$;
grant ai_reader to postgres;
grant usage on schema ai to ai_reader;
grant select on all tables in schema ai to ai_reader;
grant create on schema ai to ai_reader;

create or replace function ai.run_select(q text, max_rows int default 200)
returns jsonb language plpgsql volatile security definer set search_path = ai, pg_catalog as $f$
declare
  s text := regexp_replace(btrim(coalesce(q, '')), ';\s*$', '');
  low text; w text; r jsonb; plan jsonb; cost numeric; lim int := least(greatest(coalesce(max_rows, 200), 1), 500); wrapped text;
  fn_ok text[] := array['count','sum','avg','min','max','round','ceil','ceiling','floor','abs','sign','sqrt','power','ln','log','exp','mod','div','trunc',
    'width_bucket','coalesce','nullif','greatest','least','date_trunc','date_part','extract','to_char','to_date','to_number','age','make_date',
    'make_interval','justify_days','lower','upper','initcap','trim','btrim','ltrim','rtrim','length','char_length','substr','substring','left','right',
    'position','strpos','split_part','replace','concat','concat_ws','string_agg','array_agg','array_length','cardinality','unnest','cast','lag','lead',
    'row_number','rank','dense_rank','ntile','percent_rank','cume_dist','first_value','last_value','nth_value','percentile_cont','percentile_disc','mode',
    'stddev','stddev_pop','stddev_samp','variance','var_pop','var_samp','corr','covar_pop','regr_slope','regr_intercept','bool_and','bool_or','every',
    'jsonb_build_object','jsonb_agg','json_agg','to_jsonb','regexp_replace','date','numeric','decimal','varchar','char','timestamp','timestamptz',
    'interval','float8','int','integer','bigint','text'];
  kw_ok text[] := array['in','exists','any','all','some','over','filter','within','as','from','join','on','and','or','not','when','then','else','select',
    'where','by','using','lateral','values','having','limit','offset','union','intersect','except','between','is','like','ilike','distinct','case','with',
    'array','row','rows','range','groups','partition','order','group','cube','rollup','grouping','sets','end','asc','desc','nulls','first','last'];
begin
  low := lower(s);
  if length(s) = 0 or length(s) > 4000 then raise exception 'query is empty or longer than 4000 characters'; end if;
  if low !~ '^\s*(select|with)\M' then raise exception 'only one SELECT (or WITH ... SELECT) query is allowed'; end if;
  if s ~ '(;|--|/\*|\$|\\)' then raise exception 'semicolons, comments, dollar quotes and backslashes are not allowed'; end if;
  if low ~ '\m(insert|update|delete|merge|create|alter|drop|truncate|grant|revoke|copy|execute|call|do|lock|listen|notify|unlisten|vacuum|analy[sz]e|refresh|comment|security|set|reset|prepare|deallocate|declare|fetch|move|close|discard|load|import|into|returning|cluster|reindex|checkpoint)\M' then
    raise exception 'only read-only SELECT queries are allowed';
  end if;
  if low ~ '\mpg_\w*|information_schema|\m(public|bi|auth|storage|extensions|graphql|graphql_public|realtime|vault|net|cron|pgsodium|supabase_functions|supabase_migrations)\s*\.' then
    raise exception 'only the ai views can be queried (teams, clients, monthly_business, tracker_daily, cases, branches, potential, outstanding, collections)';
  end if;
  if s ~ '"[^"]*"\s*\(' then raise exception 'quoted function names are not allowed'; end if;
  for w in select lower(m[1]) from regexp_matches(s, '([A-Za-z_][A-Za-z0-9_]*)\s*\(', 'g') m loop
    if not (w = any (fn_ok) or w = any (kw_ok)) then raise exception 'function "%" is not allowed in agent queries', w; end if;
  end loop;
  perform set_config('transaction_read_only', 'on', true);
  wrapped := format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (select * from (%s) q limit %s) t', s, lim);
  execute 'explain (format json) ' || wrapped into plan;
  cost := (plan->0->'Plan'->>'Total Cost')::numeric;
  if cost > 3000000 then
    raise exception 'query too heavy (estimated cost %): filter by month, team or client, or aggregate first', round(cost);
  end if;
  execute wrapped into r;
  return jsonb_build_object('rows', r, 'row_count', jsonb_array_length(r), 'truncated', jsonb_array_length(r) >= lim, 'est_cost', round(cost));
end $f$;
alter function ai.run_select(text, int) owner to ai_reader;
revoke create on schema ai from ai_reader;
revoke all on function ai.run_select(text, int) from public;
grant execute on function ai.run_select(text, int) to postgres, service_role;
comment on function ai.run_select(text, int) is 'wave 105: the Ask Crux agent''s SQL tool. One validated SELECT over the ai views, read-only transaction, EXPLAIN cost guard, max 500 rows. Runs as ai_reader (SELECT on schema ai only).';

create or replace function bi.ai_pii_tokens() returns jsonb language sql stable security definer set search_path = bi, public as $f$
  with tok as (
    select distinct t from (
      select regexp_split_to_table(upper(regexp_replace(coalesce(name_key, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') t from bi.employee
      union all select regexp_split_to_table(upper(regexp_replace(coalesce(display_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.employee
      union all select regexp_split_to_table(upper(regexp_replace(coalesce(stakeholder, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.location
      union all select regexp_split_to_table(upper(regexp_replace(coalesce(name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.workforce_master
      union all select regexp_split_to_table(upper(regexp_replace(coalesce(manager, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.branch_manager
      union all select regexp_split_to_table(upper(regexp_replace(coalesce(person, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.person_role) z
    where length(t) >= 3
      and t not in (select w from (
            select l0.w from (select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(recon_unit, '') || ' ' || coalesce(zone_group, '') || ' ' || coalesce(region, '')), '[^A-Z0-9]+') w from bi.location) l0
             where l0.w in (select upper(rp.place) from bi.ref_place rp)
                or l0.w not in (select regexp_split_to_table(upper(regexp_replace(coalesce(bm.manager, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.branch_manager bm
                                union all select regexp_split_to_table(upper(regexp_replace(coalesce(pr.person, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.person_role pr
                                union all select regexp_split_to_table(upper(regexp_replace(coalesce(lo.stakeholder, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.location lo)
            union all select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(family, '') || ' ' || coalesce(product, '')), '[^A-Z0-9]+') from bi.client
            union all select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '')), '[^A-Z0-9]+') from bi.zone_group) k where w <> '')
      and t not in ('THE','AND','FOR','HOW','WHY','WHAT','WHO','ARE','WAS','MORE','LESS','LAST','NEXT','MONTH','WEEK','YEAR','TEAM','BRANCH','CASE','CASES',
                    'TARGET','DOING','LOWER','HIGHER','BANK','ZONE','TODAY','SALES','TOTAL','REST','NEW','OLD','TOP','LOW','HIGH','BEST','GOOD','WELL','THIS',
                    'THAT','WITH','FROM','LOAN','HOME','CAR','DATA','FIELD','OFFICE','BACK','POINT','POINTS','ALL','ANY','NOT','OUR','YOU','CAN','SHOW','GIVE',
                    'ADMIN','ONLY','NAME','NONE','NULL','CRUX','INDIA','PAN'))
  select coalesce(jsonb_agg(t order by length(t) desc, t), '[]'::jsonb) from tok
$f$;
revoke all on function bi.ai_pii_tokens() from public, anon, authenticated;
comment on function bi.ai_pii_tokens() is 'wave 105: person-name tokens (employees, stakeholders, workforce, branch managers, role holders) that the Ask Crux agent replaces with codes (P1, P2 ...) before anything is sent to the AI, and maps back for display.';

alter table bi.ai_message add column if not exists trace jsonb;
comment on column bi.ai_message.trace is 'wave 105: Ask Crux agent trace — tools and queries used, rows returned, figure check, model calls. No names (codes only).';

create or replace function bi.ai_agent_log(p jsonb) returns jsonb language plpgsql security definer set search_path = bi, public as $f$
declare c uuid := nullif(p->>'conversation_id', '')::uuid; mid bigint;
begin
  if c is null or not exists (select 1 from bi.ai_conversation x where x.id = c) then
    insert into bi.ai_conversation(context) values (coalesce(p->'context', '{}'::jsonb)) returning id into c;
  end if;
  insert into bi.ai_message(conversation_id, question, intent, filters, answer, data_version, provider, model, trace)
  values (c, left(coalesce(p->>'question', ''), 500), coalesce(p->>'intent', 'agent'), coalesce(p->'filters', '{}'::jsonb), coalesce(p->'answer', '{}'::jsonb),
          bi.cache_version(), p->>'provider', p->>'model', p->'trace')
  returning id into mid;
  return jsonb_build_object('message_id', mid, 'conversation_id', c);
end $f$;
revoke all on function bi.ai_agent_log(jsonb) from public, anon, authenticated;

insert into bi.ai_config(key, value, note, updated_at, updated_by) values
  ('AGENT_ENABLED', 'on', 'wave 105: Ask Crux answers are written by the AI agent (tools over the dashboard calculations + read-only SQL). off = calculated answers only.', now(), 'wave 105'),
  ('AGENT_MODEL', 'gemini-2.5-flash', 'wave 105: model for the agent (function calling). Chosen by the probe action.', now(), 'wave 105'),
  ('AGENT_FALLBACK_MODEL', 'gemini-3.5-flash-lite', 'wave 105: used when the agent model is busy or out of free quota.', now(), 'wave 105'),
  ('AGENT_TIMEOUT_MS', '25000', 'wave 105: time limit per AI call in the agent loop.', now(), 'wave 105'),
  ('AGENT_MAX_ROUNDS', '5', 'wave 105: most AI calls per question (each round may run several tools).', now(), 'wave 105')
on conflict (key) do nothing;

do $m$
declare d text;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if position('pii_tokens' in d) > 0 then return; end if;
  d := replace(d, $a$elsif op = 'auth' then$a$,
$a$elsif op = 'pii_tokens' then return bi.ai_pii_tokens();   -- wave 105: Ask Crux agent
  elsif op = 'sql' then return ai.run_select(p->>'query', coalesce(nullif(p->>'max_rows', '')::int, 200));
  elsif op = 'agent_log' then return bi.ai_agent_log(p);
  elsif op = 'history' then
    return (select coalesce(jsonb_agg(jsonb_build_object('question', h.question, 'answer', left(coalesce(h.answer->>'answer', ''), 1500)) order by h.id), '[]'::jsonb)
              from (select m.id, m.question, m.answer from bi.ai_message m where m.conversation_id = nullif(p->>'conversation_id', '')::uuid
                     order by m.id desc limit least(coalesce(nullif(p->>'n', '')::int, 3), 6)) h);
  elsif op = 'auth' then$a$);
  if position($a$op = 'pii_tokens'$a$ in d) = 0 then raise exception 'gateway anchor not found'; end if;
  execute d;
end $m$;
