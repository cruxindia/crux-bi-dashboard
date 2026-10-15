-- Applied to Supabase project via MCP on 20261015003319
create or replace function bi.warm_drill_cache(p_budget_seconds int default 240)
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare v_ver bigint := (select coalesce(max(id),0) from bi.audit_log) * 100000 + coalesce((select (extract(epoch from max(refreshed_at))::bigint % 100000) from bi.refresh_state), 0);
        m text := to_char((select max(report_month) from bi.zt_snapshot), 'YYYY-MM-DD'); t0 timestamptz := clock_timestamp(); n int := 0; c record; p text; ok boolean := true;
begin
  if exists (select 1 from bi.cache_warm w where w.id = 1 and w.version = v_ver and w.finished_at is not null) then
    return jsonb_build_object('status', 'already_warm', 'version', v_ver); end if;
  insert into bi.cache_warm as w (id, version, started_at, finished_at, calls, seconds) values (1, v_ver, now(), null, 0, 0)
  on conflict (id) do update set version = excluded.version, started_at = excluded.started_at, finished_at = null, calls = 0, seconds = 0, note = null;
  perform public.bi_call('tat_summary', jsonb_build_object('month', m, 'filters', '{}'::jsonb, 'group', 'total')); n := n + 1;
  for c in select '{}'::jsonb f, 'zone' lvl, 0 o
           union all select jsonb_build_object('zone_group', z.code), 'location', 1 from bi.zone_group z where exists (select 1 from bi.location l where l.zone_group = z.code)
           order by o, f::text loop
    if clock_timestamp() - t0 > make_interval(secs => p_budget_seconds) then ok := false; exit; end if;
    perform public.bi_call('drill', jsonb_build_object('month', m, 'filters', c.f, 'level', c.lvl, 'p', '{}'::jsonb)); n := n + 1;
    foreach p in array array['tat', 'force1', 'coverage', 'lifecycle', 'revenue', 'penalty'] loop
      perform public.bi_call('drill_ops', jsonb_build_object('month', m, 'filters', c.f, 'level', c.lvl, 'part', p)); n := n + 1;
    end loop;
    perform public.bi_call('insights', jsonb_build_object('month', m, 'filters', c.f)); perform public.bi_call('daily', jsonb_build_object('month', m, 'filters', c.f)); n := n + 2;
  end loop;
  insert into bi.cache_warm as w (id, version, started_at, finished_at, calls, seconds, note)
  values (1, v_ver, t0, case when ok then now() end, n, round(extract(epoch from clock_timestamp() - t0)::numeric, 1), case when ok then null else 'time budget reached; continues next run' end)
  on conflict (id) do update set finished_at = excluded.finished_at, calls = excluded.calls, seconds = excluded.seconds, note = excluded.note;
  return jsonb_build_object('status', case when ok then 'warmed' else 'partial' end, 'version', v_ver, 'calls', n, 'seconds', round(extract(epoch from clock_timestamp() - t0)::numeric, 1));
end $function$;
