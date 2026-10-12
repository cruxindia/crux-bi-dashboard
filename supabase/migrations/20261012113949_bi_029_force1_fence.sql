-- Applied to Supabase project via MCP on 20261012113949
do $do$ declare d text; a text := $x$(select distinct location_id, recon_unit from bi.point_derived) x$x$; begin
 d := pg_get_functiondef('bi.api_force1(date,jsonb)'::regprocedure);
 if position(a in d)=0 then raise exception 'pattern missing'; end if;
 d := replace(d, a, $x$(select distinct location_id, recon_unit from bi.point_derived offset 0) x$x$);
 execute d;
end $do$;
