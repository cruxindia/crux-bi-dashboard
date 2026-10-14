-- Applied to Supabase project via MCP on 20261014081722
-- bi_047: attrition leaver names visible to admins only (public view keeps role, location, exit date, workload)
do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('leaver names' in d) = 0 then
    d := replace(d, '  if p_fn = ''meta'' then r := r || jsonb_build_object(''role''',
      '  -- leaver names are HR data: admins only' || chr(10) ||
      '  if p_fn = ''attrition'' and not v_admin and jsonb_typeof(r->''leavers'') = ''array'' then' || chr(10) ||
      '    r := jsonb_set(r, ''{leavers}'', (select coalesce(jsonb_agg((x - ''name'') || jsonb_build_object(''name'', ''(admin only)'') order by o), ''[]''::jsonb) from jsonb_array_elements(r->''leavers'') with ordinality t(x, o)));' || chr(10) ||
      '    r := r || jsonb_build_object(''names_hidden'', true);' || chr(10) ||
      '  end if;' || chr(10) ||
      '  if p_fn = ''meta'' then r := r || jsonb_build_object(''role''');
    if position('leaver names' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;
