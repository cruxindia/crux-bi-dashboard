-- Applied to Supabase project via MCP on 20261029153358
-- One definition of the response-cache version, used by every reader and writer of bi.api_cache
-- (bi_call, both revalidators, warm_drill_cache, api_coverage_status). Prevents writers storing a version readers never match.
create or replace function bi.cache_version() returns bigint
language sql stable security definer set search_path = bi, public as $$
  select (select coalesce(max(id), 0) from bi.audit_log
           where action not in ('import_begin', 'import_reject', 'ai_config_change', 'kb_put')
             and action not like 'ai\_%' and action not like 'kb\_%' and action not like 'job\_%') * 100000
       + coalesce((select (extract(epoch from max(refreshed_at))::bigint % 100000) from bi.refresh_state), 0)
$$;
comment on function bi.cache_version() is 'Response-cache version (wave 098): data-changing audit rows + derived-table refreshes. Non-data audit actions (import begin/reject, AI, knowledge base, jobs) do not invalidate cached answers.';

do $do$
declare r record; src text; n int;
  pat constant text := '(v_ver(?: bigint)? := )\(select coalesce\(max\(id\),\s?0\) from bi\.audit_log[^;]*?from bi\.refresh_state\), 0\)';
begin
  for r in select p.oid, n2.nspname || '.' || p.proname nm from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
            where (n2.nspname, p.proname) in (('public','bi_call'), ('bi','api_revalidate'), ('bi','api_revalidate_light'), ('bi','warm_drill_cache'), ('bi','api_coverage_status')) loop
    src := pg_get_functiondef(r.oid);
    if position('bi.cache_version()' in src) > 0 then continue; end if;
    n := (select count(*) from regexp_matches(src, pat, 'g'));
    if n <> 1 then raise exception '% : version expression found % times', r.nm, n; end if;
    execute regexp_replace(src, pat, '\1bi.cache_version()');
  end loop;
end $do$;

select p.proname, position('bi.cache_version()' in p.prosrc) > 0 uses_fn from pg_proc p
 where p.proname in ('bi_call','api_revalidate','api_revalidate_light','warm_drill_cache','api_coverage_status');
