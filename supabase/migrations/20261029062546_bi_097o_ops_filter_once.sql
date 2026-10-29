-- Applied to Supabase project via MCP on 20261029062546
-- bi_097o (29-Oct-2026): bi_097m meant the location / client filters to run once per distinct value, but the planner pushed them back below
-- the DISTINCT (still 238,040 calls each, 9 s). OFFSET 0 keeps the distinct lists as their own step. Results unchanged.
do $do$
declare d text := pg_get_functiondef('bi.api_ops(date,jsonb)'::regprocedure);
        o1 text := $o$coalesce(recon_unit, '<null>') u from bi.case_store) lu$o$; n1 text := $n$coalesce(recon_unit, '<null>') u from bi.case_store offset 0) lu$n$;
        o2 text := $o$coalesce(client_code, '<null>') k from bi.case_store) cc$o$; n2 text := $n$coalesce(client_code, '<null>') k from bi.case_store offset 0) cc$n$;
begin
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'api_ops fragment 1'; end if;
  if (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'api_ops fragment 2'; end if;
  execute replace(replace(d, o1, n1), o2, n2);
end $do$;
