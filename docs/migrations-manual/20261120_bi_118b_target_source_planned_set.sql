-- wave 118b (20-Nov-2026): target_source(month).set stays the month's latest PLANNED set (as before wave 118a) — finalized sets are reported in .final,
-- and the "your targets came from <date>" fallback keeps reading the planned set that the tracker's targets replaced (found in the rollback test: after a
-- finalized set was saved and withdrawn, .set pointed at the withdrawn finalized set and owner_targets_from went blank). Counted replacement; old body in
-- bi.fn_backup (wave 118b).
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
