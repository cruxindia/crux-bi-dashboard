-- Applied to Supabase project via MCP on 20261014233206
-- bi_081: every monitor run rewrites one row per branch in bi.branch_seen; half-full pages let those updates stay on the same page
-- (HOT updates), so the primary-key index no longer grows with each run. Storage parameter only; no data change.
alter table bi.branch_seen set (fillfactor = 50);
