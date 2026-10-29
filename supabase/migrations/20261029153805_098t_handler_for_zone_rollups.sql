-- Applied to Supabase project via MCP on 20261029153805
-- Owner rule 29-Oct-2026 (5.2): the operations handler is the location head / branch manager. Cases that Force1 attributes only to
-- a zone roll-up (e.g. 171 open cases on "Lucknow / ROUP Zone") get the managers of that zone's team locations.
do $do$
declare src text; n int;
  f1 text := $q$  select case when p_code is null then$q$;
  f2 text := $q$else bi.branch_manager_code_at(p_loc, p_code, p_at) end$q$;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p where p.proname = 'ops_handler_default' and p.pronamespace = 'bi'::regnamespace;
  if position('zone teams' in src) > 0 then return; end if;
  n := (length(src) - length(replace(src, f1, ''))) / length(f1); if n <> 1 then raise exception 'f1 found % times', n; end if;
  n := (length(src) - length(replace(src, f2, ''))) / length(f2); if n <> 1 then raise exception 'f2 found % times', n; end if;
  src := replace(src, f1, $q$  select coalesce(case when p_code is null then$q$);
  src := replace(src, f2, f2 || $q$,
         (select string_agg(distinct m.manager, ', ') || ' (zone teams)'
            from bi.location r join bi.location c on c.zone_group = r.rollup_zone and not c.is_rollup
            join bi.branch_manager m on m.location_id = c.id and m.active
                 and (m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to >= p_at)
           where r.id = p_loc and r.is_rollup))$q$);
  execute src;
end $do$;
select bi.person_role_at('operations_handler', 48, null, date '2026-10-28') is not null lucknow_zone_has_handler;
