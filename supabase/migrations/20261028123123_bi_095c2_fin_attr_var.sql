-- Applied to Supabase project via MCP on 20261028123123
do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.fin_attr_refresh(bigint,bigint[])'::regprocedure);
  d := replace(replace(replace(d, ' n int; t0 timestamptz', ' v_n int; t0 timestamptz'), 'select count(*) into n from ins;', 'select count(*) into v_n from ins;'), '''rows'', n,', '''rows'', v_n,');
  if d !~ 'into v_n from ins' or d !~ '''rows'', v_n,' then raise exception 'patch failed'; end if;
  execute d;
end $do$;
