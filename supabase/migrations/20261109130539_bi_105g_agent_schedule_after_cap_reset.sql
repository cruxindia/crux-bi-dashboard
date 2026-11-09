-- Applied to Supabase project via MCP on 20261109130539
-- wave 105g (9-Nov-2026): the AI daily cap (AI_DAILY_CAP) counts calls per UTC day, so the chat review at 23:40 UTC could find the cap already used up
-- by the day's questions. It now runs at 00:05 UTC (05:35 IST), right after the cap resets, and still reviews the previous 24 hours.
select cron.schedule('bi-agent-chat-review', '5 0 * * *', $$select bi.call_edge('ask-crux', '{"action":"agent_run","job":"chat_review"}'::jsonb)$$);
