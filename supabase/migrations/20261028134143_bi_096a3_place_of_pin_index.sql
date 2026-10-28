-- Applied to Supabase project via MCP on 20261028134143
create or replace function bi.place_of_pin(p text) returns text language sql stable set search_path to 'bi', 'public' as $f$
  with q as (select substring(p from '\d{6}') s)
  select coalesce(r.place, r.state) from q join bi.ref_pin_prefix r
    on r.prefix in (left(q.s, 6), left(q.s, 5), left(q.s, 4), left(q.s, 3), left(q.s, 2))
   order by length(r.prefix) desc limit 1 $f$;
