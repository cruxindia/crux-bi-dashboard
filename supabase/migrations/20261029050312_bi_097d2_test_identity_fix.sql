-- Applied to Supabase project via MCP on 20261029050312
-- bi_097d2 (29-Oct-2026): bi.loc_of_payer returns rows; read its first row in test I12.
do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.test_identity()'::regprocedure);
  if (length(d) - length(replace(d, $o$(bi.loc_of_payer('BOM', '2483', null)).location_id$o$, ''))) / length($o$(bi.loc_of_payer('BOM', '2483', null)).location_id$o$) <> 2 then raise exception 'test_identity fragment'; end if;
  execute replace(d, $o$(bi.loc_of_payer('BOM', '2483', null)).location_id$o$, $n$(select x.location_id from bi.loc_of_payer('BOM', '2483', null) x limit 1)$n$);
end $do$;
