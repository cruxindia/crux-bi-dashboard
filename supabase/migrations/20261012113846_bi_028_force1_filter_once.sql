-- Applied to Supabase project via MCP on 20261012113846
do $do$ declare d text; a text; b text; c text; begin
 d := pg_get_functiondef('bi.api_force1(date,jsonb)'::regprocedure);
 a := 'with g as (';
 b := $x$gf as (select * from g where bi.loc_ok(location_id, recon_unit, f) and bi.fam_ok(client_code, f)),$x$;
 c := $x$and bi.loc_ok(location_id, recon_unit, f) and bi.fam_ok(client_code, f)),$x$;
 if position(a in d)=0 or position(b in d)=0 or position(c in d)=0 then raise exception 'pattern missing'; end if;
 d := replace(d, a, $x$with lok as (select location_id, recon_unit from (select distinct location_id, recon_unit from bi.point_derived) x
                 where bi.loc_ok(location_id, recon_unit, f)),
cok as (select code from bi.client where bi.fam_ok(code, f)),
g as ($x$);
 d := replace(d, b, $x$gf as (select g.* from g join lok on lok.location_id is not distinct from g.location_id and lok.recon_unit is not distinct from g.recon_unit
           where (f->>'client_family' is null or g.client_code in (select code from cok))),$x$);
 d := replace(d, c, $x$and exists (select 1 from lok where lok.location_id is not distinct from point_derived.location_id and lok.recon_unit is not distinct from point_derived.recon_unit)
          and (f->>'client_family' is null or client_code in (select code from cok))),$x$);
 execute d;
end $do$;
