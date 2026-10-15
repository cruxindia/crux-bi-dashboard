-- Applied to Supabase project via MCP on 20261015003301
create table if not exists bi.cache_warm(id int primary key default 1 check (id = 1), version bigint, started_at timestamptz, finished_at timestamptz, calls int, seconds numeric, note text);
alter table bi.cache_warm enable row level security;
