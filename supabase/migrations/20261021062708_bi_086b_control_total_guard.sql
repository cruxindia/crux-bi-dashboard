-- Applied to Supabase project via MCP on 20261021062708
-- bi_086b (21-Oct-2026): a tracker snapshot whose location rows do not add up to the sheet's own Pan India total is not published.
-- Checked at the end of the import transaction (deferred), so the whole commit is undone and the uploader sees why.
-- An admin can accept a known source-total difference for a date in bi.zt_control_override.
create table if not exists bi.zt_control_override (
  snapshot_date date primary key, reason text not null check (length(reason) >= 5), actor text not null, created_at timestamptz not null default now());
alter table bi.zt_control_override enable row level security;

create or replace function bi.zt_snapshot_control_check() returns trigger language plpgsql security definer set search_path to 'bi', 'public' as $$
declare v_leaf numeric; v_src numeric := new.pan_india_mtd;
begin
  if v_src is null or exists (select 1 from bi.zt_control_override o where o.snapshot_date = new.snapshot_date) then return null; end if;
  if not exists (select 1 from bi.zt_snapshot s where s.snapshot_date = new.snapshot_date and s.batch_id = new.batch_id) then return null; end if;
  select coalesce(sum(mtd_cases), 0) into v_leaf from bi.zt_row r
   where r.snapshot_date = new.snapshot_date and r.row_type = 'leaf' and r.location_id is not null
     and not exists (select 1 from bi.location l where l.id = r.location_id and l.is_rollup);
  if abs(v_leaf - v_src) > 0.5 then
    raise exception using errcode = 'P0001',
      message = format('Tracker %s not imported: location rows add up to %s cases but the sheet''s Pan India row says %s (difference %s). '
                       'Look for sub-total rows typed as locations, or ask an admin to record the difference as accepted.',
                       to_char(new.snapshot_date, 'DD-Mon-YYYY'), v_leaf, v_src, v_leaf - v_src);
  end if;
  return null;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'zt_snapshot_control_check' and tgrelid = 'bi.zt_snapshot'::regclass) then
    create constraint trigger zt_snapshot_control_check after insert on bi.zt_snapshot
      deferrable initially deferred for each row execute function bi.zt_snapshot_control_check();
  end if;
end $$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('claude-reaudit', 'data_correction', 'zt_snapshot', '2026-10-19',
        jsonb_build_object('note', 'Zone sub-total rows of the 19-Oct tracker re-typed as roll-ups; pseudo-locations 46-51 flagged; history views exclude them (AUDIT_REGISTER A1)',
                           'leaf_mtd_before', 57464, 'leaf_target_before', 143140, 'source_control_mtd', 33977, 'source_control_target', 84395));
