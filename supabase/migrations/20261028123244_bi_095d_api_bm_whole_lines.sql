-- Applied to Supabase project via MCP on 20261028123244
-- bi_095d (28-Oct-2026): branch-manager finance without sharing. Billed, collected and outstanding come from bi.fin_attr: each line counts whole for the
-- manager of its location × client on the line's date. A zone-level line (location not identified) counts for a manager only when every member
-- location × client of that family in the zone has that same manager (and no filter is set); otherwise it stays "not attributable".
do $do$
declare d text; a int; b int; o text; n text;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  a := position('  src as materialized (' in d);
  b := position('bi.fam_ok(a.client_code, f)),' in d);
  if a = 0 or b = 0 or b < a then raise exception 'api_bm anchors not found'; end if;
  b := b + length('bi.fam_ok(a.client_code, f)),');
  n := $n$  src as materialized (
    select a.kind, a.m, a.location_id, a.client_code, a.family, sum(a.amt) amt,
           case a.kind when 'billed' then (a.m + interval '1 month - 1 day')::date when 'collected' then least(v_thru, (a.m + interval '1 month - 1 day')::date) else v_at end at_
      from bi.fin_attr a
     where a.amt <> 0 and ((a.kind = 'billed' and a.m in (v_bc, v_bp)) or (a.kind = 'collected' and a.upload_id = any (v_co) and a.m in (v_rm, v_rmp))
                           or (a.kind = 'outstanding' and a.upload_id = v_os))
     group by 1, 2, 3, 4, 5),
  zl as materialized (
    select s.kind, s.m, s.location_id, s.family, min(mm.mgr) mgr, count(distinct mm.mgr) nm
      from src s join bi.location z on z.id = s.location_id and z.is_rollup
      join lateral (select coalesce(bi.branch_manager_code_at(l2.id, c2.code, s.at_), '(not mapped)') mgr
                      from bi.location l2 join bi.client c2 on c2.family = s.family
                     where l2.zone_group = bi.rollup_zone(s.location_id)
                       and exists (select 1 from hm h where h.location_id = l2.id and h.client_code = c2.code and h.month between (s.at_ - interval '3 months')::date and s.at_
                                     and coalesce(h.rev, 0) > 0)) mm on true
     group by 1, 2, 3, 4),
  src2 as materialized (
    select s.*, case when l.id is not null and not coalesce(l.is_rollup, false) and s.client_code <> '' then 'id'
                     when z.nm = 1 and not exists (select 1 from jsonb_each_text(coalesce(f, '{}'::jsonb)) e where coalesce(e.value, '') not in ('', '[]', 'null')) then 'zone_mgr'
                     else 'none' end st, z.mgr zmgr
      from src s left join bi.location l on l.id = s.location_id
      left join zl z on z.kind = s.kind and z.m = s.m and z.location_id = s.location_id and z.family = s.family),
  al as materialized (select kind, m, location_id, client_code, amt, st = 'zone_mgr' allocated, at_, case when st = 'zone_mgr' then zmgr end zmgr from src2 where st <> 'none'),
  una as (select kind, m, sum(amt) amt from src2 where st = 'none' group by 1, 2),
  alf as materialized (
    select a.kind, a.m, a.location_id, a.client_code, a.amt, a.allocated, a.at_, coalesce(a.zmgr, bi.branch_manager_code_at(a.location_id, a.client_code, a.at_), '(not mapped)') mgr
      from al a left join loc on loc.location_id = a.location_id
     where a.zmgr is not null or (loc.location_id is not null and bi.loc_ok(a.location_id, loc.recon_unit, f, a.at_) and bi.fam_ok(a.client_code, f))),$n$;
  d := substr(d, 1, a - 1) || n || substr(d, b);
  execute d;
end $do$;
