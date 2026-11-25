-- Applied to Supabase project via MCP on 20261121075235
-- wave 119c: the finance rebuild takes ~30 s, longer than a dashboard request may run (20 s), so a page-side rebuild after an upload never finished and
-- figures waited for the 10-minute job. The job now checks every 2 minutes (it rebuilds only when an upload, mapping or setting changed — the check is cheap)
-- and the page waits for it; api_fin_sources reports the last rebuild.
select cron.alter_job((select jobid from cron.job where jobname = 'bi-fin-derive'), schedule := '*/2 * * * *');
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '119c');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.api_fin_sources(jsonb)'::regprocedure, array[
  $r$    'uploads', (select jsonb_agg($r$,
  $r$    'last_rebuild', (select jsonb_build_object('run', r.id, 'finished_at', r.finished_at, 'ms', r.summary->'ms') from bi.fin_run r where r.finished_at is not null order by r.id desc limit 1),
    'rebuild_pending', (select max(committed_at) from bi.fin_upload) > coalesce((select max(finished_at) from bi.fin_run), '-infinity'),
    'uploads', (select jsonb_agg($r$], array[1]);
