-- Applied to Supabase project via MCP on 20261029050423
-- bi_097d3 (29-Oct-2026): test I07 uses the area-office values that occur in Case Wise ("PUNE EAST / WEST / CITY ZONE").
do $do$
declare d text; o text := $o$where upper(btrim(d.val)) = 'PUNE EAST' and$o$;
begin
  d := pg_get_functiondef('bi.test_identity()'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'test_identity fragment'; end if;
  d := replace(d, o, $n$where upper(btrim(d.val)) in ('PUNE EAST ZONE', 'PUNE WEST ZONE', 'PUNE CITY ZONE') and$n$);
  d := replace(d, $o$I07 Case Wise records: a case whose area office is "PUNE EAST" and$o$, $n$I07 Case Wise records: a case whose area office is "PUNE EAST / WEST / CITY ZONE" and$n$);
  execute d;
end $do$;
