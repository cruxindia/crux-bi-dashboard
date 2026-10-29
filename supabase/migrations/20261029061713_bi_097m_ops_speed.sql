-- Applied to Supabase project via MCP on 20261029061713
-- bi_097m (29-Oct-2026): the operations figures (bi.api_ops) took 8 s alone and over 45 s under load (statement timeout right after a data change,
-- so TAT, the Business Tracker sequence and the Overview card could fail). Same results, two changes:
-- (1) the location and client filters are evaluated once per distinct location / unit and client instead of once per case (238,040 calls each);
-- (2) "open > 7 days at day end" is counted from each case's open interval (start/end events and a running total) instead of joining every day to every case.
do $do$
declare d text := pg_get_functiondef('bi.api_ops(date,jsonb)'::regprocedure); i int;
        r text[][] := array[
  [$o$  with ops as materialized ($o$,
   $n$  with okl as materialized (select lu.l, lu.u from (select distinct coalesce(location_id, -1) l, coalesce(recon_unit, '<null>') u from bi.case_store) lu
                                where bi.loc_ok(nullif(lu.l, -1), nullif(lu.u, '<null>'), f)),
       okc as materialized (select cc.k from (select distinct coalesce(client_code, '<null>') k from bi.case_store) cc where bi.fam_ok(nullif(cc.k, '<null>'), f)),
       ops as materialized ($n$],
  [$o$            and bi.loc_ok(c.location_id, c.recon_unit, f) and bi.fam_ok(c.client_code, f)),$o$,
   $n$            and (coalesce(c.location_id, -1), coalesce(c.recon_unit, '<null>')) in (select l, u from okl) and coalesce(c.client_code, '<null>') in (select k from okc)),$n$],
  [$o$       o7 as (select days.d, count(o.case_id) n from days left join ops o on o.rd <= days.d - 7 and (o.cd is null or o.cd > days.d) group by 1),$o$,
   $n$       o7ev as (select greatest(rd + 7, m0) s, least(coalesce(cd - 1, m1), m1) e from ops where rd + 7 <= m1),
       o7x as (select x.d, sum(x.delta) delta from (select s d, 1 delta from o7ev where s <= e union all select e + 1, -1 from o7ev where s <= e) x group by 1),
       o7 as (select days.d, sum(coalesce(o7x.delta, 0)) over (order by days.d) n from days left join o7x on o7x.d = days.d),$n$]];
begin
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'api_ops fragment % not found exactly once', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
end $do$;
