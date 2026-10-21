-- Applied to Supabase project via MCP on 20261021121735
-- bi_090j (21-Oct-2026): "how much does X owe" / dues questions go to the collections handler
do $do$
declare d text := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure); o text := $x$|per case|billing gap|unbilled)' then 'collections'$x$;
begin
  if position('pending payment' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'collections intent pattern not found once'; end if;
  execute replace(d, o, $x$|per case|billing gap|unbilled|\mowes?\M|\mowed\M|\mdues\M|pending payment|receivable)' then 'collections'$x$);
end $do$;
