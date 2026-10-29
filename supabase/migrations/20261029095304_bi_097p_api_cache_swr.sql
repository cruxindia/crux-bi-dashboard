-- Applied to Supabase project via MCP on 20261029095304
-- bi_097p (29-Oct-2026, incident): the dashboard stopped loading ("upstream request timeout"). Every data change (here ~90 mapping saves at
-- 14:02 IST) invalidates every cached figure; each page then recomputed its figures on the spot, many requests at once, on a small database
-- whose refresh jobs were also running — the first call (meta) no longer finished within the time limit.
-- Fix (stale-while-revalidate): when the cached answer for a request is from an older data version, bi_call returns it at once and queues the
-- request; a background job recomputes queued requests one at a time and stores them under the current version. Only a request never seen
-- before is computed on the spot. Every answer still carries its own as-of dates. Nothing is removed.
alter table bi.api_cache add column if not exists fn text, add column if not exists args jsonb;
create table if not exists bi.api_cache_queue (k text primary key, fn text not null, args jsonb not null, requested_at timestamptz not null default now(),
  done_at timestamptz, last_ms int, last_error text);
alter table bi.api_cache_queue enable row level security;

do $do$
declare d text := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
        cs int := position('r := case p_fn' in d); ce int := position('else null end;' in d); body text;
        o1 text := $o$  select v into r from bi.api_cache where k = v_key and version = v_ver;
  if r is null then
    r := case p_fn$o$;
        o2 text := $o$      else null end;
    if r is not null then
      begin perform set_config('lock_timeout', '1500ms', true); insert into bi.api_cache(k, v, version) values (v_key, r, v_ver)
      on conflict (k) do update set v = excluded.v, version = excluded.version, computed_at = now(); exception when lock_not_available then null; end; perform set_config('lock_timeout', '0', true);
    end if;
  end if;$o$;
begin
  if cs = 0 or ce = 0 or ce < cs then raise exception 'bi_call compute block not found'; end if;
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'bi_call fragment 1'; end if;
  if (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'bi_call fragment 2'; end if;
  body := substring(d from cs + 5 for ce + length('else null end') - (cs + 5));   -- "case p_fn … else null end"
  execute 'create or replace function bi.call_compute(p_fn text, p_args jsonb) returns jsonb language plpgsql security definer set search_path to ''bi'', ''public'' as $cc$
declare m date := nullif(p_args->>''month'','''')::date; f jsonb := coalesce(p_args->''filters'',''{}''); r jsonb;
begin
  r := ' || body || ';
  return r;
end $cc$';
  -- bi_call: serve the last answer while it is recomputed in the background
  d := substring(d from 1 for position(o1 in d) - 1)
       || $n$  select v, version into r, c_ver from bi.api_cache where k = v_key;
  if r is not null and c_ver is distinct from v_ver then
    -- an older data version: answer now with the last good result, recompute in the background (bi.api_revalidate)
    begin perform set_config('lock_timeout', '1500ms', true);
      insert into bi.api_cache_queue(k, fn, args) values (v_key, p_fn, p_args - 'admin_key')
      on conflict (k) do update set requested_at = now(), done_at = null, last_error = null, fn = excluded.fn, args = excluded.args
       where bi.api_cache_queue.done_at is not null or bi.api_cache_queue.requested_at < now() - interval '30 minutes';
    exception when lock_not_available then null; end; perform set_config('lock_timeout', '0', true);
  elsif r is null then
    r := bi.call_compute(p_fn, p_args);
    if r is not null then
      begin perform set_config('lock_timeout', '1500ms', true); insert into bi.api_cache(k, v, version, fn, args) values (v_key, r, v_ver, p_fn, p_args - 'admin_key')
      on conflict (k) do update set v = excluded.v, version = excluded.version, fn = excluded.fn, args = excluded.args, computed_at = now(); exception when lock_not_available then null; end; perform set_config('lock_timeout', '0', true);
    end if;
  end if;$n$
       || substring(d from position(o2 in d) + length(o2));
  if (length(d) - length(replace(d, $o$        r jsonb;$o$, ''))) / length($o$        r jsonb;$o$) <> 1 then raise exception 'bi_call declare fragment'; end if;
  d := replace(d, $o$        r jsonb;$o$, $n$        r jsonb; c_ver bigint;$n$);
  execute d;
end $do$;

-- background recompute: newest requests first, one at a time, committed one by one; stops after the time budget
-- (no SECURITY DEFINER / SET clause: a procedure with either cannot commit; it runs as the owner from pg_cron)
create or replace procedure bi.api_revalidate(p_budget_s int default 100)
 language plpgsql as $p$
declare q record; t0 timestamptz := clock_timestamp(); t1 timestamptz; v_ver bigint; r jsonb;
begin
  if not pg_try_advisory_lock(hashtext('bi.api_revalidate')) then return; end if;
  for q in select k, fn, args from bi.api_cache_queue where done_at is null order by requested_at desc limit 200 loop
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
      update bi.api_cache_queue set done_at = now(), last_ms = (extract(epoch from clock_timestamp() - t1) * 1000)::int, last_error = left(sqlerrm, 300) where k = q.k;
    end;
    commit;
  end loop;
  perform pg_advisory_unlock(hashtext('bi.api_revalidate'));
end $p$;

select cron.schedule('bi-api-revalidate', '* * * * *', $c$call bi.api_revalidate(100)$c$);
