-- Applied to Supabase project via MCP on 20261012095815

-- Code-only export channel for the GitHub repository. Contains NO business data.
create table if not exists bi.repo_file (path text primary key check (path !~ '\.\.'), content text not null, updated_at timestamptz not null default now());
create table if not exists bi.export_token (token_hash text primary key, label text not null, expires_at timestamptz not null, revoked boolean not null default false);
alter table bi.repo_file enable row level security; alter table bi.export_token enable row level security;

create or replace function public.bi_repo_stash(p_token text, p_files jsonb) returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare n int;
begin
  if not bi.token_ok(p_token) and bi.app_role() is distinct from 'admin' then raise exception 'not authorised' using errcode='42501'; end if;
  insert into bi.repo_file(path, content, updated_at)
  select key, value #>> '{}', now() from jsonb_each(p_files)
  on conflict (path) do update set content = excluded.content, updated_at = now();
  get diagnostics n = row_count; return jsonb_build_object('stored', n);
end $$;

create or replace function public.bi_repo_export(p_token text) returns jsonb
language plpgsql security definer set search_path = bi, public, extensions as $$
begin
  if not exists (select 1 from bi.export_token where token_hash = encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex') and not revoked and expires_at > now())
    then raise exception 'not authorised' using errcode='42501'; end if;
  return (select coalesce(jsonb_object_agg(path, content), '{}'::jsonb) from (
      select path, content from bi.repo_file
      union all
      select 'supabase/migrations/' || version || '_' || name || '.sql',
             '-- Applied to Supabase project via MCP on ' || version || E'\n' || array_to_string(statements, E'\n;\n') || E'\n'
      from supabase_migrations.schema_migrations where name like 'bi\_%'
  ) t);
end $$;

