-- Applied to Supabase project via MCP on 20261119132251
-- wave 115b (19-Nov-2026): the job list also gives the time of the last piece received, so a page only revives a send nobody is still sending
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '115b');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.upload_action(text,text,jsonb)'::regprocedure, array[
  $r$'file_hash', b.file_hash, 'source', x.source, 'revivals', x.revivals, 'next_try_at', x.next_try_at,$r$,
  $r$'file_hash', b.file_hash, 'source', x.source, 'revivals', x.revivals, 'next_try_at', x.next_try_at, 'heartbeat', x.heartbeat,$r$], array[1]);
