-- Applied to Supabase project via MCP on 20261029140933
-- Wave 098 (owner rule 29-Oct-2026 19:35 IST): the operations handler of a location is its mapped branch manager / location head
-- (following that mapping's own effective dates) unless an explicit Admin → Roles row overrides it; collections owners are explicit rows.
create or replace function bi.ops_handler_default(p_loc integer, p_code text, p_at date)
returns text language sql stable set search_path to 'bi', 'public' as $f$
  select case when p_code is null then
           (select string_agg(distinct m.manager, ', ') from bi.branch_manager m
             where m.active and m.location_id = p_loc
               and (m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to >= p_at))
         else bi.branch_manager_code_at(p_loc, p_code, p_at) end
$f$;
comment on function bi.ops_handler_default(integer, text, date) is 'Wave 098: default operations handler = mapped branch manager(s) of the location (all client families when no client is given).';

create or replace function bi.person_role_at(p_role text, p_loc integer, p_code text, p_at date)
returns text language sql stable set search_path to 'bi', 'public' as $f$
  select coalesce(
    (select string_agg(distinct r.person, ', ') from bi.person_role r
      where r.active and r.role = p_role and r.location_id = p_loc and (r.client_code is null or r.client_code = p_code)
        and coalesce(r.valid_from, date '1900-01-01') <= p_at and coalesce(r.valid_to, date '2999-12-31') >= p_at
        and (p_code is null or r.client_code is not distinct from p_code or not exists (
              select 1 from bi.person_role r2 where r2.active and r2.role = p_role and r2.location_id = p_loc and r2.client_code = p_code
                and coalesce(r2.valid_from, date '1900-01-01') <= p_at and coalesce(r2.valid_to, date '2999-12-31') >= p_at))),
    case when p_role = 'operations_handler' then bi.ops_handler_default(p_loc, p_code, p_at) end)
$f$;

-- Cash view: collections owner beside each location row
do $mig$
declare d text := pg_get_functiondef('bi.api_collections(date,jsonb)'::regprocedure);
        a text := '''by_location'', v_byloc,';
        b text := '''by_location'', (select coalesce(jsonb_agg(x || jsonb_build_object(''collections_owner'', bi.person_role_at(''collections_owner'', nullif(x->>''location_id'', '''')::int, null, current_date)) order by o), ''[]''::jsonb) from jsonb_array_elements(coalesce(v_byloc, ''[]''::jsonb)) with ordinality t(x, o)),';
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_collections fragment not found exactly once'; end if;
  execute replace(d, a, b);
end $mig$;
