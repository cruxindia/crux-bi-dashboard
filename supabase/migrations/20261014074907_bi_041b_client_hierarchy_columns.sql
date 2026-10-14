-- Applied to Supabase project via MCP on 20261014074907
alter table bi.client add column if not exists summary_under text references bi.client(code);
alter table bi.client add column if not exists product text;
create table if not exists bi.zt_matrix_meta (snapshot_date date primary key, control_mtd numeric, note text, updated_by text, updated_at timestamptz not null default now());
create table if not exists bi.zt_reopen (snapshot_date date primary key references bi.zt_snapshot(snapshot_date), reopened_by text not null, reopened_at timestamptz not null default now(), reason text not null);
create table if not exists bi.zt_snapshot_archive (id bigserial primary key, snapshot_date date not null, archived_at timestamptz not null default now(), archived_by text not null,
  reason text not null, batch_id bigint, file_name text, rows jsonb not null);
comment on table bi.zt_snapshot_archive is 'Leaf rows of a tracker snapshot as they were before an admin correction (never deleted).';
