-- Applied to Supabase project via MCP on 20261120122016
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '118b');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.target_source(date)'::regprocedure, array[
  $r$st as (select s.* from bi.target_fill_set s, m where s.month = m.m order by s.id desc limit 1)$r$,
  $r$st as (select s.* from bi.target_fill_set s, m where s.month = m.m and s.kind = 'planned' order by s.id desc limit 1)$r$], array[1]);
