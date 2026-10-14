-- Applied to Supabase project via MCP on 20261014075106
alter table bi.zt_matrix_draft add column if not exists committed_batch bigint;
alter table bi.zt_reopen add column if not exists active boolean not null default true;
comment on column bi.zt_matrix_draft.committed_batch is 'Set when the draft value was committed (kept as an entry log); null = open draft.';
comment on column bi.zt_reopen.active is 'true while a committed date is open for correction; false after commit or discard (history kept).';
