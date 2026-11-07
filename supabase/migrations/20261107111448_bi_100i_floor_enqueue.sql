-- Applied to Supabase project via MCP on 20261107111448
-- Wave 100: a correction floor (a setting change, a mapping correction) makes every cached figure unservable, and until now
-- nothing put those figures back in the queue, so each page recomputed on first view (heavy ones could time out at the gateway).
-- After a floor, figures computed in the last 7 days are queued for the background revalidation (light job by day, night job).
create or replace function bi.api_cache_floor_enqueue() returns trigger language plpgsql security definer
set search_path to 'bi', 'public' as $f$
begin
  insert into bi.api_cache_queue(k, fn, args)
  select k, fn, args from bi.api_cache where fn is not null and computed_at > now() - interval '7 days'
  on conflict (k) do update set requested_at = now(), done_at = null, last_error = null, fn = excluded.fn, args = excluded.args;
  return null;
end $f$;
drop trigger if exists api_cache_floor_enqueue on bi.api_cache_floor;
create trigger api_cache_floor_enqueue after insert on bi.api_cache_floor for each statement execute function bi.api_cache_floor_enqueue();
