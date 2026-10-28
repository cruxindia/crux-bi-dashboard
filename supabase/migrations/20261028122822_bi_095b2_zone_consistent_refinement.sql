-- Applied to Supabase project via MCP on 20261028122822
-- bi_095b2: a specific row label refines a zone-level invoice prefix only inside the same zone (ledger and receipts); the label map is the first candidate
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.fin_os_lines(bigint)'::regprocedure);
  o := $o$select q.l0, q.loc, q.cl, q.br, q.sheet,
           bi.loc_refine(q.l0, array[bi.loc_of_place$o$;
  n := $n$select q.l0, q.loc, q.cl, q.br, q.sheet,
           bi.loc_refine(q.l0, array[(select lm.location_id from bi.fin_loc_map lm where lm.key_type = 'label' and lm.key = bi.fin_label(q.loc)), bi.loc_of_place$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fin_os_lines fragment'; end if;
  execute replace(d, o, n);
  d := pg_get_functiondef('bi.fin_receipts(bigint)'::regprocedure);
  o := $o$case when b.ll is not null and not exists (select 1 from bi.location z where z.id = b.ll and z.is_rollup) then b.ll end,$o$;
  n := $n$case when b.ll is not null and not exists (select 1 from bi.location z where z.id = b.ll and z.is_rollup) and (b.pl is null or bi.loc_refine(b.pl, array[b.ll]) is not null) then b.ll end,$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fin_receipts fragment 1'; end if;
  d := replace(d, o, n);
  o := $o$when b.ll is not null and not exists (select 1 from bi.location z where z.id = b.ll and z.is_rollup) then 'label'$o$;
  n := $n$when b.ll is not null and not exists (select 1 from bi.location z where z.id = b.ll and z.is_rollup) and (b.pl is null or bi.loc_refine(b.pl, array[b.ll]) is not null) then 'label'$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fin_receipts fragment 2'; end if;
  execute replace(d, o, n);
end $do$;
