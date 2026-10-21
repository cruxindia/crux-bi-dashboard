-- Applied to Supabase project via MCP on 20261021114843
-- bi_090e (21-Oct-2026): expose the finance API through bi_call (aggregates cached like every other read; records and review queue admin-only)
do $do$
declare d text := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure); n int;
begin
  if position('api_collections' in d) > 0 then return; end if;
  n := (length(d) - length(replace(d, $a$if p_fn in ('exceptions','mapping_queue','branch_reviews') then$a$, ''))) / length($a$if p_fn in ('exceptions','mapping_queue','branch_reviews') then$a$);
  if n <> 1 then raise exception 'admin list fragment found % times', n; end if;
  d := replace(d, $a$if p_fn in ('exceptions','mapping_queue','branch_reviews') then$a$, $a$if p_fn in ('exceptions','mapping_queue','branch_reviews','fin_review','fin_records') then$a$);
  n := (length(d) - length(replace(d, $a$return case p_fn when 'exceptions' then bi.api_exceptions()$a$, ''))) / length($a$return case p_fn when 'exceptions' then bi.api_exceptions()$a$);
  if n <> 1 then raise exception 'admin case fragment found % times', n; end if;
  d := replace(d, $a$return case p_fn when 'exceptions' then bi.api_exceptions()$a$,
                  $a$return case p_fn when 'exceptions' then bi.api_exceptions() when 'fin_review' then bi.api_fin_review(coalesce(p_args->'p', '{}'::jsonb)) when 'fin_records' then bi.api_fin_records(coalesce(p_args->'p', '{}'::jsonb))$a$);
  n := (length(d) - length(replace(d, $a$when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)$a$, ''))) / length($a$when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)$a$);
  if n <> 1 then raise exception 'expense fragment found % times', n; end if;
  d := replace(d, $a$when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)$a$,
                  $a$when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)
      when 'collections' then bi.api_collections(m, f)$a$);
  execute d;
end $do$;

do $do$ begin
  if not exists (select 1 from cron.job where jobname = 'bi-fin-derive') then
    perform cron.schedule('bi-fin-derive', '4-59/10 * * * *', $c$set statement_timeout = '170s'; select bi.fin_derive_if_stale()$c$);
  end if;
end $do$;
