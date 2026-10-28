-- Applied to Supabase project via MCP on 20261028065610
-- bi_094j (28-Oct-2026): rate recomputation when a tracker snapshot has no rate column.
-- The 21-Oct and 22-Oct-2026 tracker snapshots were loaded with every leaf rate empty (revenue present). A later rate change or undo then
-- valued those days' cases at 0 (coalesce(rate, 0)) and the undo restored the rate from the empty snapshot. Found by acceptance test T25.
-- Fix: a day without a stored rate uses the last stored rate earlier in the same month (else the next one in the month); the undo looks
-- back to the last snapshot that has a rate. Stored source values are not changed.
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.rate_recompute(date,integer,text)'::regprocedure);
  o := $o$coalesce(z.rate, 0) r$o$;
  n := $n$coalesce(z.rate,
                    (select pr.rate from bi.zt_row pr where pr.row_type = 'leaf' and pr.location_id = z.location_id and pr.client_code = z.client_code and pr.rate is not null
                        and pr.snapshot_date < z.snapshot_date and pr.snapshot_date >= date_trunc('month', z.snapshot_date)::date order by pr.snapshot_date desc limit 1),
                    (select nx.rate from bi.zt_row nx where nx.row_type = 'leaf' and nx.location_id = z.location_id and nx.client_code = z.client_code and nx.rate is not null
                        and nx.snapshot_date > z.snapshot_date and nx.snapshot_date < (date_trunc('month', z.snapshot_date) + interval '1 month')::date order by nx.snapshot_date limit 1),
                    0) r$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'rate_recompute fragment not found exactly once'; end if;
  execute replace(d, o, n);

  d := pg_get_functiondef('bi.rate_admin'::regproc);
  o := $o$pr.snapshot_date < v_wef order by pr.snapshot_date desc limit 1)$o$;
  n := $n$pr.snapshot_date < v_wef and pr.rate is not null order by pr.snapshot_date desc limit 1)$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'rate_admin fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;
