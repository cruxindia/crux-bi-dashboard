-- Applied to Supabase project via MCP on 20261022100137
-- bi_093i (22-Oct-2026): when adding a branch manager ends the current assignment, the audit row records which assignment was ended and its previous end date
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.branch_manager_admin(text,jsonb)'::regprocedure);
  o := array[$o0$declare op text := coalesce(p->>'op', 'list'); r bi.branch_manager; v_loc int; v_fam text; v_from date; v_to date; v_name text; v_id bigint; clash bigint;$o0$,
             $o1$      update bi.branch_manager set valid_to = v_from - 1, changed_by = p_actor, changed_at = now()
       where active and location_id = v_loc and client_family is not distinct from v_fam and (valid_to is null or valid_to >= v_from) and (valid_from is null or valid_from < v_from);$o1$,
             $o2$      jsonb_build_object('location_id', v_loc, 'client_family', v_fam, 'valid_from', v_from, 'valid_to', v_to));$o2$];
  n := array[$n0$declare op text := coalesce(p->>'op', 'list'); r bi.branch_manager; v_loc int; v_fam text; v_from date; v_to date; v_name text; v_id bigint; clash bigint; v_ended jsonb;$n0$,
             $n1$      select jsonb_agg(jsonb_build_object('id', m.id, 'valid_to_before', m.valid_to)) into v_ended from bi.branch_manager m
       where m.active and m.location_id = v_loc and m.client_family is not distinct from v_fam and (m.valid_to is null or m.valid_to >= v_from) and (m.valid_from is null or m.valid_from < v_from);
      update bi.branch_manager set valid_to = v_from - 1, changed_by = p_actor, changed_at = now()
       where active and location_id = v_loc and client_family is not distinct from v_fam and (valid_to is null or valid_to >= v_from) and (valid_from is null or valid_from < v_from);$n1$,
             $n2$      jsonb_build_object('location_id', v_loc, 'client_family', v_fam, 'valid_from', v_from, 'valid_to', v_to, 'ended_previous', v_ended));$n2$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'branch_manager_admin fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
