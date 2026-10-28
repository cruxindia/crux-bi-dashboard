-- Applied to Supabase project via MCP on 20261028123355
-- bi_095e: collection uploads may carry the payer identity columns (pbc payer branch code / IFSC, pbn payer branch name, ir invoice number quoted in
-- the narration). The 13-column layout of earlier files stays accepted.
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.fin_ingest_as(text,text,jsonb)'::regprocedure);
  o := $o$else array['r','loc','bank','rm','d','amt','cl','br','inv','basic','im','ims','h'] end;$o$;
  n := $n$when v_cols = array['r','loc','bank','rm','d','amt','cl','br','inv','basic','im','ims','h','pbc','pbn','ir'] then v_cols
                  else array['r','loc','bank','rm','d','amt','cl','br','inv','basic','im','ims','h'] end;$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fin_ingest_as fragment'; end if;
  execute replace(d, o, n);
end $do$;
