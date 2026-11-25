-- Wave 121a (25-Nov-2026): Case / Point Wise file groups — a second file for the same city (e.g. UP_LUCKNOW_MANEESH next to UP-LUCKNOW)
-- is its own file group, and a new group can be added from the upload page.
-- Owner 25-Nov 16:43: "a new file … up_lucknow_maneesh … it didn't allow and was only allowing 1 file of Lucknow to tick".
-- Cause: the page read every name containing LUCKNOW as the group "Lucknow", so the two files looked like two copies of one report.
-- Server side here: a list of known file groups for the page, and the first upload of a new group maps it to a reconciliation unit —
-- the unit of the city in its name ("Lucknow-Maneesh" → Lucknow) or the unit the admin picked on the page. Without a unit the import
-- behaves as before (cases kept, flagged "unmapped_case_file_group"). Additive; ingest_as body saved in bi.fn_backup (wave '121a').

create or replace function bi.file_group_ensure(p_group text, p_unit text default null, p_actor text default 'upload')
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $$
declare g text := bi.norm(p_group); u text; head text; how text;
begin
  if g is null then return jsonb_build_object('known', false); end if;
  select recon_unit into u from bi.location_alias where source = 'case_file' and alias = g and review_status <> 'rejected';
  if u is not null then return jsonb_build_object('known', true, 'unit', u); end if;
  if nullif(btrim(p_unit), '') is not null then
    select l.recon_unit into u from bi.location l where bi.norm(l.recon_unit) = bi.norm(p_unit) limit 1;
    how := 'chosen at upload';
  end if;
  if u is null and g ~ '^.+?\s*-\s*.+$' then
    head := btrim(split_part(g, '-', 1));
    select recon_unit into u from bi.location_alias where source = 'case_file' and alias = head and review_status <> 'rejected';
    how := 'city in the file name';
  end if;
  if u is null then return jsonb_build_object('known', false, 'new', true); end if;
  insert into bi.location_alias(source, alias, recon_unit, method, confidence, evidence, review_status)
  values ('case_file', g, u, 'upload: ' || how, case when how = 'chosen at upload' then 1 else 0.9 end,
          jsonb_build_object('group', p_group, 'by', left(coalesce(p_actor, 'upload'), 60), 'at', now(), 'wave', '121a'), 'auto')
  on conflict (source, alias) do nothing;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (left(coalesce(p_actor, 'upload'), 60), 'file_group_added', 'location_alias', g, jsonb_build_object('group', p_group, 'unit', u, 'how', how));
  return jsonb_build_object('known', true, 'added', true, 'unit', u, 'how', how);
end $$;

-- the page's list: every file group with its unit and recent imports, and the units a new group can join
create or replace function bi.api_file_groups()
returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $$
  with a as (select alias, recon_unit, method from bi.location_alias where source = 'case_file' and review_status <> 'rejected'),
  b as (select bi.norm(location_group) g, max(location_group) shown, count(*) files_90d, max(created_at) last_import
          from bi.import_batch where source_category in ('case', 'point') and status = 'committed' and created_at > now() - interval '90 days' group by 1)
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_object('group', coalesce(b.shown, (select min(l.recon_unit) from bi.location l where bi.norm(l.recon_unit) = a.alias), initcap(a.alias)),
                       'unit', a.recon_unit, 'files_90d', coalesce(b.files_90d, 0), 'last_import', b.last_import, 'added_at_upload', a.method like 'upload:%') order by a.alias)
                        from a left join b on b.g = a.alias), '[]'::jsonb),
    'units', coalesce((select jsonb_agg(distinct recon_unit order by recon_unit) from bi.location where recon_unit is not null), '[]'::jsonb));
$$;

create or replace function pg_temp.patch(p regprocedure, olds text[], news text[]) returns void language plpgsql as $$
declare d text := pg_get_functiondef(p); i int; k int;
begin
  insert into bi.fn_backup(fn, def, wave) values (p::text, d, '121a');
  for i in 1 .. array_length(olds, 1) loop
    k := (length(d) - length(replace(d, olds[i], ''))) / length(olds[i]);
    if k <> 1 then raise exception 'patch %: piece % found % times', p, i, k; end if;
    d := replace(d, olds[i], news[i]);
  end loop;
  execute d;
end $$;

select pg_temp.patch('bi.ingest_as(text,text,jsonb)'::regprocedure,
  array[$a$    insert into bi.audit_log(actor,action,entity,entity_key,detail) values (v_actor,'import_begin','import_batch',v_id::text,p_payload - 'rows');
    return jsonb_build_object('batch_id',v_id);$a$],
  array[$a$    insert into bi.audit_log(actor,action,entity,entity_key,detail) values (v_actor,'import_begin','import_batch',v_id::text,p_payload - 'rows');
    -- wave 121a: a new Case / Point Wise file group is mapped to its unit on its first upload
    if p_payload->>'category' in ('case', 'point') and nullif(p_payload->>'location_group', '') is not null then
      return jsonb_build_object('batch_id', v_id, 'file_group', bi.file_group_ensure(p_payload->>'location_group', p_payload->>'recon_unit', v_actor));
    end if;
    return jsonb_build_object('batch_id',v_id);$a$]);

select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure,
  array[$a$      when 'branch_lfl' then bi.api_branch_lfl(m, f, coalesce(p_args->'p', '{}'::jsonb))   -- wave 120b$a$],
  array[$a$      when 'branch_lfl' then bi.api_branch_lfl(m, f, coalesce(p_args->'p', '{}'::jsonb))   -- wave 120b
      when 'file_groups' then bi.api_file_groups()   -- wave 121a$a$]);
