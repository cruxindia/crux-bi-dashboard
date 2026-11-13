-- Applied to Supabase project via MCP on 20261113155631
-- wave 109d (13-Nov-2026): reports of the new team agents, the admin view of the teams, and their schedules (UTC; IST = UTC + 5:30)
alter table bi.agent_report drop constraint if exists agent_report_kind_check;
alter table bi.agent_report add constraint agent_report_kind_check check (kind = any (array['daily_brief', 'market_news', 'chat_review', 'weekly_review',
  'target_watch', 'zone_west', 'zone_north_east', 'zone_south', 'client_review', 'month_close', 'data_watch', 'branch_network', 'ops_watch', 'collections_watch', 'decision_audit']));

-- admin: the teams (no keys), switch an agent on or off
create or replace function bi.agent_team_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare r jsonb;
begin
  if coalesce(p->>'op', 'list') = 'list' then return bi.api_agent_team(); end if;
  if p->>'op' = 'enable' then
    update bi.ai_agent set enabled = coalesce((p->>'enabled')::boolean, true), updated_at = now() where agent_id = p->>'agent_id'
      returning jsonb_build_object('agent_id', agent_id, 'enabled', enabled) into r;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'ai_agent_enable', 'ai_agent', p->>'agent_id', r);
    return coalesce(r, '{}'::jsonb);
  end if;
  raise exception 'op must be list or enable';
end $f$;

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
select pg_temp.patch('public.bi_admin(text,jsonb)'::regprocedure, array[
  E'    when ''operating_model'' then return bi.operating_model_admin(',
  E'    when ''agent_team'' then return bi.agent_team_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');   -- wave 109d\n    when ''operating_model'' then return bi.operating_model_admin('], array[1]);

-- schedules: after the night refresh, before the working day; each job runs on its own agent key
select cron.schedule('bi-agent-data-watch', '15 0 * * *', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"data_watch"}'::jsonb)$c$);
select cron.schedule('bi-agent-target-watch', '20 1 * * *', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"target_watch"}'::jsonb)$c$);
select cron.schedule('bi-agent-zone-west', '30 1 * * 1-6', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"zone_west"}'::jsonb)$c$);
select cron.schedule('bi-agent-zone-north-east', '40 1 * * 1-6', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"zone_north_east"}'::jsonb)$c$);
select cron.schedule('bi-agent-zone-south', '50 1 * * 1-6', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"zone_south"}'::jsonb)$c$);
select cron.schedule('bi-agent-ops-watch', '0 2 * * 1-6', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"ops_watch"}'::jsonb)$c$);
select cron.schedule('bi-agent-client-review', '10 2 * * 2', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"client_review"}'::jsonb)$c$);
select cron.schedule('bi-agent-branch-network', '10 2 * * 3', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"branch_network"}'::jsonb)$c$);
select cron.schedule('bi-agent-collections-watch', '10 2 * * 4', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"collections_watch"}'::jsonb)$c$);
select cron.schedule('bi-agent-decision-audit', '30 2 * * *', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"decision_audit"}'::jsonb)$c$);
select cron.schedule('bi-agent-month-close', '0 3 3 * *', $c$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"month_close"}'::jsonb)$c$);
select cron.schedule('bi-agent-key-check', '5 0 * * 1', $c$select bi.call_edge('ask-crux', '{"action":"key_check"}'::jsonb)$c$);
