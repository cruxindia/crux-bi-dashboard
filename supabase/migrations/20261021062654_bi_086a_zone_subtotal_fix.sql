-- Applied to Supabase project via MCP on 20261021062654
-- bi_086a (21-Oct-2026): zone sub-total rows read as locations in the 19-Oct tracker (AUDIT_REGISTER A1)
-- The 19-Oct workbook carries zone rows ("Gujarat Zone", "Rest Of Maharashtra Zone", ...) as values instead of SUMIF formulas,
-- so they were typed as location rows and six pseudo-locations (ids 46-51) were created. Effect: MTD 57,464 instead of the
-- sheet's own 33,977; target 1,43,140 instead of 84,395; monthly history Apr-24 -> Sep-26 inflated (Sep-26 98,062 instead of 58,065).
-- Correction is reversible (row types and flags only); nothing is removed.

alter table bi.location add column if not exists is_rollup boolean not null default false;
alter table bi.location add column if not exists rollup_zone text;
comment on column bi.location.is_rollup is 'true = a zone sub-total label that was once read as a location; never a leaf location';

-- 1. flag the pseudo-locations, but only where every client row equals the sum of that zone's location rows (verified, else abort)
do $$
declare r record; bad int;
begin
  for r in select l.id, l.label, z.code from bi.location l join bi.zone_group z on bi.norm(z.label) = bi.norm(l.label)
           where l.id between 46 and 51 and l.zone_group is null loop
    select count(*) into bad from
      (select client_code, sum(mtd_cases) mtd, sum(target_cases) tgt from bi.zt_row where snapshot_date = '2026-10-19' and location_id = r.id group by 1) a
      full join (select x.client_code, sum(x.mtd_cases) mtd, sum(x.target_cases) tgt from bi.zt_row x join bi.location l2 on l2.id = x.location_id
                 where x.snapshot_date = '2026-10-19' and x.row_type = 'leaf' and l2.zone_group = r.code group by 1) b using (client_code)
     where coalesce(a.mtd, 0) <> coalesce(b.mtd, 0) or coalesce(a.tgt, 0) <> coalesce(b.tgt, 0);
    if bad > 0 then raise exception 'location % (%) is not an exact sub-total of zone % — correction stopped', r.id, r.label, r.code; end if;
    update bi.location set is_rollup = true, rollup_zone = r.code where id = r.id;
  end loop;
end $$;

-- 2. re-type their 19-Oct rows as zone roll-ups (the replica view still shows them, as roll-ups)
update bi.zt_row set row_type = 'zone_client_rollup'
 where snapshot_date = '2026-10-19' and row_type = 'leaf' and location_id in (select id from bi.location where is_rollup);

-- 3. derived organic values computed for the pseudo-locations are invalid (recomputed values never include them again)
update bi.organic_store set organic = null, v1 = null, v2 = null, v3 = null, computed_at = now()
 where location_id in (select id from bi.location where is_rollup);

-- 4. history and leaf views never include sub-total pseudo-locations
create or replace view bi.v_zt_leaf as
 SELECT r.snapshot_date, s.report_month, r.location_id, r.client_code,
    sum(r.target_cases) AS target_cases, sum(r.mtd_cases) AS mtd_cases, sum(r.revenue_target) AS revenue_target, sum(r.revenue_actual) AS revenue_actual,
    max(r.rate) AS rate, sum(r.bd_revenue) AS bd_revenue, sum(r.src_daily_value) AS src_daily_cases, count(*) AS source_rows
   FROM bi.zt_row r JOIN bi.zt_snapshot s USING (snapshot_date)
  WHERE r.row_type = 'leaf'::text AND r.location_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM bi.location lx WHERE lx.id = r.location_id AND lx.is_rollup)
  GROUP BY r.snapshot_date, s.report_month, r.location_id, r.client_code;

create or replace view bi.v_month_business as
 WITH snap AS (
         SELECT l.report_month AS month, l.location_id, l.client_code, l.target_cases, l.mtd_cases, l.revenue_target, l.revenue_actual, l.snapshot_date
           FROM bi.v_zt_leaf l JOIN bi.v_latest_snapshot ls ON ls.report_month = l.report_month AND ls.snapshot_date = l.snapshot_date
        ), hist AS (
         SELECT h.* FROM bi.zt_month_history h
          WHERE NOT EXISTS (SELECT 1 FROM bi.location lx WHERE lx.id = h.location_id AND lx.is_rollup)
        )
 SELECT COALESCE(h.month, s.month) AS month, COALESCE(h.location_id, s.location_id) AS location_id, COALESCE(h.client_code, s.client_code) AS client_code,
    COALESCE(h.cases, s.mtd_cases) AS cases, COALESCE(h.revenue, s.revenue_actual) AS revenue, h.billing, s.target_cases, s.revenue_target,
        CASE WHEN h.month IS NOT NULL THEN 'tracker_history'::text ELSE 'tracker_snapshot'::text END AS cases_source,
    COALESCE(s.snapshot_date, h.source_snapshot) AS as_of, s.mtd_cases AS month_end_snapshot_mtd
   FROM hist h FULL JOIN snap s ON s.month = h.month AND s.location_id = h.location_id AND s.client_code = h.client_code;

-- 5. prevention at import: a zone label is never turned into a new location ...
create or replace function bi.resolve_location(p_label text, p_zone text, p_batch bigint)
 returns integer language plpgsql security definer set search_path to 'bi', 'public', 'extensions' as $function$
declare v_id int; v_sim numeric; v_alias text := bi.norm(p_label);
begin
  if v_alias is null then return null; end if;
  select location_id into v_id from bi.location_alias where source='zonal_label' and alias=v_alias and review_status <> 'rejected';
  if found then return v_id; end if;
  -- rule 0 (bi_086a): a label equal to a zone name, with no location of that exact name, is a zone sub-total, not a location
  if exists (select 1 from bi.zone_group z where bi.norm(z.label) = v_alias)
     and not exists (select 1 from bi.location l where bi.norm(l.label) = v_alias and not l.is_rollup) then
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'zonal',p_label,'zone_subtotal_row','info',jsonb_build_object('zone',p_zone,'action','treated as zone roll-up, not a location'));
    return null;
  end if;
  -- rule 1: G->J corruption (observed 2026-07-06)
  select la.location_id into v_id from bi.location_alias la
   where la.source='zonal_label' and la.review_status <> 'rejected' and bi.norm_gj(la.alias) = bi.norm_gj(p_label) limit 1;
  if found then
    insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
    values ('zonal_label',v_alias,v_id,'g_j_typo_normalisation',0.95,jsonb_build_object('batch',p_batch,'zone',p_zone),'auto');
    return v_id;
  end if;
  -- rule 2: trigram similarity against known aliases
  select la.location_id, similarity(la.alias, v_alias) into v_id, v_sim from bi.location_alias la
   where la.source='zonal_label' and la.review_status <> 'rejected' order by similarity(la.alias, v_alias) desc limit 1;
  if v_sim >= 0.6 then
    insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
    values ('zonal_label',v_alias, case when v_sim>=0.85 then v_id end,'trigram',round(v_sim,3),
            jsonb_build_object('batch',p_batch,'zone',p_zone,'candidate_location_id',v_id),
            case when v_sim>=0.85 then 'auto' else 'needs_review' end);
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'zonal',p_label,'location_alias_auto_matched', case when v_sim>=0.85 then 'info' else 'warning' end,
            jsonb_build_object('candidate_location_id',v_id,'similarity',round(v_sim,3)));
    return case when v_sim>=0.85 then v_id end;
  end if;
  -- rule 3: genuinely new tracker location (tracker is authoritative) -> create, flag for review
  insert into bi.location(code,label,zone_group) values (v_alias,p_label,null) returning id into v_id;
  insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
  values ('zonal_label',v_alias,v_id,'new_from_tracker',1,jsonb_build_object('batch',p_batch,'zone',p_zone),'needs_review');
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
  values (p_batch,'zonal',p_label,'new_location_created','warning',jsonb_build_object('location_id',v_id,'zone',p_zone));
  return v_id;
end $function$;

-- ... a row that resolves to a sub-total label is stored as a roll-up, never as a location row ...
create or replace function bi.zt_row_guard() returns trigger language plpgsql security definer set search_path to 'bi', 'public' as $$
begin
  if new.row_type = 'leaf' and (
       (new.location_id is not null and exists (select 1 from bi.location l where l.id = new.location_id and l.is_rollup))
    or (new.location_id is null and exists (select 1 from bi.zone_group z where bi.norm(z.label) = bi.norm(new.location_label)))) then
    new.row_type := 'zone_client_rollup';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'zt_row_guard' and tgrelid = 'bi.zt_row'::regclass) then
    create trigger zt_row_guard before insert on bi.zt_row for each row execute function bi.zt_row_guard();
  end if;
end $$;
