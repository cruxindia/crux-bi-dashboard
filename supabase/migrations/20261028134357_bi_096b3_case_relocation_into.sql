-- Applied to Supabase project via MCP on 20261028134357
do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.case_relocate_apply(text,bigint[])'::regprocedure);
  d := replace(d, ', (select count(*) from lg) * 0
    into v_n, v_m, v_b;', '
    into v_n, v_m, v_b;');
  if d ~ 'count\(\*\) from lg' then raise exception 'not patched'; end if;
  execute d;
end $do$;
