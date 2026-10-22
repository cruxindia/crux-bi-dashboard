-- Applied to Supabase project via MCP on 20261022093709
-- bi_093f2 (22-Oct-2026): a local variable named F shadowed the filters parameter f (PL/pgSQL names are case-insensitive): renamed to fk
do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.ask_h_revenue(date,jsonb,text)'::regprocedure);
  if position('ord text; F text; u text;' in d) = 0 then raise exception 'declaration not found'; end if;
  d := replace(d, 'ord text; F text; u text;', 'ord text; fk text; u text;');
  d := replace(d, $q$F := 'inr';$q$, $q$fk := 'inr';$q$);
  d := replace(d, $q$F := 'n';$q$, $q$fk := 'n';$q$);
  d := replace(d, $q$when F = 'inr'$q$, $q$when fk = 'inr'$q$);
  if d ~ '\mF\M' then raise exception 'F still referenced'; end if;
  execute d;
end $do$;
