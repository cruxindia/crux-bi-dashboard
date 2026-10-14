-- Applied to Supabase project via MCP on 20261014234338
-- bi_082: (1) api_potential evaluates the effective-dated location filter once per location and report date instead of once per
-- tracker row (same result, verified equal on 11 filter/grouping/month/measure combinations; ~7x faster with a zone, region or
-- stakeholder filter). (2) api_drill also returns the organic comparison to date, matching the Overview tile.
do $$
declare d text := pg_get_functiondef('bi.api_potential(date,jsonb,text,text)'::regprocedure);
  old1 text := $o$and bi.loc_ok(x.location_id, l.recon_unit, f, x.snapshot_date) and bi.fam_ok(x.client_code, f)),$o$;
  new1 text := $n$and (coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb or (x.location_id, x.snapshot_date) in (select ok.location_id, ok.d from okset ok)) and bi.fam_ok(x.client_code, f)),$n$;
  old2 text := $o$with leaf as (select x.snapshot_date d,$o$;
  new2 text := $n$with okset as materialized (select z.location_id, z.d from (select distinct x2.location_id, x2.snapshot_date d from bi.v_zt_leaf x2 where x2.report_month <= m and x2.report_month >= (m - interval '12 months')::date and coalesce(f, '{}'::jsonb) - 'client_family' <> '{}'::jsonb) z join bi.location l2 on l2.id = z.location_id where bi.loc_ok(z.location_id, l2.recon_unit, f, z.d)),
  leaf as (select x.snapshot_date d,$n$;
begin
  if position('okset' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, old1, ''))) / length(old1) <> 1 or (length(d) - length(replace(d, old2, ''))) / length(old2) <> 1 then raise exception 'api_potential anchors not unique'; end if;
  execute replace(replace(d, old1, new1), old2, new2);
end $$;

do $$
declare d text := pg_get_functiondef('bi.api_drill(date,jsonb,text,jsonb)'::regprocedure);
  anchor text := $a$'children', kids,$a$;
  addition text := $s$'children', kids, 'organic', (select o->'total' || jsonb_build_object('complete', o->'complete', 'as_of', o->'as_of') from (select bi.api_organic(m, f, 'total') o) x),$s$;
begin
  if position('''organic''' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then raise exception 'api_drill anchor not unique'; end if;
  execute replace(d, anchor, addition);
end $$;

-- cached drill results were built without the organic comparison: start a new cache version
insert into bi.audit_log(actor, action, entity, detail) values ('migration:bi_082', 'cache_refresh', 'api_cache', '{"reason":"api_drill returns organic to date"}');
