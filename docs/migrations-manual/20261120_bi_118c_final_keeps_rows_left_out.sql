-- wave 118c (20-Nov-2026): finalized targets — a team × client left out of the file keeps the target it has now, also on the month's later tracker files.
-- Without this, a file covering only some rows fixed those rows, and a later tracker file without targets (or the nightly carry of the owner's targets)
-- would no longer fill the rows left out, because finalized targets take over the month's tracker uploads. The saved set now also holds every
-- team × client that has a target on the month's latest report date and is not in the file (note "kept as it was (not in the file)"); for a month
-- without a tracker file yet, the rows of the finalized set it replaces. Counted replacements; old body in bi.fn_backup (wave 118c).
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '118c');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.target_final_save(text,date,jsonb,text,text)'::regprocedure, array[
  $r$v_prev bi.target_fill_set; v_id bigint; v_bad int; r jsonb; v_tot jsonb;$r$,
  $r$v_prev bi.target_fill_set; v_id bigint; v_bad int; r jsonb; v_tot jsonb; v_lastm date; v_kept int := 0;$r$,
  $r$  r := bi.target_final_apply(v_id, null, p_actor);$r$,
  $r$  -- wave 118c: a team × client left out keeps the target it has now (latest report date of the month; no file yet → the finalized set it replaces)
  v_lastm := (select max(snapshot_date) from bi.zt_snapshot where report_month = v_m);
  if v_lastm is not null then
    insert into bi.target_fill_row (set_id, location_id, client_code, target_cases, revenue_target, rate, note)
    select v_id, z.location_id, z.client_code, sum(coalesce(z.target_cases, 0)), sum(coalesce(z.revenue_target, 0)), max(z.rate), 'kept as it was (not in the file)'
      from bi.zt_row z where z.snapshot_date = v_lastm and z.row_type = 'leaf' and z.location_id is not null and z.client_code is not null
       and not exists (select 1 from _fr f where f.location_id = z.location_id and f.client_code = z.client_code)
     group by z.location_id, z.client_code having sum(coalesce(z.target_cases, 0)) <> 0 or sum(coalesce(z.revenue_target, 0)) <> 0;
    get diagnostics v_kept = row_count;
  elsif v_prev.kind = 'final' then
    insert into bi.target_fill_row (set_id, location_id, client_code, target_cases, revenue_target, rate, note)
    select v_id, r0.location_id, r0.client_code, r0.target_cases, r0.revenue_target, r0.rate, coalesce(r0.note, 'kept from your earlier finalized targets')
      from bi.target_fill_row r0 where r0.set_id = v_prev.id
       and not exists (select 1 from _fr f where f.location_id = r0.location_id and f.client_code = r0.client_code);
    get diagnostics v_kept = row_count;
  end if;
  r := bi.target_final_apply(v_id, null, p_actor);$r$,
  $r$'replaced', case when v_prev.id is not null$r$,
  $r$'kept', v_kept, 'replaced', case when v_prev.id is not null$r$], array[1, 1, 1]);
