-- Applied to Supabase project via MCP on 20261014165725
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_ask(text,jsonb,uuid)'::regprocedure);
  -- 1) zone names in the question ("Gujarat", "Hyderabad zone") set a zone filter when no location matched
  d2 := replace(d, 'loc record; fam text;', 'loc record; fam text; zg text; scope text;');
  d2 := replace(d2, $o$  if loc.id is not null then f := f || jsonb_build_object('location_id', loc.id); end if;$o$,
    $n$  if loc.id is not null then f := f || jsonb_build_object('location_id', loc.id);
  else
    select z.code into zg from bi.zone_group z
     where length(split_part(regexp_replace(z.label,'[^A-Za-z ]',' ','g'),' ',1)) >= 4
       and lower(split_part(regexp_replace(z.label,'[^A-Za-z ]',' ','g'),' ',1)) not in ('rest')
       and q ~ ('\m' || lower(split_part(regexp_replace(z.label,'[^A-Za-z ]',' ','g'),' ',1)) || '\M')
     order by length(z.label) limit 1;
    if zg is not null then f := f || jsonb_build_object('zone_group', zg); end if;
  end if;$n$);
  -- 2) every answer states its scope, so a whole-company figure is never read as one place's figure
  d2 := replace(d2, $o$  a := jsonb_build_object('conversation_id', conv, 'intent', intent, 'answer', txt,$o$,
    $n$  scope := case when f - 'client_family' = '{}'::jsonb then 'All locations'
                 else concat_ws(', ', (select label from bi.location where id = nullif(f->>'location_id','')::int), (select label from bi.zone_group where code = f->>'zone_group'),
                                case when f ? 'region' then 'Region ' || (f->>'region') end, case when f ? 'stakeholder' then 'Stakeholder filter' end) end
             || case when f ? 'client_family' then ' · client ' || (f->>'client_family') else ' · all clients' end;
  txt := 'Scope: ' || scope || '. ' || txt;
  a := jsonb_build_object('conversation_id', conv, 'intent', intent, 'scope', scope, 'answer', txt,$n$);
  if position('zone_group'', zg' in d2) = 0 or position('''scope'', scope' in d2) = 0 then raise exception 'anchor'; end if;
  execute d2;
end $$;
