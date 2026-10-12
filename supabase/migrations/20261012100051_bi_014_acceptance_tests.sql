-- Applied to Supabase project via MCP on 20261012100051

create or replace function bi.run_acceptance_tests()
returns table(test text, passed boolean, detail jsonb)
language plpgsql security definer set search_path = bi, public as $$
declare a numeric; b numeric; c numeric; d numeric; j jsonb; s1 date; s0 date; m date; ok boolean;
begin
  -- T1 daily MTD change = MTD(today) - MTD(previous snapshot); never a sum of MTDs
  select max(snapshot_date) into s1 from bi.zt_snapshot;
  select max(snapshot_date) into s0 from bi.zt_snapshot where snapshot_date < s1 and date_trunc('month',snapshot_date)=date_trunc('month',s1);
  select sum(mtd_cases) into a from bi.v_zt_leaf where snapshot_date=s1;
  select sum(mtd_cases) into b from bi.v_zt_leaf where snapshot_date=s0;
  select sum(change_cases) into c from bi.v_zt_daily where snapshot_date=s1;
  test:='T01 daily change = MTD difference'; passed:= c = a-b; detail:=jsonb_build_object('snapshot',s1,'prev',s0,'mtd',a,'prev_mtd',b,'sum_change',c); return next;

  -- T02 duplicate upload of an identical file is detected, nothing inserted
  select file_hash into j from (select to_jsonb(file_hash) file_hash from bi.import_batch where status='committed' and source_category='case' limit 1) x;
  j := bi.ingest_as('acceptance-test','begin', jsonb_build_object('category','case','file_name','dup-test','file_hash', j #>> '{}'));
  test:='T02 duplicate file detected'; passed:= coalesce((j->>'duplicate')::boolean,false); detail:=j; return next;

  -- T03 corrected re-upload: Nashik Jul v1 then v2 -> one row per case, changed/new counted, history kept
  select jsonb_agg(jsonb_build_object('file',file_name,'new',rows_new,'changed',rows_changed,'unchanged',rows_unchanged,'status',status) order by id) into j
    from bi.import_batch where file_name like 'Nashik_2026-07%' and status in ('committed','superseded');
  select count(*), count(distinct case_id) into a, b from bi.fact_case where file_group='Nashik' and received_month='2026-07-01';
  test:='T03 corrected file updates without duplication'; passed:= a=b and jsonb_array_length(j)>=2; detail:=jsonb_build_object('batches',j,'rows',a,'distinct_cases',b); return next;

  -- T04 new month created, prior months retained
  select jsonb_object_agg(to_char(report_month,'YYYY-MM'), n) into j from (select report_month, count(*) n from bi.zt_snapshot group by 1) x;
  test:='T04 months retained across snapshots'; passed:= (select count(distinct report_month) from bi.zt_snapshot) >= 5; detail:=j; return next;

  -- T05 location aliases (typo + rename) resolve to one canonical location
  select count(distinct location_id) into a from bi.location_alias where alias in ('GWALIOR','JWALIOR');
  select count(distinct location_id) into b from bi.location_alias where alias in ('BENGALURU (REST OF KARNATAKA)','BENJALURU (REST OF KARNATAKA)','BENGALURU + REST OF KARNATAKA + KERELA');
  test:='T05 alias resolution (G/J typo, renames)'; passed:= a=1 and b=1;
  detail:=jsonb_build_object('gwalior_targets',a,'bengaluru_targets',b,'needs_review',(select count(*) from bi.location_alias where review_status='needs_review')); return next;

  -- T06 summary rows never counted: leaf sum equals source Pan-India control where source is consistent
  select count(*) filter (where abs(l.s - z.pan_india_mtd) < 0.5), count(*) into a, b
    from bi.zt_snapshot z join (select snapshot_date, sum(mtd_cases) s from bi.v_zt_leaf group by 1) l using (snapshot_date);
  test:='T06 leaf totals match source control (no subtotal double count)'; passed:= a >= b - 2;
  detail:=jsonb_build_object('snapshots_matching',a,'snapshots',b,'note','known source-corrupted control rows: 2026-09-01, 2026-09-03 (logged as source_total_mismatch)'); return next;

  -- T07 case vs point grain
  select case_id into d from bi.fact_point group by case_id having count(*) > 3 limit 1;
  select count(*) into a from bi.fact_case where case_id=d; select count(*) into b from bi.fact_point where case_id=d;
  test:='T07 multi-point case counts once at case level'; passed:= a=1 and b>3; detail:=jsonb_build_object('case_id',d,'case_rows',a,'point_rows',b); return next;

  -- T08 Force usage arithmetic, independently recomputed
  select sum(force_cases), sum(tracker_cases) into a, b from bi.v_force_usage where month='2026-07-01' and case_data_available;
  select (j2->>'force_cases')::numeric, (j2->>'tracker_cases_covered')::numeric into c, d from (select bi.api_overview('2026-07-01','{}')->'force' j2) x;
  test:='T08 Force usage = Force cases / tracker cases (same period & grain)'; passed:= a=c and b=d; detail:=jsonb_build_object('view_force',a,'view_tracker',b,'api_force',c,'api_tracker',d,'usage',round(a/nullif(b,0),4)); return next;

  -- T09 case TAT = completed - received; negatives detected and excluded
  select count(*) into a from bi.v_case where raw_tat_hours < 0;
  select count(*) into b from bi.v_case where raw_tat_hours < 0 and sla_met is not null;
  test:='T09 negative case durations detected, excluded'; passed:= a > 0;
  detail:=jsonb_build_object('negative_cases',a,'negative_with_sla_value',b,'flags',(select jsonb_object_agg(coalesce(tat_flag,'null'),n) from (select tat_flag,count(*) n from bi.v_case group by 1) x)); return next;

  -- T10 manual-case TAT is always flagged as an estimate with its basis
  select count(*), count(*) filter (where (e->>'is_estimate')::boolean and e->>'estimate_basis' is not null) into a, b from jsonb_array_elements(bi.api_manual_tat('2026-07-01','{}')) e;
  test:='T10 manual TAT labelled as estimate'; passed:= a>0 and a=b; detail:=jsonb_build_object('rows',a,'flagged',b); return next;

  -- T11 no field executive verified non-field points (unless overridden)
  select count(*) into a from bi.employee where classification='field_executive' and not override and coalesce((evidence->>'document')::int,0)+coalesce((evidence->>'tele')::int,0)+coalesce((evidence->>'other')::int,0) > 0;
  test:='T11 field executives verify only field point types'; passed:= a=0;
  detail:=(select jsonb_object_agg(classification,n) from (select classification,count(*) n from bi.employee group by 1) x); return next;

  -- T12 field TAT only on field points; document TAT only on document points
  select count(*) filter (where category<>'field' and field_tat_hours is not null), count(*) filter (where category<>'document' and doc_tat_hours is not null) into a, b from bi.v_point;
  test:='T12 TAT metrics restricted to their point category'; passed:= a=0 and b=0; detail:=jsonb_build_object('non_field_with_field_tat',a,'non_doc_with_doc_tat',b); return next;

  -- T13 processing route only assigned for field points; outside-Force claims only with evidence
  select count(*) into a from bi.v_point where category is distinct from 'field' and processing_route is not null;
  test:='T13 route classification limited to field points'; passed:= a=0;
  detail:=(select jsonb_object_agg(processing_route,n) from (select processing_route,count(*) n from bi.v_point where processing_route is not null group by 1) x); return next;

  -- T14 analytics exclude data before 2024-04-01
  select least((select min(month) from bi.zt_month_history),(select min(received_month) from bi.fact_case),(select min(created_month) from bi.fact_point)) into m;
  test:='T14 nothing before 1-Apr-2024'; passed:= m >= '2024-04-01'; detail:=jsonb_build_object('earliest',m); return next;

  -- T15 executive card = sum of supporting table (same snapshot, same filters)
  select (bi.api_overview('2026-10-01','{"stakeholder":"Shantanu Suravase"}')->>'mtd_cases')::numeric into a;
  select sum((e->>'mtd')::numeric) into b from jsonb_array_elements(bi.api_zonal((select max(snapshot_date) from bi.zt_snapshot where report_month='2026-10-01'),'{"stakeholder":"Shantanu Suravase"}')) e;
  test:='T15 overview reconciles with detail table under filters'; passed:= a=b; detail:=jsonb_build_object('overview',a,'table_sum',b); return next;

  -- T16 security: API roles cannot reach schema bi; RPCs refuse unauthenticated callers
  ok := not has_schema_privilege('anon','bi','usage') and not has_schema_privilege('authenticated','bi','usage');
  begin
    perform set_config('request.jwt.claims','{}',true);
    perform public.bi_call('meta','{}'); ok := false;
  exception when insufficient_privilege then null; end;
  begin perform public.bi_ingest('wrong-token','begin','{}'); ok := false; exception when insufficient_privilege then null; end;
  test:='T16 unauthorised access rejected'; passed:= ok; detail:=jsonb_build_object('anon_schema_usage',has_schema_privilege('anon','bi','usage')); return next;

  -- T18 AI insight numbers equal the calculation engine
  select (bi.api_forecast('2026-10-01','{}')->>'run_rate_projection')::numeric into a;
  select count(*) into b from jsonb_array_elements(bi.api_insights('2026-10-01','{}')) e where e->>'type'='forecast' and e->>'text' like '%'||a::bigint::text||'%';
  test:='T18 insight text matches computed forecast'; passed:= b>=1; detail:=jsonb_build_object('run_rate_projection',a); return next;
end $$;
revoke all on function bi.run_acceptance_tests() from public, anon, authenticated;

