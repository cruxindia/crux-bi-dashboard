-- Applied to Supabase project via MCP on 20261029051019
-- bi_097f (29-Oct-2026)
-- (1) Branch coverage status: last monitor run (succeeded / skipped / failed, source version, time), possible duplicate IFSC entries, branch activity
--     classes (growing, stable, losing traction, dormant, reactivated, new) and Force1 branch codes that are not in the branch master (unmatched).
-- (2) Identity register: an administrator can start a run (it runs in the background within a minute); a weekly run on Sunday 02:20 IST.
create or replace function bi.api_coverage_status() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with lr as (select * from bi.job_run where job = 'branch_monitor' order by started_at desc limit 1),
       ls as (select * from bi.job_run where job = 'branch_monitor' and status = 'succeeded' order by started_at desc limit 1),
       fams as (select distinct client_family fam from bi.client_branch_master where source_type = 'rbi_ifsc_directory'),
       cs as (select k.family fam, ltrim(regexp_replace(upper(c.branch_code), '[^A-Z0-9]', '', 'g'), '0') code, count(*) n
                from bi.case_store c join bi.client k on k.code = c.client_code
               where c.received_at >= now() - interval '6 months' and c.branch_code is not null and k.family in (select fam from fams) group by 1, 2),
       um as (select cs.* from cs where not exists (select 1 from bi.client_branch_master m where m.client_family = cs.fam and m.code_norm = cs.code))
  select jsonb_build_object(
    'monitor_last_run', (select jsonb_build_object('status', status, 'trigger', trigger, 'at', started_at, 'source_version', source_version, 'summary', summary) from lr),
    'monitor_last_success', (select jsonb_build_object('at', started_at, 'source_version', source_version, 'summary', summary) from ls),
    'possible_duplicate_entries', (select sum((v->>'duplicate_candidates')::int) from ls, jsonb_each(ls.stats) e(k, v)),
    'force1_branch_codes_6m', (select count(*) from cs), 'force1_cases_6m', (select sum(n) from cs),
    'unmatched_force1_codes', (select count(*) from um), 'unmatched_force1_cases', (select coalesce(sum(n), 0) from um),
    'unmatched_by_client', (select coalesce(jsonb_agg(jsonb_build_object('client', fam, 'codes', c, 'cases', n) order by n desc), '[]') from (select fam, count(*) c, sum(n) n from um group by 1) z),
    'note', 'A skipped monitor run means the source file has not changed since the last successful comparison — not that the external source was re-checked for freshness. IFSC entries are directory entries: one physical branch can appear under more than one IFSC (possible duplicates are queued for review), and some entries are processing centres. Unmatched = Force1 branch codes of the last 6 months not found in the branch master for that client; they are never counted as "never activated".') $f$;

do $do$
declare d text; o text := $o$  if p_fn = 'identity' then return bi.api_identity(); end if;$o$;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_call fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$  if p_fn = 'coverage_status' then return bi.api_coverage_status(); end if;$n$);
  d := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
  o := $o$    when 'identity_exceptions' then return bi.identity_exceptions(p - 'admin_key');$o$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_admin fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$    when 'identity_run' then
      if exists (select 1 from cron.job where jobname = 'bi-identity-run-once') or exists (select 1 from bi.identity_run where status = 'running' and started_at > now() - interval '15 minutes') then
        return jsonb_build_object('ok', true, 'note', 'A run is already queued or running.'); end if;
      perform cron.schedule('bi-identity-run-once', '* * * * *', $c$set statement_timeout = '10min'; do $j$ begin perform cron.unschedule('bi-identity-run-once'); perform bi.identity_audit_run(300); end $j$;$c$);
      return jsonb_build_object('ok', true, 'note', 'The identity register will be rebuilt within about two minutes.');$n$);
end $do$;

select cron.schedule('bi-identity-weekly', '50 20 * * 6', $c$set statement_timeout = '10min'; select bi.identity_audit_run(300);$c$);
