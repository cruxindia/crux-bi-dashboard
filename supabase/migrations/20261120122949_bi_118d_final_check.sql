-- Applied to Supabase project via MCP on 20261120122949
create or replace function bi.target_final_check(p_actor text, p_month date, p_rows jsonb, p_reason text, p_file text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare r jsonb;
begin
  begin
    r := bi.target_final_save(p_actor, p_month, p_rows, case when length(coalesce(trim(p_reason), '')) >= 5 then p_reason else 'check only' end, p_file);
    raise exception using errcode = 'P0099', message = r::text;
  exception when sqlstate 'P0099' then
    return jsonb_build_object('check', true) || sqlerrm::jsonb;
  end;
end $f$;
revoke all on function bi.target_final_check(text, date, jsonb, text, text) from public, anon, authenticated;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '118d');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.target_fill_admin(text,jsonb)'::regprocedure, array[
  $r$  elsif op = 'final_withdraw' then$r$,
  $r$  elsif op = 'final_check' then return bi.target_final_check(p_actor, v_m, p->'rows', p->>'reason', p->>'file');   -- wave 118d
  elsif op = 'final_withdraw' then$r$,
  $r$'op must be get, plan, withdraw, final_template, final_save or final_withdraw'$r$,
  $r$'op must be get, plan, withdraw, final_template, final_check, final_save or final_withdraw'$r$], array[1, 1]);
