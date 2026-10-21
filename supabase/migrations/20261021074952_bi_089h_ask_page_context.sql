-- Applied to Supabase project via MCP on 20261021074952
-- bi_089h: "here / this page" questions are answered for the page the user is on
do $do$
declare d text := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure); a text; b text;
begin
  a := $a$    when q ~ '(collect|outstanding|receivable|invoice|realis|realiz|payment|overdue|debtor|billing|billed|cash)' then 'collections'$a$;
  b := a || $b$
    when q ~ '\m(here|this page|this section|this screen)\M' and sec in ('tat', 'force1', 'force', 'quality', 'health', 'growth', 'tracker')
      then case sec when 'tat' then 'tat' when 'force1' then 'force1' when 'force' then 'force1_recon' when 'quality' then 'health' when 'health' then 'health' else 'growth' end$b$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'anchor'; end if;
  execute replace(d, a, b);
end $do$;
