-- Applied to Supabase project via MCP on 20261029144421
-- Fix bi_098d: the exclusion table has a column "r", which collided with the function's result variable r. Aggregate in a subquery first.
do $mig$
declare d text; a text; b text;
begin
  d := pg_get_functiondef('bi.api_os_recon()'::regprocedure);
  a := 'from bi.fin_line_exclusion e where e.upload_id = u.id and e.kind = ''outstanding'');';
  b := 'from (select count(*) n, sum(x.amount) amount from bi.fin_line_exclusion x where x.upload_id = u.id and x.kind = ''outstanding'') e);';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'os fragment not found exactly once'; end if;
  d := replace(d, a, b);
  a := '''lines'', count(e.*), ''amount'', round(coalesce(sum(e.amount), 0), 2)';
  b := '''lines'', e.n, ''amount'', round(coalesce(e.amount, 0), 2)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'os fragment 2 not found exactly once'; end if;
  d := replace(d, a, b);
  d := replace(d, '(r->>''gross'')::numeric - coalesce(sum(e.amount), 0)', '(r->>''gross'')::numeric - coalesce(e.amount, 0)');
  d := replace(d, '(r->>''net'')::numeric - coalesce(sum(e.amount), 0)', '(r->>''net'')::numeric - coalesce(e.amount, 0)');
  execute d;

  d := pg_get_functiondef('bi.api_coll_recon()'::regprocedure);
  a := 'from bi.fin_line_exclusion e where e.upload_id = u.id and e.kind = ''collection'');';
  b := 'from (select count(*) n, sum(x.amount) amount from bi.fin_line_exclusion x where x.upload_id = u.id and x.kind = ''collection'') e);';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'coll fragment not found exactly once'; end if;
  d := replace(d, a, b);
  d := replace(d, '''rows'', count(e.*), ''amount'', round(coalesce(sum(e.amount), 0), 2)', '''rows'', e.n, ''amount'', round(coalesce(e.amount, 0), 2)');
  d := replace(d, '(r->>''bank_credit'')::numeric - coalesce(sum(e.amount), 0)', '(r->>''bank_credit'')::numeric - coalesce(e.amount, 0)');
  execute d;
end $mig$;
