-- Applied to Supabase project via MCP on 20261029130835
-- Wave 098: daytime refresh of the light landing figures (meta, overview, daily, insights, business count, tracker sheet, zonal, like-for-like, compare)
-- so an upload shows on the dashboard within ~10 minutes. Heavy figures (drill-downs, collections reconciliation, growth, coverage) stay on the
-- 00:30–05:30 IST night window (bi.api_revalidate). Shares the night job's advisory lock, so the two never run together.
create or replace procedure bi.api_revalidate_light(p_budget_s integer default 20)
language plpgsql
as $procedure$
declare q record; t0 timestamptz := clock_timestamp(); t1 timestamptz; v_ver bigint; r jsonb;
begin
  if not pg_try_advisory_lock(hashtext('bi.api_revalidate')) then return; end if;
  for q in select k, fn, args from bi.api_cache_queue
            where done_at is null
              and fn = any (array['meta','overview','daily','insights','business_count','tracker_sheet','zonal','lfl','compare'])
              and coalesce(last_ms, 0) < 15000
            order by requested_at desc limit 40 loop
    exit when clock_timestamp() - t0 > make_interval(secs => p_budget_s);
    v_ver := (select coalesce(max(id), 0) from bi.audit_log) * 100000 + coalesce((select (extract(epoch from max(refreshed_at))::bigint % 100000) from bi.refresh_state), 0);
    t1 := clock_timestamp();
    begin
      r := bi.call_compute(q.fn, q.args);
      if r is not null then
        insert into bi.api_cache(k, v, version, fn, args) values (q.k, r, v_ver, q.fn, q.args)
        on conflict (k) do update set v = excluded.v, version = excluded.version, fn = excluded.fn, args = excluded.args, computed_at = now();
      end if;
      update bi.api_cache_queue set done_at = now(), last_ms = (extract(epoch from clock_timestamp() - t1) * 1000)::int, last_error = null where k = q.k;
    exception when others then
      -- leave the item queued for the night run; record the time so a slow item is skipped by this light job next time
      update bi.api_cache_queue set last_ms = greatest(coalesce(last_ms, 0), 15000), last_error = left('light: ' || sqlerrm, 300) where k = q.k;
    end;
    commit;
  end loop;
  perform pg_advisory_unlock(hashtext('bi.api_revalidate'));
end $procedure$;

comment on procedure bi.api_revalidate_light(integer) is 'Wave 098: daytime refresh of light landing figures only (allow-list, 20 s budget); heavy figures refresh at night via bi.api_revalidate.';
