
create table if not exists bi.location_mapping_history (
  id bigserial primary key,
  location_id int not null references bi.location(id),
  attr text not null check (attr in ('zone_group','region','stakeholder')),
  value text,
  valid_from date not null check (valid_from >= date '2024-04-01'),
  valid_to date,
  active boolean not null default true,
  changed_by text not null,
  changed_at timestamptz not null default now(),
  reason text not null,
  change_ref bigint,
  check (valid_to is null or valid_to >= valid_from)
);
create index if not exists lmh_lookup on bi.location_mapping_history(location_id, attr, valid_from) where active;
comment on table bi.location_mapping_history is 'Effective-dated (WEF) location group mappings. Rows are never deleted; superseded rows get active=false.';

-- no overlapping active periods for the same location+attribute
create or replace function bi.trg_lmh_no_overlap() returns trigger language plpgsql as $$
begin
  if new.active and exists (select 1 from bi.location_mapping_history h
     where h.active and h.id<>new.id and h.location_id=new.location_id and h.attr=new.attr
       and daterange(h.valid_from, h.valid_to, '[]') && daterange(new.valid_from, new.valid_to, '[]')) then
    raise exception 'overlapping mapping period for location % %', new.location_id, new.attr using errcode='23P01';
  end if;
  return new;
end $$;
drop trigger if exists lmh_no_overlap on bi.location_mapping_history;
create constraint trigger lmh_no_overlap after insert or update on bi.location_mapping_history
  deferrable initially deferred for each row execute function bi.trg_lmh_no_overlap();

insert into bi.location_mapping_history(location_id, attr, value, valid_from, changed_by, reason)
select l.id, a.attr, case a.attr when 'zone_group' then l.zone_group when 'region' then l.region else l.stakeholder end,
       date '2024-04-01', 'system-seed', 'Initial mapping as loaded; no earlier mapping history was available'
from bi.location l cross join (values ('zone_group'),('region'),('stakeholder')) a(attr)
where not exists (select 1 from bi.location_mapping_history h where h.location_id=l.id and h.attr=a.attr);

create or replace function bi.loc_attr_at(p_loc int, p_attr text, p_at date) returns text language sql stable as $$
  select v from (
    (select h.value v, 1 o from bi.location_mapping_history h
      where h.active and h.location_id=p_loc and h.attr=p_attr and h.valid_from<=p_at and (h.valid_to is null or h.valid_to>=p_at)
      order by h.valid_from desc limit 1)
    union all
    select case p_attr when 'zone_group' then l.zone_group when 'region' then l.region else l.stakeholder end, 2
      from bi.location l where l.id=p_loc) q order by o limit 1 $$;

-- date-aware filter (tracker reports pass the snapshot/month date)
create or replace function bi.loc_ok(p_loc int, p_unit text, f jsonb, p_at date) returns boolean language sql stable as $$
  select case when coalesce(f,'{}'::jsonb) - 'client_family' = '{}'::jsonb then true
    when p_at is null then bi.loc_ok(p_loc, p_unit, f)
    when p_loc is not null then exists(select 1 from bi.location l where l.id=p_loc)
          and (f->>'location_id' is null or p_loc=(f->>'location_id')::int)
          and (f->>'region' is null or bi.loc_attr_at(p_loc,'region',p_at) is not distinct from f->>'region')
          and (f->>'zone_group' is null or bi.loc_attr_at(p_loc,'zone_group',p_at) is not distinct from f->>'zone_group')
          and (f->>'stakeholder' is null or bi.loc_attr_at(p_loc,'stakeholder',p_at) is not distinct from f->>'stakeholder')
    else f->>'location_id' is null and exists(select 1 from bi.location l where l.recon_unit=p_unit
          and (f->>'region' is null or bi.loc_attr_at(l.id,'region',p_at) is not distinct from f->>'region')
          and (f->>'zone_group' is null or bi.loc_attr_at(l.id,'zone_group',p_at) is not distinct from f->>'zone_group')
          and (f->>'stakeholder' is null or bi.loc_attr_at(l.id,'stakeholder',p_at) is not distinct from f->>'stakeholder')) end $$;

-- keep bi.location (current view used by Case/Point/People reports and filters) in line with today's mapping
create or replace function bi.sync_location_current() returns int language plpgsql security definer set search_path to 'bi','public' as $$
declare n int;
begin
  with t as (select l.id, bi.loc_attr_at(l.id,'zone_group',(now() at time zone 'Asia/Kolkata')::date) z,
                    bi.loc_attr_at(l.id,'region',(now() at time zone 'Asia/Kolkata')::date) r,
                    bi.loc_attr_at(l.id,'stakeholder',(now() at time zone 'Asia/Kolkata')::date) s from bi.location l),
  u as (update bi.location l set zone_group=t.z, region=t.r, stakeholder=t.s from t
        where t.id=l.id and (l.zone_group is distinct from t.z or l.region is distinct from t.r or l.stakeholder is distinct from t.s) returning l.id)
  select count(*) into n from u;
  if n>0 then insert into bi.audit_log(actor,action,entity,detail) values ('system','wef_mapping_applied','location',jsonb_build_object('locations_updated',n)); end if;
  return n;
end $$;

create or replace function bi.group_change_preview(p jsonb) returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $$
declare v_loc int := (p->>'location_id')::int; v_attr text := p->>'attr'; v_val text := nullif(trim(p->>'value'),'');
        v_wef date := nullif(p->>'wef','')::date; v_errs text[] := '{}'; v_next date; v_end date; c bi.location_mapping_history; l bi.location;
        v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  select * into l from bi.location where id=v_loc;
  if l.id is null then v_errs := v_errs || 'Unknown location'; end if;
  if v_attr is null or v_attr not in ('zone_group','region','stakeholder') then v_errs := v_errs || 'Group type must be zone_group, region or stakeholder'; end if;
  if v_wef is null then v_errs := v_errs || 'WEF date is required';
  elsif v_wef < date '2024-04-01' then v_errs := v_errs || 'WEF date cannot be before 1-Apr-2024'; end if;
  if v_attr='zone_group' and (v_val is null or not exists(select 1 from bi.zone_group where code=v_val)) then v_errs := v_errs || 'Zone group must be an existing zone code (add it first)'; end if;
  if v_attr='region' and v_val is null then v_errs := v_errs || 'Region cannot be blank'; end if;
  if p ? 'reason' and length(coalesce(trim(p->>'reason'),'')) < 5 then v_errs := v_errs || 'Reason must be at least 5 characters'; end if;
  if array_length(v_errs,1) is null then
    select * into c from bi.location_mapping_history h where h.active and h.location_id=v_loc and h.attr=v_attr
      and h.valid_from<=v_wef and (h.valid_to is null or h.valid_to>=v_wef) order by valid_from desc limit 1;
    if c.id is not null and c.value is not distinct from v_val then v_errs := v_errs || format('No change: value is already %s on %s', coalesce(v_val,'(blank)'), v_wef); end if;
    select min(valid_from) into v_next from bi.location_mapping_history h where h.active and h.location_id=v_loc and h.attr=v_attr and h.valid_from>v_wef;
    v_end := coalesce(c.valid_to, v_next - 1);
  end if;
  return jsonb_build_object('ok', array_length(v_errs,1) is null, 'errors', to_jsonb(v_errs),
    'location', l.label, 'location_id', v_loc, 'attr', v_attr, 'new_value', v_val, 'wef', v_wef, 'applies_until', v_end,
    'value_today', case when l.id is not null and v_attr is not null then bi.loc_attr_at(v_loc, v_attr, v_today) end,
    'value_on_wef', case when l.id is not null and v_attr is not null and v_wef is not null then bi.loc_attr_at(v_loc, v_attr, v_wef) end,
    'takes_effect_now', v_wef is not null and v_wef <= v_today and (v_end is null or v_end >= v_today),
    'later_change_kept', v_next,
    'affected', jsonb_build_object(
       'tracker_snapshots', (select count(distinct snapshot_date) from bi.zt_row where location_id=v_loc and row_type='leaf' and snapshot_date>=v_wef and (v_end is null or snapshot_date<=v_end)),
       'tracker_rows', (select count(*) from bi.zt_row where location_id=v_loc and row_type='leaf' and snapshot_date>=v_wef and (v_end is null or snapshot_date<=v_end)),
       'tracker_months', (select coalesce(jsonb_agg(distinct to_char(snapshot_date,'YYYY-MM')),'[]') from bi.zt_row where location_id=v_loc and row_type='leaf' and snapshot_date>=v_wef and (v_end is null or snapshot_date<=v_end)),
       'case_rows_current_mapping', (select count(*) from bi.v_case where location_id=v_loc and received_at>=v_wef)),
    'reports', jsonb_build_array(
       'Overview, Business tracker, Growth & trends, LFL and forecasts: tracker figures from the WEF date onward move to the new group; earlier dates keep the old group',
       'Force1, TAT and People: use the mapping in force today (changes once the WEF date is reached)'),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('value',value,'from',valid_from,'to',valid_to,'by',changed_by,'reason',reason) order by valid_from),'[]')
                from bi.location_mapping_history where active and location_id=v_loc and attr=v_attr));
end $$;

create or replace function bi.group_change_apply(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $$
declare pv jsonb := bi.group_change_preview(p || jsonb_build_object('reason', coalesce(p->>'reason',''))); c bi.location_mapping_history;
        v_loc int := (p->>'location_id')::int; v_attr text := p->>'attr'; v_val text := nullif(trim(p->>'value'),''); v_wef date := (p->>'wef')::date;
        v_reason text := trim(p->>'reason'); v_new bigint; v_end date := nullif(pv->>'applies_until','')::date; v_sync int;
begin
  if not (pv->>'ok')::boolean then return pv; end if;
  select * into c from bi.location_mapping_history h where h.active and h.location_id=v_loc and h.attr=v_attr
    and h.valid_from<=v_wef and (h.valid_to is null or h.valid_to>=v_wef) order by valid_from desc limit 1 for update;
  if c.id is not null then
    update bi.location_mapping_history set active=false where id=c.id;
    if c.valid_from < v_wef then
      insert into bi.location_mapping_history(location_id,attr,value,valid_from,valid_to,changed_by,reason,change_ref)
      values (v_loc,v_attr,c.value,c.valid_from,v_wef-1,p_actor,'Period closed by WEF change: '||v_reason,c.id);
    end if;
  end if;
  insert into bi.location_mapping_history(location_id,attr,value,valid_from,valid_to,changed_by,reason,change_ref)
  values (v_loc,v_attr,v_val,v_wef,v_end,p_actor,v_reason,c.id) returning id into v_new;
  set constraints bi.lmh_no_overlap immediate;
  v_sync := bi.sync_location_current();
  insert into bi.audit_log(actor,action,entity,entity_key,detail)
  values (p_actor,'group_change','location_mapping_history',v_new::text,
          jsonb_build_object('location_id',v_loc,'attr',v_attr,'old_value',c.value,'new_value',v_val,'wef',v_wef,'until',v_end,'reason',v_reason,'replaced_row',c.id));
  return pv || jsonb_build_object('applied', true, 'change_id', v_new, 'current_mapping_updated', v_sync > 0);
end $$;

create or replace function bi.zone_group_edit(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $$
declare v_code text := upper(trim(p->>'code')); v_label text := trim(p->>'label'); v_old text; v_reason text := trim(p->>'reason');
begin
  if v_code is null or v_code !~ '^[A-Z0-9_]{2,30}$' then raise exception 'Zone code must be 2-30 letters, digits or _'; end if;
  if coalesce(length(v_label),0) < 2 then raise exception 'Zone label is required'; end if;
  if coalesce(length(v_reason),0) < 5 then raise exception 'Reason must be at least 5 characters'; end if;
  select label into v_old from bi.zone_group where code=v_code;
  if p->>'mode'='add' then
    if v_old is not null then raise exception 'Zone code % already exists', v_code; end if;
    insert into bi.zone_group(code,label) values (v_code,v_label);
  else
    if v_old is null then raise exception 'Unknown zone code %', v_code; end if;
    update bi.zone_group set label=v_label where code=v_code;
  end if;
  insert into bi.audit_log(actor,action,entity,entity_key,detail)
  values (p_actor, case when p->>'mode'='add' then 'zone_add' else 'zone_rename' end, 'zone_group', v_code,
          jsonb_build_object('old_label',v_old,'new_label',v_label,'reason',v_reason));
  return jsonb_build_object('ok',true,'code',v_code,'old_label',v_old,'label',v_label);
end $$;

create or replace function bi.api_groups() returns jsonb language sql stable security definer set search_path to 'bi','public' as $$
  select jsonb_build_object(
    'zones', (select jsonb_agg(jsonb_build_object('code',code,'label',label) order by label) from bi.zone_group),
    'regions', (select jsonb_agg(distinct region) from bi.location where region is not null),
    'stakeholders', (select jsonb_agg(distinct stakeholder) from bi.location where stakeholder is not null),
    'locations', (select jsonb_agg(jsonb_build_object('id',l.id,'label',l.label,'zone_group',l.zone_group,'zone',zg.label,'region',l.region,'stakeholder',l.stakeholder,'recon_unit',l.recon_unit) order by l.region,zg.label,l.label)
                  from bi.location l left join bi.zone_group zg on zg.code=l.zone_group),
    'upcoming', (select coalesce(jsonb_agg(jsonb_build_object('id',h.id,'location',l.label,'attr',h.attr,'value',h.value,'from',h.valid_from,'by',h.changed_by,'reason',h.reason) order by h.valid_from),'[]')
                 from bi.location_mapping_history h join bi.location l on l.id=h.location_id where h.active and h.valid_from > (now() at time zone 'Asia/Kolkata')::date),
    'file_groups', (select coalesce(jsonb_agg(jsonb_build_object('file_group',alias,'recon_unit',recon_unit,'status',review_status) order by alias),'[]') from bi.location_alias where source='case_file'),
    'concepts', jsonb_build_array(
      jsonb_build_object('name','Zone group','source','Tracker zone heading (bi.location.zone_group → bi.zone_group)','editable','WEF-dated'),
      jsonb_build_object('name','Region','source','bi.location.region','editable','WEF-dated'),
      jsonb_build_object('name','Stakeholder','source','bi.location.stakeholder (zone owner)','editable','WEF-dated'),
      jsonb_build_object('name','File group','source','Case/Point Wise file name → reconciliation unit (bi.location_alias source=case_file)','editable','via mapping queue (not dated)'))) $$;

create or replace function bi.api_group_history(p jsonb) returns jsonb language sql stable security definer set search_path to 'bi','public' as $$
  select coalesce(jsonb_agg(x order by (x->>'changed_at') desc),'[]') from (
    select jsonb_build_object('id',h.id,'location',l.label,'location_id',h.location_id,'attr',h.attr,'value',h.value,'from',h.valid_from,'to',h.valid_to,
           'active',h.active,'by',h.changed_by,'changed_at',h.changed_at,'reason',h.reason,'replaces',h.change_ref) x
    from bi.location_mapping_history h join bi.location l on l.id=h.location_id
    where (p->>'location_id' is null or h.location_id=(p->>'location_id')::int) and (coalesce((p->>'include_seed')::boolean,false) or h.changed_by<>'system-seed')
    order by h.changed_at desc limit 500) q $$;

revoke all on function bi.group_change_apply(text,jsonb), bi.zone_group_edit(text,jsonb), bi.sync_location_current() from public, anon, authenticated;
