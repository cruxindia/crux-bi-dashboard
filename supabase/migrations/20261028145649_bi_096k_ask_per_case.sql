-- Applied to Supabase project via MCP on 20261028145649
-- bi_096k (28-Oct-2026): "revenue per case vs rate" goes to the collections answer (per-case and rate comparison), not to revenue growth.
do $do$
declare d text; o text := $o$         and q !~ '(collect|outstanding|receivable|realis|realiz|overdue|\mcash\M|payment)' then 'revenue_growth'$o$;
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_ask3 fragment'; end if;
  execute replace(d, o, $n$         and q !~ '(collect|outstanding|receivable|realis|realiz|overdue|\mcash\M|payment|per case|\mrates?\M)' then 'revenue_growth'$n$);
end $do$;
