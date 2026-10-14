-- Applied to Supabase project via MCP on 20261014120222
-- Point-level facts are rebuilt only when something that affects them changes (imports, mappings), not on daily-table saves,
-- rate changes, penalties or cache refreshes — the rebuild briefly locks Force1/People figures.
create or replace function bi.point_source_version() returns bigint language sql stable security definer set search_path to 'bi','public' as $fn$
  select coalesce(max(id), 0) from bi.audit_log
  where action not in ('matrix_save','matrix_commit','matrix_correction','matrix_discard','matrix_reopen','matrix_no_report','cache_bump',
                       'rate_change','rate_change_end','penalty_add','penalty_void','master_import','client_hierarchy')
$fn$;

do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.refresh_if_stale'::regproc);
  if position('point_source_version' in d) = 0 then
    d := replace(d, 'declare v bigint := (select coalesce(max(id),0) from bi.audit_log);', 'declare v bigint := bi.point_source_version();');
    if position('point_source_version' in d) = 0 then raise exception 'refresh_if_stale patch failed'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('bi.refresh_point_derived'::regproc);
  if position('point_source_version' in d) = 0 then
    d := replace(d, 'v bigint := (select coalesce(max(id),0) from bi.audit_log);', 'v bigint := bi.point_source_version();');
    if position('point_source_version' in d) = 0 then raise exception 'refresh_point_derived patch failed'; end if;
    execute d;
  end if;
end $do$;
