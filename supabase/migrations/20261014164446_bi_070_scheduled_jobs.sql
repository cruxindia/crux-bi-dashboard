-- Applied to Supabase project via MCP on 20261014164446
create extension if not exists pg_net with schema extensions;

-- job token for scheduled calls: generated inside the database, plaintext kept only in Vault, hash in bi.ingest_token (scope job)
do $$
declare t text;
begin
  if not exists (select 1 from vault.secrets where name = 'bi_job_token') then
    t := encode(extensions.gen_random_bytes(32), 'hex');
    perform vault.create_secret(t, 'bi_job_token', 'Crux BI scheduled jobs: pg_cron -> Edge Functions (branch monitor, AI maintenance)');
    insert into bi.ingest_token(token_hash, label, expires_at, revoked, scope)
    values (encode(extensions.digest(t, 'sha256'), 'hex'), 'Scheduled jobs (pg_cron -> Edge Functions)', now() + interval '5 years', false, 'job');
  end if;
end $$;

create or replace function bi.call_edge(p_fn text, p_body jsonb)
returns bigint language plpgsql security definer set search_path = bi, public, extensions as $$
declare tok text; id bigint;
  anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN6ZGpiYmh4Ym93ZWF3cWJqeXdyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ5NjkyNDgsImV4cCI6MjEwMDU0NTI0OH0.NSiSksxZiMVrVG6h4Wt2ZPhS4P4mbgv3XaAlGSqYIzM';
begin
  if p_fn not in ('branch-monitor', 'ask-crux') then raise exception 'function not allowed'; end if;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'bi_job_token';
  select net.http_post(url := 'https://czdjbbhxboweawqbjywr.supabase.co/functions/v1/' || p_fn,
                       body := coalesce(p_body, '{}'::jsonb) || jsonb_build_object('token', tok),
                       headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || anon, 'apikey', anon),
                       timeout_milliseconds := 150000) into id;
  insert into bi.job_run(job, trigger, status, finished_at, summary) values ('scheduler', 'cron', 'succeeded', now(), 'Dispatched ' || p_fn || ' ' || coalesce(p_body->>'action', p_body->>'trigger', '') || ' (request ' || id || ')');
  return id;
end $$;

select cron.schedule('bi-branch-monitor', '*/10 1-3 2 * *', $c$select bi.call_edge('branch-monitor', '{"trigger":"cron"}'::jsonb)$c$);
select cron.schedule('bi-ai-validate', '50 3 2 * *', $c$select bi.call_edge('ask-crux', '{"action":"validate"}'::jsonb)$c$);
select cron.schedule('bi-ai-embed-sync', '20 2 * * *', $c$select bi.call_edge('ask-crux', '{"action":"embed_sync","max":100}'::jsonb)$c$);
select cron.schedule('bi-branch-activity', '7,37 * * * *', $c$set statement_timeout = '120s'; select bi.branch_activity_refresh_if_stale()$c$);
