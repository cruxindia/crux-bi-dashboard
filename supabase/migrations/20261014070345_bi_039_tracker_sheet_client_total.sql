-- Applied to Supabase project via MCP on 20261014070345
do $do$
declare d text := pg_get_functiondef('bi.api_tracker_sheet(date,jsonb,date,integer)'::regprocedure); d2 text;
begin
  d2 := replace(d, 'and lower(trim(l.client_label)) = lower(trim(coalesce(t.client_label, t.location_label)))',
    'and (lower(trim(coalesce(t.client_label, t.location_label))) = ''total'' or lower(trim(l.client_label)) = lower(trim(coalesce(t.client_label, t.location_label))))');
  if d2 = d then raise exception 'patch made no change'; end if;
  execute d2;
end $do$;
