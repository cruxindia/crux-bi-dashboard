-- Applied to Supabase project via MCP on 20261118142355
-- wave 113c (18-Nov-2026). (1) Google Drive by link: the folders are shared "anyone with the link", so the upload page lists and reads them with the
-- browser key and no Google sign-in; admins paste each folder link once. 'imports' lists recent committed uploads so the page can pre-tick new or changed files.
-- (2) Business Associates vs Crux Branches: a client x location pair with both models (BOM at Pune: BOM codes by a Business Associate, BRT by a Crux Branch)
-- compares each model with its own previous figures. (3) Planned / withdrawn / owner targets force every page to recompute (correction floor).
create or replace function bi.drive_config_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'get'); v jsonb; nv jsonb;
begin
  select value into v from bi.app_setting where key = 'google_drive';
  v := coalesce(v, '{}'::jsonb);
  if op = 'get' then
    return v || jsonb_build_object(
      'configured', nullif(v->>'client_id', '') is not null and nullif(v->>'api_key', '') is not null and nullif(v->>'app_id', '') is not null,
      'configured_link', nullif(v->>'api_key', '') is not null and jsonb_array_length(coalesce(v->'folders', '[]'::jsonb)) > 0);
  elsif op = 'imports' then   -- wave 113c: latest committed upload per file name and kind (last 120 days)
    return jsonb_build_object('imports', (select coalesce(jsonb_agg(jsonb_build_object('kind', source_category, 'name', file_name, 'at', at)), '[]'::jsonb)
      from (select source_category, file_name, max(committed_at) at from bi.import_batch
             where status in ('committed', 'superseded') and committed_at > now() - interval '120 days' and file_name is not null group by 1, 2) x));
  elsif op = 'set' then
    nv := v;
    if p ? 'client_id' then
      if nullif(trim(p->>'client_id'), '') is not null and trim(p->>'client_id') !~ '^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$' then
        raise exception 'The OAuth client ID should look like 1234567890-abc123.apps.googleusercontent.com'; end if;
      nv := jsonb_set(nv, '{client_id}', to_jsonb(nullif(trim(p->>'client_id'), '')));
    end if;
    if p ? 'api_key' then
      if nullif(trim(p->>'api_key'), '') is not null and trim(p->>'api_key') !~ '^AIza[0-9A-Za-z_-]{30,}$' then
        raise exception 'The API key should start with AIza'; end if;
      nv := jsonb_set(nv, '{api_key}', to_jsonb(nullif(trim(p->>'api_key'), '')));
    end if;
    if p ? 'app_id' then
      if nullif(trim(p->>'app_id'), '') is not null and trim(p->>'app_id') !~ '^[0-9]{6,20}$' then
        raise exception 'The project number is digits only (Google Cloud → Project settings → Project number)'; end if;
      nv := jsonb_set(nv, '{app_id}', to_jsonb(nullif(trim(p->>'app_id'), '')));
    end if;
    if jsonb_typeof(p->'folders') = 'array' then
      if exists (select 1 from jsonb_array_elements(p->'folders') x where coalesce(x->>'id', '') !~ '^[A-Za-z0-9_-]{10,}$' or coalesce(x->>'label', '') = ''
                    or coalesce(x->>'rk', '') !~ '^[A-Za-z0-9_-]{0,80}$' or length(coalesce(x->>'link', '')) > 500) then
        raise exception 'Each folder needs a label and a Google Drive folder link (or folder ID)'; end if;
      nv := jsonb_set(nv, '{folders}', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('key', x->>'key', 'label', x->>'label', 'id', x->>'id',
                                                   'rk', nullif(x->>'rk', ''), 'link', nullif(x->>'link', ''))) order by o)
                                         from jsonb_array_elements(p->'folders') with ordinality t(x, o)));
    end if;
    update bi.app_setting set value = nv, updated_by = p_actor, updated_at = now() where key = 'google_drive';
    insert into bi.audit_log(actor, action, entity, detail)
    values (p_actor, 'drive_config_set', 'app_setting',
            jsonb_build_object('client_id_set', nullif(nv->>'client_id', '') is not null, 'api_key_set', nullif(nv->>'api_key', '') is not null,
                               'app_id_set', nullif(nv->>'app_id', '') is not null, 'folders', jsonb_array_length(coalesce(nv->'folders', '[]'::jsonb))));
    return nv || jsonb_build_object('configured', nullif(nv->>'client_id', '') is not null and nullif(nv->>'api_key', '') is not null and nullif(nv->>'app_id', '') is not null,
                                    'configured_link', nullif(nv->>'api_key', '') is not null and jsonb_array_length(coalesce(nv->'folders', '[]'::jsonb)) > 0);
  end if;
  raise exception 'op must be get, imports or set';
end $f$;
revoke all on function bi.drive_config_admin(text, jsonb) from public, anon, authenticated;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '113c');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.api_assoc(date,jsonb)'::regprocedure, array[
  $r$left join (select location_id, fam, sum(revenue) r from cmp group by 1, 2) p on p.location_id = g.location_id and p.fam = g.fam$r$,
  $r$left join (select location_id, fam, md, sum(revenue) r from cmp group by 1, 2, 3) p on p.location_id = g.location_id and p.fam = g.fam and p.md = g.md   -- wave 113c$r$], array[1]);
select pg_temp.patch('bi.target_fill_plan(text,date,text)'::regprocedure, array[
  $r$  return jsonb_build_object('ok', true, 'set', v_id, 'apply', r) || bi.target_source(v_m);$r$,
  $r$  insert into bi.api_cache_floor (floor_at, reason, set_by, set_at) values (now(), 'planned targets set for ' || to_char(v_m, 'Mon-YY'), p_actor, now());
  return jsonb_build_object('ok', true, 'set', v_id, 'apply', r) || bi.target_source(v_m);$r$], array[1]);
select pg_temp.patch('bi.target_fill_withdraw(text,date,text)'::regprocedure, array[
  $r$  return jsonb_build_object('ok', true, 'set', v_id, 'rows_restored', v_n);$r$,
  $r$  insert into bi.api_cache_floor (floor_at, reason, set_by, set_at) values (now(), 'planned targets withdrawn for ' || to_char(v_m, 'Mon-YY'), p_actor, now());
  return jsonb_build_object('ok', true, 'set', v_id, 'rows_restored', v_n);$r$], array[1]);
select pg_temp.patch('bi.target_fill_on_commit(date)'::regprocedure, array[
  $r$      insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('tracker upload', 'target_fill_owner', 'zt_snapshot', p_snap::text, r);$r$,
  $r$      insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('tracker upload', 'target_fill_owner', 'zt_snapshot', p_snap::text, r);
      insert into bi.api_cache_floor (floor_at, reason, set_by, set_at) values (now(), 'owner targets replaced the planned targets (' || p_snap || ')', 'tracker upload', now());$r$], array[1]);
