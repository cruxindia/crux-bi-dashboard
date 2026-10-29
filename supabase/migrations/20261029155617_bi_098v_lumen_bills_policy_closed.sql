-- Applied to Supabase project via MCP on 20261029155617
-- Owner-authorised Lumen removal (5.8.4): until the owner deletes the buckets, the old storage policy that let anyone read and
-- write the private "bills" bucket is closed (no rows match). The owner script still drops it.
alter policy lumen_bills_all on storage.objects using (false) with check (false);
