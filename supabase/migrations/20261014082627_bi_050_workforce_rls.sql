-- Applied to Supabase project via MCP on 20261014082627
-- bi_050: defence in depth — workforce master has no direct client access (only via SECURITY DEFINER functions)
alter table bi.workforce_master enable row level security;
comment on column bi.workforce_master.exit_reason is 'HR detail; stored for admins, never returned by public APIs.';
