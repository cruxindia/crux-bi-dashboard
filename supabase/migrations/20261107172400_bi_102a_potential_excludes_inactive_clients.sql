-- Applied to Supabase project via MCP on 20261107172400
-- wave 102a (7-Nov-2026, owner decision): clients with no tracker cases anywhere in India in the last three months
-- (reference month included) are removed from potential and therefore from targets
do $m$
declare d text := pg_get_functiondef('bi.potential_refresh()'::regprocedure); o text := d;
begin
  d := replace(d, $a$    select distinct location_id, fam from _pair where now_cases > 0 or tgt > 0;
$a$, $a$    select distinct location_id, fam from _pair where now_cases > 0 or tgt > 0;

  -- wave 102a: client families with no tracker cases anywhere in India in the last three months are left out (owner, 7-Nov-2026)
  create temp table _inact on commit drop as
    select f.fam from (select fam from _uni union select fam from _pair) f
     where not exists (select 1 from _pm p where p.fam = f.fam and p.month >= (v_m - interval '2 months')::date and p.cases > 0);
$a$);
  d := replace(d, $a$    from x left join _rate r on r.location_id = x.location_id and r.fam = x.fam left join _frate fr on fr.fam = x.fam;$a$,
                  $a$    from x left join _rate r on r.location_id = x.location_id and r.fam = x.fam left join _frate fr on fr.fam = x.fam
   where not exists (select 1 from _inact i where i.fam = x.fam);$a$);
  d := replace(d, $a$   where greatest(g.r - coalesce(d.r, 0), 0) > 0;$a$,
                  $a$   where greatest(g.r - coalesce(d.r, 0), 0) > 0 and not exists (select 1 from _inact i where i.fam = g.fam);$a$);
  d := replace(d, $a$          'source_version', v_src))$a$,
                  $a$          'source_version', v_src, 'inactive_clients', (select coalesce(jsonb_agg(fam order by fam), '[]'::jsonb) from _inact)))$a$);
  if (length(d) - length(o)) < 400 or position('_inact i where i.fam = g.fam' in d) = 0 or position('_inact i where i.fam = x.fam' in d) = 0 or position('''inactive_clients''' in d) = 0 then
    raise exception 'potential_refresh: an anchor was not found';
  end if;
  execute d;

  d := pg_get_functiondef('bi.api_market_potential(date, jsonb)'::regprocedure); o := d;
  d := replace(d, 'Potential = current business + headroom. Universe:',
    'Potential = current business + headroom. Clients with no tracker cases anywhere in India in the last three months are left out (owner decision 7-Nov-2026; listed in inputs.inactive_clients). Universe:');
  if d = o then raise exception 'api_market_potential: method anchor not found'; end if;
  execute d;
end $m$;
