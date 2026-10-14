-- Applied to Supabase project via MCP on 20261014220231
create table if not exists bi.mapping_correction(
  id bigserial primary key,
  kind text not null check (kind in ('location_alias', 'client_alias')),
  source text not null, alias text not null,
  old_target text, new_target text not null,
  effective_from date not null, reason text not null, actor text not null,
  affected jsonb not null default '{}'::jsonb, created_at timestamptz not null default now());
alter table bi.mapping_correction enable row level security;

create or replace function bi.mapping_retarget(p_actor text, p jsonb)
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare k text := p->>'kind'; wef date := nullif(p->>'effective_from', '')::date; why text := nullif(trim(p->>'reason'), '');
        doit boolean := coalesce((p->>'apply')::boolean, false); la record; ca record; newloc int; newcli text;
        n_zt int := 0; n_cs int := 0; snaps int := 0; aff jsonb; note text; old_label text; new_label text;
begin
  if k = 'history' then
    return (select coalesce(jsonb_agg(to_jsonb(h) order by h.id desc), '[]'::jsonb) from (select * from bi.mapping_correction order by id desc limit 200) h);
  end if;
  if wef is null or wef < date '2024-04-01' or wef > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'effective_from must be a date between 01-Apr-2024 and today'; end if;
  if k = 'location_alias' then
    select * into la from bi.location_alias where id = (p->>'id')::bigint;
    if not found then raise exception 'mapping not found'; end if;
    newloc := (p->>'target')::int;
    if not exists (select 1 from bi.location where id = newloc) then raise exception 'unknown target location'; end if;
    if newloc = la.location_id then raise exception 'the mapping already points to that location'; end if;
    if la.source = 'case_file' then raise exception 'File-group mappings set the location group; change those with the WEF group editor'; end if;
    old_label := (select label from bi.location where id = la.location_id); new_label := (select label from bi.location where id = newloc);
    if la.source = 'zonal_label' then
      select count(*), count(distinct snapshot_date) into n_zt, snaps from bi.zt_row
       where bi.norm(location_label) = la.alias and snapshot_date >= wef and location_id is distinct from newloc;
    elsif la.source = 'area_office' then
      select count(*) into n_cs from bi.case_store c join bi.dim d on d.id = c.area_office_id
       where c.recon_unit = la.recon_unit and bi.norm(d.val) = la.alias and (c.received_at at time zone 'Asia/Kolkata')::date >= wef and c.location_id = la.location_id;
    elsif la.source = 'branch_token' then
      select count(*) into n_cs from bi.case_store c join bi.dim d on d.id = c.branch_id
       where c.recon_unit = la.recon_unit and bi.norm(d.val) ~ ('(^|[^A-Z])' || la.alias || '([^A-Z]|$)')
         and (c.received_at at time zone 'Asia/Kolkata')::date >= wef and c.location_id = la.location_id;
    end if;
    aff := jsonb_build_object('tracker_rows', n_zt, 'tracker_snapshots', snaps, 'force1_cases', n_cs);
    if doit then
      if why is null or length(why) < 5 then raise exception 'A reason (5+ characters) is required'; end if;
      if la.source = 'zonal_label' then
        update bi.zt_row set location_id = newloc where bi.norm(location_label) = la.alias and snapshot_date >= wef and location_id is distinct from newloc;
      elsif la.source = 'area_office' then
        update bi.case_store c set location_id = newloc from bi.dim d
         where d.id = c.area_office_id and c.recon_unit = la.recon_unit and bi.norm(d.val) = la.alias
           and (c.received_at at time zone 'Asia/Kolkata')::date >= wef and c.location_id = la.location_id;
      elsif la.source = 'branch_token' then
        update bi.case_store c set location_id = newloc from bi.dim d
         where d.id = c.branch_id and c.recon_unit = la.recon_unit and bi.norm(d.val) ~ ('(^|[^A-Z])' || la.alias || '([^A-Z]|$)')
           and (c.received_at at time zone 'Asia/Kolkata')::date >= wef and c.location_id = la.location_id;
      end if;
      update bi.location_alias set location_id = newloc, review_status = 'accepted', reviewed_by = p_actor, reviewed_at = now() where id = la.id;
      insert into bi.mapping_correction(kind, source, alias, old_target, new_target, effective_from, reason, actor, affected)
      values (k, la.source, la.alias, la.location_id::text, newloc::text, wef, why, p_actor, aff);
    end if;
    return jsonb_build_object('kind', k, 'source', la.source, 'alias', la.alias, 'current', jsonb_build_object('id', la.location_id, 'label', old_label),
      'proposed', jsonb_build_object('id', newloc, 'label', new_label), 'effective_from', wef, 'affected', aff, 'applied', doit,
      'note', 'Records dated before the effective date keep the current location; later records move. New uploads use the corrected mapping.');
  elsif k = 'client_alias' then
    select * into ca from bi.client_alias where source = p->>'source' and alias = p->>'alias';
    if not found then raise exception 'mapping not found'; end if;
    newcli := p->>'target';
    if not exists (select 1 from bi.client where code = newcli) then raise exception 'unknown target client'; end if;
    if newcli = ca.client_code then raise exception 'the mapping already points to that client'; end if;
    if ca.source = 'zonal' then
      select count(*), count(distinct snapshot_date) into n_zt, snaps from bi.zt_row
       where bi.norm(client_label) = ca.alias and snapshot_date >= wef and client_code is distinct from newcli;
      note := 'Tracker rows dated on or after the effective date move to the new client.';
    else
      note := 'Force1 case records do not keep the original client label, so past cases cannot be traced to this mapping; the correction applies to new uploads.';
    end if;
    aff := jsonb_build_object('tracker_rows', n_zt, 'tracker_snapshots', snaps, 'force1_cases', null);
    if doit then
      if why is null or length(why) < 5 then raise exception 'A reason (5+ characters) is required'; end if;
      if ca.source = 'zonal' then
        update bi.zt_row set client_code = newcli where bi.norm(client_label) = ca.alias and snapshot_date >= wef and client_code is distinct from newcli;
      end if;
      update bi.client_alias set client_code = newcli, review_status = 'accepted' where source = ca.source and alias = ca.alias;
      insert into bi.mapping_correction(kind, source, alias, old_target, new_target, effective_from, reason, actor, affected)
      values (k, ca.source, ca.alias, ca.client_code, newcli, wef, why, p_actor, aff);
    end if;
    return jsonb_build_object('kind', k, 'source', ca.source, 'alias', ca.alias, 'current', jsonb_build_object('id', ca.client_code),
      'proposed', jsonb_build_object('id', newcli), 'effective_from', wef, 'affected', aff, 'applied', doit, 'note', note);
  else
    raise exception 'kind must be location_alias, client_alias or history';
  end if;
end $function$;

do $$
declare d text := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
        anchor text := $a$when 'mapping_update' then$a$;
        addition text := $s$when 'mapping_retarget' then
      declare r jsonb := bi.mapping_retarget('admin-key:' || coalesce(nullif(trim(p->>'editor'), ''), 'unnamed'), p - 'admin_key');
      begin
        if coalesce((r->>'applied')::boolean, false) then
          insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin-key:' || coalesce(nullif(trim(p->>'editor'), ''), 'unnamed'), 'mapping_retarget', r->>'kind', r->>'alias', r);
          insert into bi.audit_log(actor, action, entity) values ('admin-key', 'request_refresh', 'point_derived');
        end if;
        return r;
      end;
    $s$;
begin
  if position('when ''mapping_retarget''' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then raise exception 'anchor not unique'; end if;
  execute replace(d, anchor, addition || anchor);
end $$;
