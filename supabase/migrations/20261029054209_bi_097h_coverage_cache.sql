-- Applied to Supabase project via MCP on 20261029054209
-- bi_097h (29-Oct-2026): the coverage status strip took 11–40 s per page load (6-month Case Wise scan + full scan of the branch master).
-- The heavy part (Force1 codes vs the branch master, possible duplicates) is now cached with the same data version as bi_call; the monitor
-- status (last run / last success) stays live on every call. The client-family list uses an index probe instead of a full scan.
create or replace function bi.api_coverage_codes() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with ls as (select * from bi.job_run where job = 'branch_monitor' and status = 'succeeded' order by started_at desc limit 1),
       fams as (select k.family fam from (select distinct family from bi.client where family is not null) k(family)
                 where exists (select 1 from bi.client_branch_master m where m.client_family = k.family and m.source_type = 'rbi_ifsc_directory')),
       cs as (select k.family fam, ltrim(regexp_replace(upper(c.branch_code), '[^A-Z0-9]', '', 'g'), '0') code, count(*) n
                from bi.case_store c join bi.client k on k.code = c.client_code
               where c.received_at >= now() - interval '6 months' and c.branch_code is not null and k.family in (select fam from fams) group by 1, 2),
       um as (select cs.* from cs where not exists (select 1 from bi.client_branch_master m where m.client_family = cs.fam and m.code_norm = cs.code))
  select jsonb_build_object(
    'possible_duplicate_entries', (select sum((v->>'duplicate_candidates')::int) from ls, jsonb_each(ls.stats) e(k, v)),
    'force1_branch_codes_6m', (select count(*) from cs), 'force1_cases_6m', (select sum(n) from cs),
    'unmatched_force1_codes', (select count(*) from um), 'unmatched_force1_cases', (select coalesce(sum(n), 0) from um),
    'unmatched_by_client', (select coalesce(jsonb_agg(jsonb_build_object('client', fam, 'codes', c, 'cases', n) order by n desc), '[]') from (select fam, count(*) c, sum(n) n from um group by 1) z),
    'codes_computed_at', now()) $f$;

create or replace function bi.api_coverage_status() returns jsonb language plpgsql volatile security definer set search_path to 'bi', 'public' as $f$
declare v_ver bigint := (select coalesce(max(id), 0) from bi.audit_log) * 100000 + coalesce((select (extract(epoch from max(refreshed_at))::bigint % 100000) from bi.refresh_state), 0);
        v_key text := md5('coverage_codes|v1'); r jsonb;
begin
  select v into r from bi.api_cache where k = v_key and version = v_ver;
  if r is null then
    r := bi.api_coverage_codes();
    begin perform set_config('lock_timeout', '1500ms', true);
      insert into bi.api_cache(k, v, version) values (v_key, r, v_ver) on conflict (k) do update set v = excluded.v, version = excluded.version, computed_at = now();
    exception when lock_not_available then null; end;
    perform set_config('lock_timeout', '0', true);
  end if;
  return r || jsonb_build_object(
    'monitor_last_run', (select jsonb_build_object('status', status, 'trigger', trigger, 'at', started_at, 'source_version', source_version, 'summary', summary)
                           from bi.job_run where job = 'branch_monitor' order by started_at desc limit 1),
    'monitor_last_success', (select jsonb_build_object('at', started_at, 'source_version', source_version, 'summary', summary)
                               from bi.job_run where job = 'branch_monitor' and status = 'succeeded' order by started_at desc limit 1),
    'note', 'A skipped monitor run means the source file has not changed since the last successful comparison — not that the external source was re-checked for freshness. IFSC entries are directory entries: one physical branch can appear under more than one IFSC (possible duplicates are queued for review), and some entries are processing centres. Unmatched = Force1 branch codes of the last 6 months not found in the branch master for that client; they are never counted as "never activated".');
end $f$;
