-- Applied to Supabase project via MCP on 20261108061919
-- wave 103f (owner 8-Nov-2026 11:39: "drop what needs to be dropped"): remove the temporary test copy of the target function made while
-- testing wave 103a. Nothing references it (checked: no function body, view or cron job mentions api_target_sheet_t103).
drop function if exists bi.api_target_sheet_t103(date, jsonb, jsonb);
