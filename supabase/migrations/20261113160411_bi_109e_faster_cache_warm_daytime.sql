-- Applied to Supabase project via MCP on 20261113160411
-- wave 109e (13-Nov-2026): pages were slow for a while after each daytime upload (32 s first load) because the day-time cache warm ran every 10 minutes
-- for 20 seconds. On the Pro plan it now runs every 3 minutes for up to 40 seconds (still skipping anything slower than 15 s, which the night run handles).
select cron.schedule('bi-api-revalidate-light', '*/3 0-18 * * *', 'call bi.api_revalidate_light(40)');
