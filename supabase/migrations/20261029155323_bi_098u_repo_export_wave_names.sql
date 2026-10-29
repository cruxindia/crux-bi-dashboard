-- Applied to Supabase project via MCP on 20261029155323
-- The GitHub sync exported only migrations named bi_*; wave 098b migrations 098l–098t were named without the prefix and were missed.
-- Export those wave-numbered names too (no data, schema only — same as every exported migration).
do $do$
declare src text; frag text := $q$where name like 'bi\_%'$q$; n int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p where p.proname = 'bi_repo_export' and p.pronamespace = 'public'::regnamespace;
  if position($q$name ~ '^0[0-9]{2}[a-z]_'$q$ in src) > 0 then return; end if;
  n := (length(src) - length(replace(src, frag, ''))) / length(frag);
  if n <> 1 then raise exception 'bi_repo_export filter found % times', n; end if;
  execute replace(src, frag, $q$where (name like 'bi\_%' or name ~ '^0[0-9]{2}[a-z]_')$q$);
end $do$;
