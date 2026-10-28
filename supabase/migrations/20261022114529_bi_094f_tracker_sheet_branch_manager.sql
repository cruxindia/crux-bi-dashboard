-- Applied to Supabase project via MCP on 20261022114529
-- bi_094f (22-Oct-2026): tracker view rows carry the branch manager mapped on the report date (client rows: the manager of that location × client; location totals: every manager with an assignment there)
do $do$
declare d text; o text := $o$      'stk', lf.stk, 'reg', lf.reg, 'tier', lf.tier,$o$;
        n text := $n$      'stk', lf.stk, 'reg', lf.reg, 'tier', lf.tier,
      'bm', case when z.row_type = 'leaf' and z.location_id is not null and z.client_code is not null then bi.branch_manager_code_at(z.location_id, z.client_code, s)
                 when z.row_type = 'location_total' and z.location_id is not null then (select string_agg(distinct m.manager, ', ' order by m.manager) from bi.branch_manager m
                      where m.active and m.location_id = z.location_id and (m.valid_from is null or m.valid_from <= s) and (m.valid_to is null or m.valid_to >= s)) end,$n$;
begin
  d := pg_get_functiondef('bi.api_tracker_sheet(date,jsonb,date,integer)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'api_tracker_sheet fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;
