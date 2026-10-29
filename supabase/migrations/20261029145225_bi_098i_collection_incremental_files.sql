-- Applied to Supabase project via MCP on 20261029145225
-- Wave 098: Finance may send receipt files as increments (only new receipts) or as a cumulative financial-year file.
-- A newer collection file replaces an earlier one only when it starts on or before the earlier file's first receipt (it covers it);
-- an increment is kept alongside, and a receipt present in both files is counted once (same fingerprint, as before).
do $mig$
declare d text := pg_get_functiondef('bi.fin_ingest_as(text,text,jsonb)'::regprocedure); a text; b text;
begin
  a := 'and bi.fin_fy(coalesce(period_from, as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of))
         and (as_of < u.as_of or (as_of = u.as_of and id < u.id));';
  b := 'and bi.fin_fy(coalesce(period_from, as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of))
         and (as_of < u.as_of or (as_of = u.as_of and id < u.id))
         and coalesce(u.period_from, u.as_of) <= coalesce(period_from, as_of);';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'supersede fragment 1 not found exactly once'; end if;
  d := replace(d, a, b);
  a := 'and bi.fin_fy(coalesce(o.period_from, o.as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of)) and o.as_of > u.as_of);';
  b := 'and bi.fin_fy(coalesce(o.period_from, o.as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of)) and o.as_of > u.as_of
                                     and coalesce(o.period_from, o.as_of) <= coalesce(u.period_from, u.as_of));';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'supersede fragment 2 not found exactly once'; end if;
  execute replace(d, a, b);
end $mig$;
