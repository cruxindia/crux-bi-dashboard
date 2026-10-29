-- Applied to Supabase project via MCP on 20261029153449
do $do$
declare src text; frag text := $q$'owner_app', 'Lumen bill extractor (keep)'$q$; n int;
begin
  select pg_get_functiondef('bi.api_db_health()'::regprocedure) into src;
  n := (length(src) - length(replace(src, frag, ''))) / length(frag);
  if n = 1 then
    execute replace(src, frag, $q$'owner_app', 'Lumen — not used by the dashboard; quarantined 29-Oct-2026, removal by supabase/owner/owner_lumen_removal.sql'$q$);
  elsif position('quarantined 29-Oct-2026' in src) = 0 then
    raise exception 'api_db_health label found % times', n;
  end if;
end $do$;
