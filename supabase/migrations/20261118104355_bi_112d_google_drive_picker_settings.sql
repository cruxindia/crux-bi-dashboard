-- Applied to Supabase project via MCP on 20261118104355
-- wave 112d (18-Nov-2026): upload from Google Drive. The page opens Google's file picker on the three report folders (Zonal Tracker,
-- Point Wise, Case Wise); picked files are read in the browser and go through the same checks as a manual upload. The Google settings
-- (OAuth client ID, browser API key restricted to the dashboard's web address, Cloud project number) are kept here and shown to admins only.
insert into bi.app_setting (key, value, note, updated_by)
values ('google_drive', jsonb_build_object('client_id', null, 'api_key', null, 'app_id', null,
          'folders', jsonb_build_array(
            jsonb_build_object('key', 'zonal', 'label', 'Zonal Tracker', 'id', '1ANPZ30iQkVXbTFt99UaZnAjn6sQRcpUu'),
            jsonb_build_object('key', 'point', 'label', 'Point wise', 'id', '1mhhGbTkgcwBcZFLUtNpu6U1X-IP6CW9v'),
            jsonb_build_object('key', 'case', 'label', 'Case wise', 'id', '1YBf8fO2HdhWToB9Pi99sfS2bKgjHglWR'))),
        'wave 112d: Google Drive picker settings (admin only). Folders from the owner, 18-Nov-2026.', 'wave 112d')
on conflict (key) do nothing;

create or replace function bi.drive_config_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'get'); v jsonb; nv jsonb;
begin
  select value into v from bi.app_setting where key = 'google_drive';
  v := coalesce(v, '{}'::jsonb);
  if op = 'get' then
    return v || jsonb_build_object('configured', nullif(v->>'client_id', '') is not null and nullif(v->>'api_key', '') is not null and nullif(v->>'app_id', '') is not null);
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
      if exists (select 1 from jsonb_array_elements(p->'folders') x where coalesce(x->>'id', '') !~ '^[A-Za-z0-9_-]{10,}$' or coalesce(x->>'label', '') = '') then
        raise exception 'Each folder needs a label and a Drive folder ID'; end if;
      nv := jsonb_set(nv, '{folders}', p->'folders');
    end if;
    update bi.app_setting set value = nv, updated_by = p_actor, updated_at = now() where key = 'google_drive';
    insert into bi.audit_log(actor, action, entity, detail)
    values (p_actor, 'drive_config_set', 'app_setting',
            jsonb_build_object('client_id_set', nullif(nv->>'client_id', '') is not null, 'api_key_set', nullif(nv->>'api_key', '') is not null,
                               'app_id_set', nullif(nv->>'app_id', '') is not null, 'folders', jsonb_array_length(coalesce(nv->'folders', '[]'::jsonb))));
    return nv || jsonb_build_object('configured', nullif(nv->>'client_id', '') is not null and nullif(nv->>'api_key', '') is not null and nullif(nv->>'app_id', '') is not null);
  end if;
  raise exception 'op must be get or set';
end $f$;
comment on function bi.drive_config_admin(text, jsonb) is 'wave 112d: Google Drive picker settings for the upload page (admin only; the audit log records which values are set, never the values).';
revoke all on function bi.drive_config_admin(text, jsonb) from public, anon, authenticated;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '112d');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('public.bi_admin(text,jsonb)'::regprocedure, array[
  $r$    when 'operating_model' then return bi.operating_model_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');   -- wave 109c$r$,
  $r$    when 'operating_model' then return bi.operating_model_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');   -- wave 109c
    when 'drive_config' then return bi.drive_config_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');   -- wave 112d$r$], array[1]);
