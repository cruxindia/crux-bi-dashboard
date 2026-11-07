-- Applied to Supabase project via MCP on 20261107160946
-- wave 101m: potential rankings leave out "no team yet" rows and, for the share captured, pairs with under ₹50,000 potential (tiny denominators)
do $m$
declare d text := pg_get_functiondef('bi.ask_h_potential(date, jsonb, text, text)'::regprocedure); o text := d;
begin
  d := replace(d, $a$where g not like '(no team%' and coalesce((x->>'potential')::numeric, 0) > 0) y;$a$,
                  $a$where g not like '(no team%' and g not like 'No team%' and coalesce((x->>'potential')::numeric, 0) >= case when met = 'penetration' then 50000 else 1 end) y;$a$);
  d := replace(d, $a$where coalesce(x->>'manager', '') like '(no team%';$a$,
                  $a$where coalesce(x->>'manager', x->>'location', '') like '(no team%' or coalesce(x->>'location', '') like 'No team%';$a$);
  d := replace(d, $a$case when dim = 'bm' and unm > 0 then format(' %s of potential sits with teams or areas that have no mapped branch manager.', bi.fmt_inr(unm)) else '' end);$a$,
                  $a$case when dim = 'bm' and unm > 0 then format(' %s of potential sits with teams or areas that have no mapped branch manager.', bi.fmt_inr(unm)) when dim = 'location' and unm > 0 then format(' %s of potential is in areas with no Crux team yet (not ranked).', bi.fmt_inr(unm)) else '' end || case when met = 'penetration' then ' Pairs with under ₹50,000 potential are left out of this ranking.' else '' end);$a$);
  if d = o then raise exception 'no change'; end if;
  execute d;
end $m$;
