-- Applied to Supabase project via MCP on 20261014220344
create or replace function bi.run_wave_tests()
returns table(test text, passed boolean, detail jsonb)
language plpgsql security definer set search_path to 'bi', 'public', 'extensions' as $function$
declare m date := date_trunc('month', (select max(snapshot_date) from bi.zt_snapshot))::date; a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; z text; l text;
        ok boolean; err text; r record; tgt int; wef date; n_before int; n_after int; n_moved int; pv jsonb; ap jsonb; res jsonb := '{}'::jsonb;
        k_valid text := 'T38-valid-' || md5(random()::text); k_exp text := 'T38-exp-' || md5(random()::text);
        k_rev text := 'T38-rev-' || md5(random()::text); k_job text := 'T38-job-' || md5(random()::text);
        pen jsonb := jsonb_build_object('op', 'add', 'date', (now() at time zone 'Asia/Kolkata')::date, 'location_id', (select id from bi.location where label = 'Pune'),
                                        'amount', 100, 'reason', 'T38 authorisation test', 'editor', 'test');
        outcomes jsonb := '{}'::jsonb; msg text;
begin
  a := bi.api_drill(m, '{}', 'zone');
  select x->>'id' into z from jsonb_array_elements(a->'children') x order by (x->>'mtd')::numeric desc limit 1;
  b := bi.api_drill(m, jsonb_build_object('zone_group', z), 'location');
  select x->>'id' into l from jsonb_array_elements(b->'children') x order by (x->>'mtd')::numeric desc limit 1;
  c := bi.api_drill(m, jsonb_build_object('zone_group', z, 'location_id', l::int), 'client');
  test := 'T39 drill-down: Pan India = Σ zones, zone = Σ locations, location = Σ clients; parent shown';
  passed := (a->'selected'->>'mtd')::numeric = (select sum((x->>'mtd')::numeric) from jsonb_array_elements(a->'children') x)
        and (b->'selected'->>'mtd')::numeric = (select sum((x->>'mtd')::numeric) from jsonb_array_elements(b->'children') x)
        and (c->'selected'->>'mtd')::numeric = (select sum((x->>'mtd')::numeric) from jsonb_array_elements(c->'children') x)
        and (b->'parent'->>'mtd')::numeric = (a->'selected'->>'mtd')::numeric
        and (a->'selected'->>'mtd')::numeric = (bi.api_overview(m, '{}')->>'mtd_cases')::numeric
        and not exists (select 1 from jsonb_array_elements(a->'children') x where x->>'id' is null)
        and not exists (select 1 from jsonb_array_elements(b->'children') x where x->>'id' is null)
        and jsonb_array_length(a->'history') between 1 and 12;
  detail := jsonb_build_object('month', m, 'pan', a->'selected'->'mtd', 'zone', z, 'zone_mtd', b->'selected'->'mtd', 'location', l, 'location_mtd', c->'selected'->'mtd'); return next;

  d := bi.api_drill(m, jsonb_build_object('location_id', l::int), 'branch');
  e := bi.api_branch_detail(jsonb_build_object('client_family', d->'branches'->0->>'client_family', 'branch_code', d->'branches'->0->>'branch_code'));
  test := 'T40 branch list (Force1 cases) and branch detail agree for the month';
  passed := jsonb_array_length(d->'branches') > 0
        and (select (x->>'cases')::int from jsonb_array_elements(e->'months') x where (x->>'month')::date = m) >= (d->'branches'->0->>'cases_month')::int
        and (d->>'force1_cases_month')::int >= (select coalesce(sum((x->>'cases_month')::int), 0) from jsonb_array_elements(d->'branches') x);
  detail := jsonb_build_object('branch', d->'branches'->0, 'detail_months', e->'months', 'force1_total', d->'force1_cases_month'); return next;

  begin
    insert into bi.ingest_token(token_hash, label, expires_at, revoked, scope) values
      (encode(extensions.digest(k_valid, 'sha256'), 'hex'), 'T41 valid', now() + interval '1 hour', false, 'admin'),
      (encode(extensions.digest(k_exp, 'sha256'), 'hex'), 'T41 expired', now() - interval '1 minute', false, 'admin'),
      (encode(extensions.digest(k_rev, 'sha256'), 'hex'), 'T41 revoked', now() + interval '1 hour', true, 'admin'),
      (encode(extensions.digest(k_job, 'sha256'), 'hex'), 'T41 job', now() + interval '1 hour', false, 'job');
    for r in select * from (values ('no key', null::text), ('wrong key', 'not-a-real-key-123456'), ('expired', k_exp), ('revoked', k_rev), ('job token', k_job), ('valid', k_valid)) v(name, key) loop
      begin
        perform public.bi_admin('penalty', pen || coalesce(jsonb_build_object('admin_key', r.key), '{}'::jsonb));
        outcomes := outcomes || jsonb_build_object('penalty ' || r.name, 'allowed');
      exception when others then outcomes := outcomes || jsonb_build_object('penalty ' || r.name, 'refused: ' || left(sqlerrm, 40)); end;
      begin
        perform public.bi_admin('mapping_retarget', jsonb_build_object('kind', 'history', 'admin_key', r.key));
        outcomes := outcomes || jsonb_build_object('mapping ' || r.name, 'allowed');
      exception when others then outcomes := outcomes || jsonb_build_object('mapping ' || r.name, 'refused: ' || left(sqlerrm, 40)); end;
    end loop;
    raise exception 'rollback_t41';
  exception when others then err := sqlerrm; end;
  test := 'T41 penalty and mapping changes need a valid, unexpired, unrevoked admin key; anon has no direct access';
  passed := err = 'rollback_t41'
        and outcomes->>'penalty valid' = 'allowed' and outcomes->>'mapping valid' = 'allowed'
        and (select bool_and(value like 'refused%') from jsonb_each_text(outcomes) where key not like '% valid')
        and not has_schema_privilege('anon', 'bi', 'usage')
        and not exists (select 1 from bi.penalty where reason = 'T41 authorisation test' or reason = 'T38 authorisation test')
        and not exists (select 1 from bi.ingest_token where label like 'T41%');
  detail := outcomes; return next;

  ok := false; err := null;
  select la.id, la.location_id, la.alias into r from bi.location_alias la
   where la.source = 'zonal_label' and la.review_status <> 'rejected'
     and (select count(distinct snapshot_date) from bi.zt_row z where bi.norm(z.location_label) = la.alias) >= 10
   order by la.id limit 1;
  select id into tgt from bi.location where id <> r.location_id and zone_group is not null order by id limit 1;
  select snapshot_date into wef from (select distinct snapshot_date from bi.zt_row z where bi.norm(z.location_label) = r.alias order by 1) s
   offset (select count(distinct snapshot_date) / 2 from bi.zt_row z where bi.norm(z.location_label) = r.alias) limit 1;
  select count(*) into n_before from bi.zt_row z where bi.norm(z.location_label) = r.alias and z.snapshot_date < wef and z.location_id = r.location_id;
  begin
    pv := bi.mapping_retarget('test', jsonb_build_object('kind', 'location_alias', 'id', r.id, 'target', tgt, 'effective_from', wef));
    begin perform bi.mapping_retarget('test', jsonb_build_object('kind', 'location_alias', 'id', r.id, 'target', tgt, 'effective_from', wef, 'apply', true));
          msg := 'applied without reason'; exception when others then msg := sqlerrm; end;
    ap := bi.mapping_retarget('test', jsonb_build_object('kind', 'location_alias', 'id', r.id, 'target', tgt, 'effective_from', wef, 'apply', true, 'reason', 'T42 retarget test'));
    select count(*) into n_after from bi.zt_row z where bi.norm(z.location_label) = r.alias and z.snapshot_date < wef and z.location_id = r.location_id;
    select count(*) into n_moved from bi.zt_row z where bi.norm(z.location_label) = r.alias and z.snapshot_date >= wef and z.location_id = tgt;
    ok := (pv->>'applied')::boolean = false and (pv->'affected'->>'tracker_rows')::int > 0 and msg like 'A reason%'
          and n_after = n_before and n_moved = (pv->'affected'->>'tracker_rows')::int
          and (select location_id from bi.location_alias where id = r.id) = tgt
          and exists (select 1 from bi.mapping_correction where alias = r.alias and new_target = tgt::text and effective_from = wef and reason = 'T42 retarget test');
    raise exception 'rollback_t42';
  exception when others then err := sqlerrm; end;
  test := 'T42 mapping correction moves only records from the effective date, needs a reason and keeps history';
  passed := ok and err = 'rollback_t42' and (select location_id from bi.location_alias where id = r.id) = r.location_id
            and not exists (select 1 from bi.mapping_correction where reason = 'T42 retarget test');
  detail := jsonb_build_object('alias_id', r.id, 'effective_from', wef, 'preview', pv - 'note', 'rows_before_wef_unchanged', n_before, 'rows_moved', n_moved, 'no_reason', msg, 'error', nullif(err, 'rollback_t42')); return next;
end $function$;
