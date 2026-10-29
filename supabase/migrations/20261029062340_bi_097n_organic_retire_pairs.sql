-- Applied to Supabase project via MCP on 20261029062340
-- bi_097n (29-Oct-2026): the organic store kept rows for a location × client pair after all of its tracker data moved elsewhere (the Amaravati
-- team location after D170/D187), so the organic expectation for Amaravati was counted twice (Sep-26 269, Oct-26 320 cases).
-- The refresh now sets the expectation of a pair with no tracker data at all (no month total, not in the latest report) to 0 — the row is kept,
-- it simply no longer adds anything. Same rule for any future relabel or retarget.
do $do$
declare d text := pg_get_functiondef('bi.organic_refresh()'::regprocedure);
        o1 text := $o$declare n int; cur date$o$; n1 text := $n$declare n int; k int; cur date$n$;
        o2 text := $o$  get diagnostics n = row_count;
$o$;
        n2 text := $n$  get diagnostics n = row_count;
  -- pairs with no tracker data left (moved by a retarget or relabel): expectation 0, row kept
  with mb as (select distinct location_id, client_code from bi.v_month_business
              where month between date '2024-04-01' and (cur - interval '1 month')::date and location_id is not null),
       pairs as (select location_id, client_code from mb
                 union select location_id, client_code from bi.zt_row where row_type = 'leaf' and location_id is not null and client_code is not null
                   and snapshot_date = (select max(snapshot_date) from bi.zt_snapshot))
  update bi.organic_store o set organic = 0, v1 = 0, v2 = 0, v3 = 0, b_mom = 0, b_qoq = 0, b_yoy = null, computed_at = now()
   where (o.organic <> 0 or o.v1 <> 0 or o.v2 <> 0 or o.v3 <> 0 or o.b_mom <> 0 or o.b_qoq <> 0 or o.b_yoy is not null)
     and not exists (select 1 from pairs p where p.location_id = o.location_id and p.client_code = o.client_code);
  get diagnostics k = row_count; n := n + k;
$n$;
begin
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'organic_refresh fragment 1'; end if;
  if (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'organic_refresh fragment 2'; end if;
  execute replace(replace(d, o1, n1), o2, n2);
end $do$;
