-- Applied to Supabase project via MCP on 20261119125355
-- wave 114a (19-Nov-2026): background import of uploads (see docs/migrations-manual/20261119_bi_114a_background_upload.sql for the full note).
-- Indexes built CONCURRENTLY before this migration: point_store_case_pin_idx, case_store_branch_id_idx; vacuum (analyze) bi.point_store.
create table if not exists bi.upload_hold (
  batch_id bigint not null references bi.import_batch(id) on delete cascade,
  seq integer not null, payload jsonb not null,
  primary key (batch_id, seq));
create table if not exists bi.upload_job (
  batch_id bigint primary key references bi.import_batch(id) on delete cascade,
  category text not null, file_name text, total integer not null default 0, done integer not null default 0,
  status text not null default 'sending' check (status in ('sending', 'queued', 'running', 'done', 'failed', 'cancelled')),
  result jsonb not null default '{}'::jsonb, error text, tries integer not null default 0, actor text,
  created_at timestamptz not null default now(), queued_at timestamptz, started_at timestamptz, finished_at timestamptz, heartbeat timestamptz);
create index if not exists upload_job_open on bi.upload_job (queued_at) where status in ('queued', 'running');
alter table bi.upload_hold enable row level security;
alter table bi.upload_job enable row level security;
revoke all on bi.upload_hold, bi.upload_job from public, anon, authenticated;

create or replace function bi.upload_action(p_actor text, p_action text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_id bigint := nullif(p->>'batch_id', '')::bigint; v_n int; j bi.upload_job; v_held int;
begin
  if p_action = 'check' then
    return jsonb_build_object('imported', (select coalesce(jsonb_agg(jsonb_build_object('hash', b.file_hash, 'batch_id', b.id, 'file_name', b.file_name, 'category', b.source_category,
               'committed_at', b.committed_at, 'rows_in', b.rows_in, 'snapshot_date', b.snapshot_date)), '[]'::jsonb)
      from bi.import_batch b where b.status = 'committed' and b.file_hash = any (array(select jsonb_array_elements_text(coalesce(p->'hashes', '[]'::jsonb))))));
  elsif p_action = 'hold' then
    if not exists (select 1 from bi.import_batch where id = v_id and status = 'staged') then raise exception 'batch % cannot take rows', v_id; end if;
    insert into bi.upload_job (batch_id, category, file_name, total, actor, heartbeat)
    select b.id, b.source_category, b.file_name, coalesce((p->>'total')::int, 0), p_actor, now() from bi.import_batch b where b.id = v_id
    on conflict (batch_id) do update set heartbeat = now(), total = greatest(bi.upload_job.total, excluded.total);
    if (select status from bi.upload_job where batch_id = v_id) <> 'sending' then raise exception 'batch % was already handed to the server', v_id; end if;
    insert into bi.upload_hold (batch_id, seq, payload)
    select v_id, (p->>'seq_start')::int + o - 1, e from jsonb_array_elements(p->'rows') with ordinality t(e, o)
    on conflict (batch_id, seq) do update set payload = excluded.payload;
    get diagnostics v_n = row_count;
    return jsonb_build_object('held', v_n);
  elsif p_action = 'queue' then
    select * into j from bi.upload_job where batch_id = v_id;
    if j.batch_id is null or j.status <> 'sending' then raise exception 'batch % is not being sent', v_id; end if;
    select count(*) into v_held from bi.upload_hold where batch_id = v_id and seq > 0;
    if v_held < j.total then raise exception 'only % of % rows arrived — send the file again', v_held, j.total; end if;
    update bi.upload_job set status = 'queued', queued_at = now(), heartbeat = now() where batch_id = v_id;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'import_queued', 'import_batch', v_id::text, jsonb_build_object('rows', j.total, 'category', j.category));
    return jsonb_build_object('queued', true, 'total', j.total,
      'ahead', (select count(*) from bi.upload_job x where x.status in ('queued', 'running') and x.batch_id <> v_id and x.queued_at <= now()));
  elsif p_action = 'jobs' then
    return jsonb_build_object('jobs', (select coalesce(jsonb_agg(jsonb_build_object('batch_id', x.batch_id, 'category', x.category, 'file_name', x.file_name, 'status', x.status,
               'total', x.total, 'done', x.done, 'result', x.result, 'error', x.error, 'created_at', x.created_at, 'queued_at', x.queued_at, 'started_at', x.started_at,
               'finished_at', x.finished_at, 'snapshot_date', b.snapshot_date, 'period_month', b.period_month, 'location_group', b.location_group,
               'ahead', case when x.status = 'queued' then (select count(*) from bi.upload_job y where y.status in ('queued', 'running') and y.queued_at < x.queued_at) end)
               order by x.created_at desc), '[]'::jsonb)
      from bi.upload_job x join bi.import_batch b on b.id = x.batch_id
     where (jsonb_typeof(p->'batch_ids') = 'array' and x.batch_id = any (array(select jsonb_array_elements_text(p->'batch_ids')::bigint)))
        or (jsonb_typeof(p->'batch_ids') is distinct from 'array' and (x.created_at > now() - interval '36 hours' or x.status in ('sending', 'queued', 'running')))),
      'worker_last_run', (select max(end_time) from cron.job_run_details d join cron.job c on c.jobid = d.jobid where c.jobname = 'bi-upload-worker'));
  elsif p_action = 'cancel' then
    update bi.upload_job set status = 'cancelled', error = 'cancelled by ' || p_actor, finished_at = now() where batch_id = v_id and status in ('sending', 'queued');
    get diagnostics v_n = row_count;
    if v_n = 1 then
      update bi.import_batch set status = 'rejected', notes = coalesce(notes, '') || ' cancelled before import' where id = v_id and status = 'staged';
      delete from bi.upload_hold where batch_id = v_id;
    end if;
    return jsonb_build_object('cancelled', v_n = 1);
  end if;
  raise exception 'unknown upload action %', p_action;
end $f$;
revoke all on function bi.upload_action(text, text, jsonb) from public, anon, authenticated;

create or replace procedure bi.upload_work(p_seconds integer default 50) language plpgsql as $f$
declare t_end timestamptz := clock_timestamp() + make_interval(secs => p_seconds); j bi.upload_job; r jsonb; v_n int; v_chunk int; v_err text; v_ok boolean;
begin
  if not pg_try_advisory_lock(hashtext('bi.upload_work')) then return; end if;
  update bi.upload_job set status = 'cancelled', error = 'the page was closed before the whole file was sent — send the file again', finished_at = now()
   where status = 'sending' and coalesce(heartbeat, created_at) < now() - interval '2 hours';
  update bi.import_batch b set status = 'rejected', notes = coalesce(b.notes, '') || ' upload interrupted: the page was closed before the upload finished'
   where b.status = 'staged' and b.created_at < now() - interval '3 hours'
     and b.source_category in ('zonal', 'case', 'point')
     and not exists (select 1 from bi.upload_job x where x.batch_id = b.id and x.status in ('sending', 'queued', 'running'));
  delete from bi.upload_hold h where not exists (select 1 from bi.upload_job x where x.batch_id = h.batch_id and x.status in ('sending', 'queued', 'running'));
  commit;
  loop
    exit when clock_timestamp() > t_end;
    select * into j from bi.upload_job where status in ('queued', 'running') order by queued_at, batch_id limit 1;
    exit when j.batch_id is null;
    if j.status = 'queued' then update bi.upload_job set status = 'running', started_at = now(), heartbeat = now() where batch_id = j.batch_id; end if;
    v_ok := true; v_err := null;
    begin
      if j.category = 'zonal' then
        insert into bi.stg_row (batch_id, seq, payload) select h.batch_id, h.seq, h.payload from bi.upload_hold h where h.batch_id = j.batch_id
        on conflict (batch_id, seq) do update set payload = excluded.payload;
        r := bi.commit_zonal(j.batch_id);
        insert into bi.audit_log (actor, action, entity, entity_key, detail) values (coalesce(j.actor, 'upload worker'), 'import_commit', 'import_batch', j.batch_id::text, r);
        update bi.upload_job set done = total, status = 'done', result = r, finished_at = now(), heartbeat = now() where batch_id = j.batch_id;
        delete from bi.upload_hold where batch_id = j.batch_id;
      else
        v_chunk := case j.category when 'case' then 300 else 1000 end;
        insert into bi.stg_row (batch_id, seq, payload)
        select h.batch_id, h.seq, h.payload from bi.upload_hold h where h.batch_id = j.batch_id and h.seq > j.done and h.seq <= j.done + v_chunk
        on conflict (batch_id, seq) do update set payload = excluded.payload;
        get diagnostics v_n = row_count;
        if v_n > 0 then
          r := case j.category when 'case' then bi.commit_case(j.batch_id) else bi.commit_point(j.batch_id) end;
          insert into bi.audit_log (actor, action, entity, entity_key, detail) values (coalesce(j.actor, 'upload worker'), 'import_commit', 'import_batch', j.batch_id::text, r);
          update bi.upload_job set done = least(done + v_chunk, total), heartbeat = now(), tries = 0,
                 result = jsonb_build_object('new', coalesce((result->>'new')::int, 0) + coalesce((r->>'new')::int, 0),
                                             'changed', coalesce((result->>'changed')::int, 0) + coalesce((r->>'changed')::int, 0),
                                             'unchanged', coalesce((result->>'unchanged')::int, 0) + coalesce((r->>'unchanged')::int, 0))
           where batch_id = j.batch_id;
        end if;
        if v_n = 0 or j.done + v_chunk >= j.total then
          update bi.import_batch set status = 'committed', committed_at = now() where id = j.batch_id and status = 'staged';
          insert into bi.audit_log (actor, action, entity, entity_key) values (coalesce(j.actor, 'upload worker'), 'import_finalize', 'import_batch', j.batch_id::text);
          update bi.upload_job set status = 'done', done = total, finished_at = now(), heartbeat = now() where batch_id = j.batch_id;
          delete from bi.upload_hold where batch_id = j.batch_id;
        end if;
      end if;
    exception when others then v_ok := false; v_err := sqlerrm;
    end;
    if not v_ok then
      update bi.upload_job set tries = tries + 1, heartbeat = now(), error = v_err,
             status = case when tries + 1 >= 3 then 'failed' else status end, finished_at = case when tries + 1 >= 3 then now() end
       where batch_id = j.batch_id;
      update bi.import_batch b set status = 'rejected', notes = coalesce(b.notes, '') || ' import failed on the server: ' || left(v_err, 200)
       where b.id = j.batch_id and b.status = 'staged' and (select x.status from bi.upload_job x where x.batch_id = j.batch_id) = 'failed';
    end if;
    commit;
  end loop;
  perform pg_advisory_unlock(hashtext('bi.upload_work'));
end $f$;
revoke all on procedure bi.upload_work(integer) from public, anon, authenticated;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '114a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.ingest_as(text,text,jsonb)'::regprocedure, array[
  $r$  elsif p_action = 'reject' then$r$,
  $r$  elsif p_action in ('check', 'hold', 'queue', 'jobs', 'cancel') then   -- wave 114a: background import
    return bi.upload_action(v_actor, p_action, p_payload);
  elsif p_action = 'reject' then$r$], array[1]);

select cron.schedule('bi-upload-worker', '* * * * *', $c$call bi.upload_work(52)$c$);
