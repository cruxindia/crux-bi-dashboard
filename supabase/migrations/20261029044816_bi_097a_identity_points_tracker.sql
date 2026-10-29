-- Applied to Supabase project via MCP on 20261029044816
-- bi_097a (29-Oct-2026): canonical identity, part 1.
-- (1) Tracker labels: a known location label with a team / person suffix added ("Amaravati (Sudhir)") resolves to that location and is flagged for
--     review, instead of silently creating a new location without a zone; a genuinely new label keeps the zone the tracker gives it.
-- (2) Point Wise: a point follows its case only when the relationship is proven (the case exists in Case Wise and the point's branch is the case's
--     branch). Otherwise the point is placed on its own evidence — place in its branch name, its pincode, then its file's usual location — and the
--     exception is kept in bi.point_loc with basis and reason. The processing unit of a point is its own Point Wise file's unit (own evidence first).
create or replace function bi.resolve_location_suffix_base(p_label text) returns text language sql immutable as $f$
  select nullif(bi.norm(btrim(regexp_replace(coalesce(p_label, ''), '\s*[-–]?\s*\([^)]*\)\s*$', ''))), '') $f$;

do $do$
declare d text;
  o1 text := $o$  -- rule 3: genuinely new tracker location (tracker is authoritative) -> create, flag for review
  insert into bi.location(code,label,zone_group) values (v_alias,p_label,null) returning id into v_id;$o$;
  n1 text := $n$  -- rule 2b (bi_097a): an existing location's label with a team / person suffix added -> that location, flagged for review
  select la.location_id into v_id from bi.location_alias la
   where la.source = 'zonal_label' and la.review_status in ('confirmed', 'auto') and la.location_id is not null
     and la.alias = bi.resolve_location_suffix_base(p_label) and la.alias <> v_alias
   order by (la.review_status = 'confirmed') desc limit 1;
  if found then
    insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
    values ('zonal_label',v_alias,v_id,'team_suffix_removed',0.9,jsonb_build_object('batch',p_batch,'zone',p_zone,'base_label',bi.resolve_location_suffix_base(p_label)),'needs_review');
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'zonal',p_label,'location_label_team_suffix','warning',jsonb_build_object('location_id',v_id,'zone',p_zone,
            'action','mapped to the existing location of the same name; the suffix usually names the team — check the branch manager'));
    return v_id;
  end if;
  -- rule 3: genuinely new tracker location (tracker is authoritative) -> create with the tracker's zone, flag for review
  insert into bi.location(code,label,zone_group) values (v_alias,p_label,(select z.code from bi.zone_group z where bi.norm(z.label) = bi.norm(p_zone) limit 1)) returning id into v_id;$n$;
begin
  d := pg_get_functiondef('bi.resolve_location(text,text,bigint)'::regprocedure);
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'resolve_location fragment'; end if;
  execute replace(d, o1, n1);
end $do$;

create table if not exists bi.point_loc (
  point_id bigint primary key, location_id int references bi.location(id), basis text not null, case_location_id int, reason text not null,
  active boolean not null default true, run text, changed_at timestamptz not null default now());
alter table bi.point_loc enable row level security;
comment on table bi.point_loc is 'Points that do not follow their case (no matching case, or a different branch): location from the point''s own evidence, with basis and reason. Inactive rows are kept as history.';

create or replace function bi.point_locate_apply(p_run text default 'refresh', p_apply boolean default true) returns jsonb
 language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare r jsonb;
begin
  with ex as materialized (
    select p.point_id, p.branch_id, p.pincode, p.file_group, p.recon_unit, c.location_id cloc,
           case when c.case_id is null then 'no matching case in Case Wise' else 'point branch differs from its case' end reason
      from bi.point_store p left join bi.case_store c on c.case_id = p.case_id
     where c.case_id is null or (p.branch_id is not null and c.branch_id is not null and p.branch_id <> c.branch_id)),
  brp as materialized (select b.branch_id, bi.place_of_branch((select val from bi.dim where id = b.branch_id)) pl from (select distinct branch_id from ex where branch_id is not null) b),
  pnp as materialized (select z.pin, bi.place_of_pin(z.pin) pl from (select distinct pincode::text pin from ex where pincode between 100000 and 999999) z),
  k as materialized (select distinct v.pl, ex.file_group from ex left join brp on brp.branch_id = ex.branch_id left join pnp on pnp.pin = ex.pincode::text
                      cross join lateral (values (brp.pl), (pnp.pl)) v(pl) where v.pl is not null),
  kl as materialized (select k.pl, k.file_group, coalesce(bi.loc_of_place(k.pl, k.file_group), (select s.location_id from bi.ref_state_default s where upper(s.state) = upper(k.pl))) l from k),
  ud as materialized (select l.recon_unit, min(l.id) id from bi.location l where l.is_unit_default group by 1),
  res as materialized (
    select ex.point_id, coalesce(lb.l, lp.l, ud.id) loc,
           case when lb.l is not null then 'place in the point''s branch name' when lp.l is not null then 'point pincode table'
                when ud.id is not null then 'point file''s usual location' else 'not identified' end basis,
           ex.cloc, ex.reason
      from ex left join brp on brp.branch_id = ex.branch_id left join pnp on pnp.pin = ex.pincode::text
      left join kl lb on lb.pl = brp.pl and lb.file_group is not distinct from ex.file_group
      left join kl lp on lp.pl = pnp.pl and lp.file_group is not distinct from ex.file_group
      left join ud on ud.recon_unit = ex.recon_unit),
  ins as (
    insert into bi.point_loc(point_id, location_id, basis, case_location_id, reason, active, run, changed_at)
    select point_id, loc, basis, cloc, reason, true, p_run, now() from res where p_apply
    on conflict (point_id) do update set location_id = excluded.location_id, basis = excluded.basis, case_location_id = excluded.case_location_id,
           reason = excluded.reason, active = true, run = excluded.run, changed_at = now()
     where not bi.point_loc.active or (bi.point_loc.location_id, bi.point_loc.basis, bi.point_loc.case_location_id, bi.point_loc.reason)
           is distinct from (excluded.location_id, excluded.basis, excluded.case_location_id, excluded.reason)
    returning 1),
  off as (
    update bi.point_loc pl set active = false, run = p_run, changed_at = now()
     where p_apply and pl.active and not exists (select 1 from res x where x.point_id = pl.point_id)
    returning 1)
  select jsonb_build_object('exceptions', (select count(*) from res),
     'by_reason_basis', (select jsonb_agg(jsonb_build_object('reason', reason, 'basis', basis, 'points', n, 'differs_from_case_location', d) order by n desc)
                           from (select reason, basis, count(*) n, count(*) filter (where cloc is not null and loc is distinct from cloc) d from res group by 1, 2) z),
     'not_identified', (select count(*) from res where loc is null),
     'applied', p_apply, 'written', (select count(*) from ins), 'back_to_case', (select count(*) from off)) into r;
  return r;
end $f$;

-- v_point: point location = its case's location unless bi.point_loc holds an active exception; processing unit = the point file's own unit first
do $do$
declare d text;
begin
  d := pg_get_viewdef('bi.v_point'::regclass);
  if position('COALESCE(c.recon_unit, p.recon_unit) AS recon_unit' in d) = 0 or position('    c.location_id,' in d) = 0
     or position('LEFT JOIN bi.fact_case c ON ((c.case_id = p.case_id)))' in d) = 0 then raise exception 'v_point fragments not found'; end if;
  d := replace(d, 'COALESCE(c.recon_unit, p.recon_unit) AS recon_unit', 'COALESCE(p.recon_unit, c.recon_unit) AS recon_unit');
  d := replace(d, '    c.location_id,', '    CASE WHEN (pl.point_id IS NOT NULL) THEN pl.location_id ELSE c.location_id END AS location_id,');
  d := replace(d, 'LEFT JOIN bi.fact_case c ON ((c.case_id = p.case_id)))', 'LEFT JOIN bi.fact_case c ON ((c.case_id = p.case_id))) LEFT JOIN bi.point_loc pl ON (((pl.point_id = p.point_id) AND pl.active))');
  execute 'create or replace view bi.v_point as ' || d;
end $do$;

-- the scheduled point refresh places exception points first (bi.refresh_point_derived itself is unchanged)
do $do$
declare d text; o text := $o$  return bi.refresh_point_derived();$o$;
begin
  d := pg_get_functiondef('bi.refresh_if_stale()'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'refresh_if_stale fragment'; end if;
  execute replace(d, o, $n$  perform bi.point_locate_apply('refresh');
  return bi.refresh_point_derived();$n$);
end $do$;
