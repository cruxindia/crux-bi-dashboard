-- Applied to Supabase project via MCP on 20261107110856
-- Wave 100: the person-level split shows Force1 activity per named person; like the workforce view (wave 098), names are for
-- admins only. Viewers see each team's distribution with people numbered by rank ("Person 1" = most actions).
do $m$
declare d text := pg_get_functiondef('public.bi_call(text, jsonb)'::regprocedure);
begin
  if position('person-level split' in d) > 0 then return; end if;
  if position('  -- penalty reasons and names of who entered them: admins only' in d) = 0 then raise exception 'bi_call anchor not found'; end if;
  d := replace(d, '  -- penalty reasons and names of who entered them: admins only',
'  -- person-level split (Force1 activity per person): names for admins only, like the workforce view
  if p_fn = ''split'' and not v_admin and r->>''level'' = ''people'' then
    r := r || jsonb_build_object(''names_hidden'', true,
      ''members'', (select coalesce(jsonb_agg((x - ''member'') || jsonb_build_object(''member'', ''Person '' || (x->>''rank'')) order by o), ''[]''::jsonb) from jsonb_array_elements(r->''members'') with ordinality t(x, o)),
      ''groups'', (select coalesce(jsonb_agg((x - ''top1'' - ''carry50'') || jsonb_build_object(''top1'', ''Person 1'', ''carry50'', null) order by o), ''[]''::jsonb) from jsonb_array_elements(r->''groups'') with ordinality t(x, o)));
  end if;
  -- penalty reasons and names of who entered them: admins only');
  execute d;
end $m$;
