-- Applied to Supabase project via MCP on 20261014114046
do $do$
declare d text := pg_get_functiondef('bi.api_organic(date,jsonb,text,text)'::regprocedure);
  o text := '  brm as (select b.client_code, b.bk, b.location_id, b.n,
                 (select min(b2.received_month) from br b2 where b2.client_code = b.client_code and b2.bk = b.bk) first_m,
                 exists (select 1 from br b3 where b3.client_code = b.client_code and b3.bk = b.bk and b3.received_month between (m - interval ''3 months'')::date and (m - interval ''1 month'')::date) recent
          from br b left join bi.location l on l.id = b.location_id';
  n text := '  bf as (select br.client_code, br.bk, min(br.received_month) first_m,
                 bool_or(br.received_month between (m - interval ''3 months'')::date and (m - interval ''1 month'')::date) recent from br group by 1, 2),
  brm as (select b.client_code, b.bk, b.location_id, b.n, bf.first_m, bf.recent
          from br b join bf on bf.client_code = b.client_code and bf.bk = b.bk left join bi.location l on l.id = b.location_id';
begin
  if position('bf as (' in d) = 0 then
    if position(o in d) = 0 then raise exception 'api_organic branch block not found'; end if;
    d := replace(d, o, n); execute d;
  end if;
end $do$;
