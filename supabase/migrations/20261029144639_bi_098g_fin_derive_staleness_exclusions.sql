-- Applied to Supabase project via MCP on 20261029144639
-- Wave 098: a new duplicate exclusion also makes the finance figures stale (re-derived by cron bi-fin-derive).
do $mig$
declare d text := pg_get_functiondef('bi.fin_derive_if_stale()'::regprocedure);
        a text := 'coalesce((select max(updated_at) from bi.fin_config), ''-infinity''))';
        b text := 'coalesce((select max(updated_at) from bi.fin_config), ''-infinity''), coalesce((select max(approved_at) from bi.fin_line_exclusion), ''-infinity''))';
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'fin_derive_if_stale fragment not found exactly once'; end if;
  execute replace(d, a, b);
end $mig$;
