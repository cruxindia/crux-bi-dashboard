-- Applied to Supabase project via MCP on 20261022094357
-- bi_093h (22-Oct-2026): cases growth pairs also carry the previous month's branch manager and a read-with-care note when it changed (same as revenue)
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth(date,jsonb,jsonb)'::regprocedure);
  o := array[$o0$'branch_manager', r.mgr, 'branch_manager_changed', r.mgr is not null and r.mgr_prev is not null and r.mgr is distinct from r.mgr_prev,$o0$,
             $o1$            union all select 'owner changed this month' where r.owner is distinct from r.owner_prev$o1$];
  n := array[$n0$'branch_manager', r.mgr, 'branch_manager_prev', r.mgr_prev, 'branch_manager_changed', r.mgr is not null and r.mgr_prev is not null and r.mgr is distinct from r.mgr_prev,$n0$,
             $n1$            union all select 'owner changed this month' where r.owner is distinct from r.owner_prev
            union all select 'branch manager changed this month (' || r.mgr_prev || ' → ' || r.mgr || ')' where r.mgr is not null and r.mgr_prev is not null and r.mgr is distinct from r.mgr_prev$n1$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_growth fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
