-- Applied to Supabase project via MCP on 20261028123427
-- bi_095e2: an interrupted upload of the same file can be begun again (the content check overwrote FOUND, so the retry tried a second insert)
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.fin_ingest_as(text,text,jsonb)'::regprocedure);
  o := $o$    if found then
      update bi.fin_upload set status = 'staging', file_name = p->>'file_name'$o$;
  n := $n$    if u.id is not null then
      update bi.fin_upload set status = 'staging', file_name = p->>'file_name'$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fin_ingest_as begin fragment'; end if;
  execute replace(d, o, n);
end $do$;
