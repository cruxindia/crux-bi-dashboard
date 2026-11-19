-- wave 116a (19-Nov-2026, owner 19:35 IST: "Only 24 out of 32 got uploaded and 1 is cancelled why? … Rectify and finish the pending uploads").
-- Cause: the page sent files one at a time; files still waiting for their turn existed only in that page, so when the page was reloaded at 19:31
-- seven Case Wise files were never sent and nothing could pick them up again. From now on every ticked file is registered on the server when
-- Import is pressed (an empty upload with where the file came from), so a page opened later — on any device — sends the ones whose turn never came.
--   * 'retry' also resumes a registered upload that has no rows yet (it used to need at least one piece held);
--   * new action 'touch': the sending page keeps its waiting files marked as alive, so another open page does not take them over.
-- Function bodies only (no table change); applied with counted replacements, old bodies kept in bi.fn_backup.
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '116a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.upload_action(text,text,jsonb)'::regprocedure, array[
  $r$elsif j.status in ('sending', 'cancelled') and v_held > 0 and coalesce(j.error, '') not like 'cancelled by%' then$r$,
  $r$elsif j.status in ('sending', 'cancelled') and (v_held > 0 or j.source is not null) and coalesce(j.error, '') not like 'cancelled by%' then   -- wave 116a: also a registered file whose turn never came$r$,
  $r$  elsif p_action = 'cancel' then$r$,
  $r$  elsif p_action = 'touch' then   -- wave 116a: the sending page keeps the files waiting for their turn marked as alive
    update bi.upload_job set heartbeat = now()
     where status = 'sending' and batch_id = any (array(select jsonb_array_elements_text(coalesce(p->'batch_ids', '[]'::jsonb))::bigint));
    get diagnostics v_n = row_count;
    return jsonb_build_object('touched', v_n);
  elsif p_action = 'cancel' then$r$], array[1, 1]);

select pg_temp.patch('bi.ingest_as(text,text,jsonb)'::regprocedure, array[
  $r$elsif p_action in ('check', 'hold', 'queue', 'jobs', 'cancel', 'retry') then$r$,
  $r$elsif p_action in ('check', 'hold', 'queue', 'jobs', 'cancel', 'retry', 'touch') then$r$], array[1]);
