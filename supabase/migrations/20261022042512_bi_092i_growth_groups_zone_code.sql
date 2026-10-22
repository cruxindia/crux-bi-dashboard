-- Applied to Supabase project via MCP on 20261022042512
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth(date,jsonb,jsonb)'::regprocedure);
  o := array[$o0$  keys as materialized (select distinct location_id, fam from pp where coalesce(c1, 0) > 0 or coalesce(c0, 0) > 0),$o0$,
$o1$    'net', (select to_jsonb(net) from net),$o1$];
  n := array[$n0$  grp as materialized (
    select case p->>'group' when 'client' then coalesce(fr.display_name, cl.label, k.fam) when 'location' then loc.label
                when 'zone' then coalesce((select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(k.location_id, 'zone_group', (v_cm + interval '1 month - 1 day')::date)), '(no zone)')
                when 'stakeholder' then coalesce(bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm + interval '1 month - 1 day')::date), '(not mapped)')
                when 'region' then coalesce(loc.region, '(none)') end g,
           k.pid, sum(k.c1) c1, sum(k.c0) c0, sum(coalesce(k.c1, 0)) filter (where k.cov) c1c, sum(coalesce(k.c0, 0)) filter (where k.cov) c0c,
           sum(k.o1) filter (where k.cov) o1c, sum(k.o0) filter (where k.cov) o0c, count(*) n
    from pp k join loc on loc.location_id = k.location_id left join bi.client cl on cl.code = k.fam left join bi.client_family_research fr on fr.family = k.fam
    where p->>'group' in ('client', 'location', 'zone', 'stakeholder', 'region') group by 1, 2),
  keys as materialized (select distinct location_id, fam from pp where coalesce(c1, 0) > 0 or coalesce(c0, 0) > 0),$n0$,
$n1$    'net', (select to_jsonb(net) from net), 'group', coalesce(p->>'group', 'pair'),
    'groups', case when p->>'group' in ('client', 'location', 'zone', 'stakeholder', 'region') then (select coalesce(jsonb_agg(jsonb_build_object('group', g.g, 'id', g.pid,
                  'cur', g.c1, 'prev', g.c0, 'chg', coalesce(g.c1, 0) - coalesce(g.c0, 0), 'pct', bi.pct_chg(g.c1, g.c0, v_minc),
                  'org_cur', round(g.o1c), 'org_prev', round(g.o0c), 'beyond', round((g.c1c - g.c0c) - (g.o1c - g.o0c)),
                  'effort_cur', round(g.c1c - g.o1c), 'effort_prev', round(g.c0c - g.o0c), 'covered_cur', g.c1c, 'covered_prev', g.c0c, 'pairs', g.n)
                  order by g.pid, coalesce(g.c1, 0) - coalesce(g.c0, 0) desc), '[]') from grp g) end,$n1$];
  for i in 1 .. array_length(o, 1) loop
    if position(o[i] in d) = 0 then raise exception 'api_growth fragment % not found', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth_rev(date,jsonb,jsonb)'::regprocedure);
  o := array[$o0$           array_agg(distinct l.recon_unit) filter (where u.is_member and l.recon_unit is not null) units$o0$,
$o1$    select k.unit_id, k.fam, ua.label, ua.zl, ua.members, ua.owners, ua.owners_prev, ua.zone, ua.region, ua.member_labels,$o1$,
$o2$    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11),$o2$,
$o3$        'zone', r.zone, 'region', r.region, 'client', r.fam, 'client_label', r.fam_label,$o3$];
  n := array[$n0$           array_agg(distinct l.recon_unit) filter (where u.is_member and l.recon_unit is not null) units,
           max(l.rollup_zone) filter (where not u.is_member) zone_code$n0$,
$n1$    select k.unit_id, k.fam, ua.label, ua.zl, ua.members, ua.owners, ua.owners_prev, ua.zone, ua.region, ua.member_labels, ua.zone_code,$n1$,
$n2$    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12),$n2$,
$n3$        'zone', r.zone, 'zone_code', r.zone_code, 'region', r.region, 'client', r.fam, 'client_label', r.fam_label,$n3$];
  for i in 1 .. array_length(o, 1) loop
    if position(o[i] in d) = 0 then raise exception 'api_growth_rev fragment % not found', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;

