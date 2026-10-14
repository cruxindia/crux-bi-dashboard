-- bi_037: tracker reports use the mapping in force on each snapshot/month date; expose LFL + group admin actions; T20
do $do$
declare fn text; d text; d2 text; n int;
begin
  foreach fn in array array['api_zonal','api_daily','api_overview','api_monthly','api_lfl','api_forecast','api_insights'] loop
    d := pg_get_functiondef(('bi.'||fn)::regproc);
    d2 := regexp_replace(d, 'bi\.loc_ok\((d|l|x|z)\.location_id,\s*([A-Za-z_.]+),\s*f\)', 'bi.loc_ok(\1.location_id,\2,f,\1.snapshot_date)', 'g');
    d2 := regexp_replace(d2, 'bi\.loc_ok\(mb\.location_id,\s*([A-Za-z_.]+),\s*f\)', 'bi.loc_ok(mb.location_id,\1,f,mb.month)', 'g');
    if fn = 'api_zonal' then
      d2 := replace(d2, 'left join bi.zone_group zg on zg.code=lo.zone_group', 'left join bi.zone_group zg on zg.code=bi.loc_attr_at(lo.id,''zone_group'',d.snapshot_date)');
      d2 := replace(d2, '''region'',lo.region', '''region'',bi.loc_attr_at(lo.id,''region'',d.snapshot_date)');
      d2 := replace(d2, '''stakeholder'',lo.stakeholder', '''stakeholder'',bi.loc_attr_at(lo.id,''stakeholder'',d.snapshot_date)');
    elsif fn = 'api_monthly' then
      d2 := replace(d2, 'left join bi.zone_group zg on zg.code=lo.zone_group', 'left join bi.zone_group zg on zg.code=bi.loc_attr_at(lo.id,''zone_group'',mb.month)');
    end if;
    if d2 = d then raise exception 'patch made no change in %', fn; end if;
    execute d2;
  end loop;
  select count(*) into n from pg_proc where pronamespace='bi'::regnamespace and proname in ('api_zonal','api_daily','api_overview','api_monthly','api_lfl','api_forecast','api_insights')
     and prosrc ~ 'loc_ok\((d|l|x|z|mb)\.location_id,[^,]+,f\)';
  if n > 0 then raise exception '% tracker functions still use undated loc_ok', n; end if;
end $do$;

-- public read: add LFL
do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''lfl''' in d) = 0 then
    d := replace(d, 'when ''branches'' then bi.api_branches(f)',
      'when ''branches'' then bi.api_branches(f)'||chr(10)||'      when ''lfl'' then bi.api_lfl(m,f,coalesce(p_args->>''group'',''location''))');
    if position('''lfl''' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;

create or replace function public.bi_admin(p_action text, p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'bi','public' as $function$
begin
  if not bi.admin_ok(p->>'admin_key') then raise exception 'admin key required' using errcode='42501'; end if;
  case p_action
    when 'verify' then return jsonb_build_object('ok', true);
    when 'mapping_update' then return bi.api_mapping_update('admin-key', p - 'admin_key');
    when 'refresh_employees' then
      insert into bi.audit_log(actor,action,entity) values ('admin-key','request_refresh','point_derived');
      return jsonb_build_object('queued', true, 'note', 'Classification and Force1 figures refresh within 10 minutes');
    when 'matrix' then return bi.api_matrix((p->>'from')::date, (p->>'to')::date);
    when 'matrix_save' then return bi.matrix_save('admin-key', p);
    when 'matrix_validate' then return bi.matrix_validate((p->>'date')::date);
    when 'matrix_commit' then return bi.matrix_commit('admin-key', (p->>'date')::date, coalesce((p->>'ack')::boolean,false), p->>'reason');
    when 'matrix_no_report' then return bi.matrix_mark_no_report('admin-key', (p->>'date')::date, p->>'reason');
    when 'groups' then return bi.api_groups();
    when 'group_preview' then return bi.group_change_preview(p - 'admin_key');
    when 'group_apply' then return bi.group_change_apply('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'group_history' then return bi.api_group_history(p - 'admin_key');
    when 'zone_edit' then return bi.zone_group_edit('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    else raise exception 'unknown action';
  end case;
end $function$;
grant execute on function public.bi_admin(text,jsonb) to anon, authenticated;

-- daily: apply future-dated WEF changes to the current mapping
select cron.schedule('bi-wef-sync', '35 18 * * *', $$select bi.sync_location_current()$$);

-- T20: WEF change behaves correctly across the WEF date and never overwrites history (run inside a sub-transaction, rolled back)
create or replace function bi.test_wef_group_change() returns jsonb language plpgsql security definer set search_path to 'bi','public' as $$
declare v_loc int; v_old text; v_new text; s_before date; s_after date; v_wef date; r jsonb; before_ok boolean; after_ok boolean; hist int; overlap_blocked boolean := false;
begin
  select l.id, l.zone_group into v_loc, v_old from bi.location l join bi.zt_row z on z.location_id=l.id and z.row_type='leaf'
   where z.snapshot_date between date '2026-09-01' and date '2026-09-30' group by 1,2 having count(distinct z.snapshot_date)>10 order by 1 limit 1;
  select code into v_new from bi.zone_group where code<>v_old order by code limit 1;
  select min(snapshot_date), max(snapshot_date) into s_before, s_after from bi.zt_row where location_id=v_loc and snapshot_date between date '2026-09-01' and date '2026-09-30';
  v_wef := date '2026-09-15';
  begin
    r := bi.group_change_apply('test', jsonb_build_object('location_id',v_loc,'attr','zone_group','value',v_new,'wef',v_wef,'reason','acceptance test T20'));
    before_ok := (select count(*) from jsonb_array_elements(bi.api_zonal(s_before, jsonb_build_object('zone_group',v_old))) e where (e->>'location_id')::int=v_loc) > 0
             and (select count(*) from jsonb_array_elements(bi.api_zonal(s_before, jsonb_build_object('zone_group',v_new))) e where (e->>'location_id')::int=v_loc) = 0;
    after_ok := (select count(*) from jsonb_array_elements(bi.api_zonal(s_after, jsonb_build_object('zone_group',v_new))) e where (e->>'location_id')::int=v_loc) > 0
             and (select count(*) from jsonb_array_elements(bi.api_zonal(s_after, jsonb_build_object('zone_group',v_old))) e where (e->>'location_id')::int=v_loc) = 0;
    select count(*) into hist from bi.location_mapping_history where location_id=v_loc and attr='zone_group';
    begin
      insert into bi.location_mapping_history(location_id,attr,value,valid_from,changed_by,reason) values (v_loc,'zone_group',v_old,date '2026-09-20','test','overlap');
      set constraints bi.lmh_no_overlap immediate;
    exception when others then overlap_blocked := true; end;
    raise exception 'rollback_t20';
  exception when others then
    if sqlerrm <> 'rollback_t20' then return jsonb_build_object('passed',false,'error',sqlerrm); end if;
  end;
  return jsonb_build_object('passed', before_ok and after_ok and hist=3 and overlap_blocked and (r->>'applied')::boolean,
    'location_id',v_loc,'old_zone',v_old,'new_zone',v_new,'wef',v_wef,'snapshot_before',s_before,'snapshot_after',s_after,
    'old_group_before_wef',before_ok,'new_group_after_wef',after_ok,'history_rows_after_change',hist,'overlap_blocked',overlap_blocked);
end $$;
revoke all on function bi.test_wef_group_change() from public, anon, authenticated;

do $do$
declare d text := pg_get_functiondef('bi.run_acceptance_tests'::regproc);
begin
  if position('T20' in d) = 0 then
    d := replace(d, E'return next;\nend $function$',
      E'return next;\n\n  -- T20 WEF-dated group change (rolled back)\n  j := bi.test_wef_group_change();\n  test:=''T20 WEF group change applies from the WEF date and keeps history''; passed:=coalesce((j->>''passed'')::boolean,false); detail:=j; return next;\nend $function$');
    if position('T20' in d) = 0 then raise exception 'T20 patch failed'; end if;
    execute d;
  end if;
end $do$;

-- Ask Crux: honour a month named in the question ("in September", "Aug 2026"); Force1 field-level uses that month when Point Wise data exists
do $do$
declare d text := pg_get_functiondef('public.bi_ask'::regproc); d0 text;
begin
  if position('mm int;' in d) = 0 then
    d0 := d;
    d := replace(d, 'mid bigint;', 'mid bigint; mm int; yy int; mx date;');
    d := replace(d, $r$m := coalesce(nullif(p_context->>'month','')::date, (select max(report_month) from bi.zt_snapshot));$r$,
$r$m := coalesce(nullif(p_context->>'month','')::date, (select max(report_month) from bi.zt_snapshot));
  select i into mm from unnest(array['\m(january|jan)\M','\m(february|feb)\M','\m(march)\M','\m(april|apr)\M','(\min may\M|\mmay\s+(20)?\d\d\M)','\m(june|jun)\M',
       '\m(july|jul)\M','\m(august|aug)\M','\m(september|sept|sep)\M','\m(october|oct)\M','\m(november|nov)\M','\m(december)\M']) with ordinality t(rx,i) where q ~ rx limit 1;
  if mm is not null then
    yy := (regexp_match(q, '\m(20\d\d)\M'))[1]::int;
    if yy is null then yy := (regexp_match(q, '(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*''?(\d\d)\M'))[1]::int + 2000; end if;
    mx := (select max(report_month) from bi.zt_snapshot);
    m := make_date(coalesce(yy, extract(year from mx)::int), mm, 1);
    if yy is null and m > mx then m := (m - interval '1 year')::date; end if;
  end if;$r$);
    d := replace(d, 'y := bi.api_force1((select max(created_month) from bi.point_derived), f);',
                    'y := bi.api_force1(least(m, (select max(created_month) from bi.point_derived)), f);');
    if d = d0 or position('mm int;' in d) = 0 or position('least(m, (select max(created_month)' in d) = 0 or position('make_date(' in d) = 0 then raise exception 'bi_ask patch incomplete'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_ask(text,jsonb,uuid) to anon, authenticated;
