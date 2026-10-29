-- Applied to Supabase project via MCP on 20261029153043
-- A rule change must show at once: older cached answers are not served after it (cache floor), same as data corrections.
do $do$
declare src text; frag text; n int;
begin
  select pg_get_functiondef('bi.setting_admin(text, jsonb)'::regprocedure) into src;
  frag := $q$  return jsonb_build_object('ok', true, 'key', v_key, 'from', v_old, 'to', v_val);$q$;
  n := (length(src) - length(replace(src, frag, ''))) / length(frag);
  if n <> 1 then raise exception 'setting_admin fragment found % times', n; end if;
  if position('api_cache_floor' in src) = 0 then
    execute replace(src, frag, $q$  insert into bi.api_cache_floor(floor_at, reason, set_by) values (now(), 'setting ' || v_key || ' = ' || v_val, p_actor);
$q$ || frag);
  end if;
end $do$;
