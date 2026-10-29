-- Applied to Supabase project via MCP on 20261029153516
do $do$
declare src text; frag text := $q$'action', 'Review public Lumen functions callable without sign-in (for example reset_data)', 'who', 'Owner / Lumen', 'why', 'Security: the public key can call them'$q$; n int;
begin
  select pg_get_functiondef('bi.api_db_health()'::regprocedure) into src;
  n := (length(src) - length(replace(src, frag, ''))) / length(frag);
  if n = 1 then
    execute replace(src, frag, $q$'action', 'Run supabase/owner/owner_lumen_removal.sql (Lumen tables and functions were moved out of the API on 29-Oct-2026; anon can no longer call reset_data)', 'who', 'Owner', 'why', 'Finish the owner-approved Lumen removal; frees about 11 MB of file storage'$q$);
  elsif position('owner_lumen_removal.sql (Lumen tables' in src) = 0 then
    raise exception 'api_db_health action found % times', n;
  end if;
end $do$;
