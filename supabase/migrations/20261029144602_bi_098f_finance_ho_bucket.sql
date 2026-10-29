-- Applied to Supabase project via MCP on 20261029144602
-- Wave 098 (owner decision 29-Oct-2026 19:35 IST): finance lines whose location the workbooks do not state belong to Mumbai HO, with
-- accountability on the Finance team, not on operations. They stay outside every branch / branch-manager figure (location 0) and are shown
-- under "Mumbai HO — Finance" in the finance views, owned by the Mumbai collections owner.
do $mig$
declare d text := pg_get_functiondef('bi.api_collections(date,jsonb)'::regprocedure); a text; b text;
begin
  a := '''location'', coalesce(l.label, ''Location not identified''), ''zone'', coalesce(l.zone_group, l.rollup_zone),';
  b := '''location'', coalesce(l.label, case when ids.id = 0 then ''Mumbai HO — Finance (location not stated in the workbook)'' else ''Location not identified'' end), ''zone'', coalesce(l.zone_group, l.rollup_zone, case when ids.id = 0 then (select z.zone_group from bi.location z where z.label = ''Mumbai'' limit 1) end), ''finance_owned'', ids.id = 0,';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_collections label fragment not found exactly once'; end if;
  d := replace(d, a, b);
  a := 'bi.person_role_at(''collections_owner'', nullif(x->>''location_id'', '''')::int, null, current_date)';
  b := 'bi.person_role_at(''collections_owner'', case when nullif(x->>''location_id'', '''')::int = 0 then (select z.id from bi.location z where z.label = ''Mumbai'' limit 1) else nullif(x->>''location_id'', '''')::int end, null, current_date)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_collections owner fragment not found exactly once'; end if;
  execute replace(d, a, b);
end $mig$;
