-- Applied to Supabase project via MCP on 20261013071746
do $do$ declare d text; a text := $x$tpl as (select bi.matrix_template(coalesce((select min(dt) from dates where status in ('missing','draft')), p_to + 1)) t),$x$; begin
 d := pg_get_functiondef('bi.api_matrix(date,date)'::regprocedure);
 if position(a in d)=0 then raise exception 'pattern'; end if;
 d := replace(d, a, $x$tpl as (select bi.matrix_template(p_to + 1) t),$x$);
 execute d; end $do$;
