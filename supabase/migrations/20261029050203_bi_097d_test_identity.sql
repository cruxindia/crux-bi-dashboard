-- Applied to Supabase project via MCP on 20261029050203
-- bi_097d (29-Oct-2026): acceptance test for canonical identity — known examples per source (expected values come from the mapping documents,
-- not from current output) plus reconciliation checks on the latest identity run.
create or replace function bi.test_identity() returns table(test text, passed boolean, detail jsonb) language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare run jsonb := (select summary from bi.identity_run where status = 'succeeded' order by id desc limit 1);
        loc_pune int := (select id from bi.location where upper(label) = 'PUNE' and not coalesce(is_rollup, false) limit 1);
        loc_jal int := (select id from bi.location where upper(label) = 'JALGAON' and not coalesce(is_rollup, false) limit 1);
        loc_mum int := (select id from bi.location where upper(label) = 'MUMBAI' and not coalesce(is_rollup, false) limit 1);
        loc_ned int := (select id from bi.location where upper(label) = 'NANDED' and not coalesce(is_rollup, false) limit 1);
        loc_amr int := (select id from bi.location where upper(label) = 'AMARAVATI' and not coalesce(is_rollup, false) limit 1);
        loc_ny int := 30;   -- the two Nagpur team locations (ids 30 and 31)
        loc_ns int := 31;
        v int; t text; c bigint;
begin
  -- tracker
  test := 'I01 tracker: a known label with a team suffix added resolves to the existing location (every "Amaravati (…)" label → Amaravati)';
  select count(*), count(*) filter (where location_id = loc_amr) into c, v from bi.location_alias where source = 'zonal_label' and alias like 'AMARAVATI (%';
  passed := c > 0 and v = c and bi.resolve_location_suffix_base('Amaravati (Team X)') = 'AMARAVATI'
            and (select location_id from bi.location_alias where source = 'zonal_label' and alias = 'AMARAVATI') = loc_amr;
  detail := jsonb_build_object('labels', c, 'to_amaravati', v); return next;
  test := 'I02 tracker: every leaf row of the latest report has a location and a client';
  passed := (run->'tracker'->>'latest_unmapped')::int = 0 and (run->'tracker'->>'locations_without_zone')::int = 0;
  detail := run->'tracker'; return next;
  -- Case Wise rules (rule book 27-Oct)
  test := 'I03 case rule 1: area office "PUNE EAST" → Pune (direction removed)';
  t := bi.place_of_area_office('PUNE EAST', null); passed := t = 'Pune' and bi.loc_of_place(t, 'x') = loc_pune; detail := jsonb_build_object('place', t); return next;
  test := 'I04 case rule 3: branch name "SBI SHIVCOLONY JALGAON" → Jalgaon';
  t := bi.place_of_branch('SBI SHIVCOLONY JALGAON'); passed := t = 'Jalgaon' and bi.loc_of_place(t, 'x') = loc_jal; detail := jsonb_build_object('place', t); return next;
  test := 'I05 case rule 5: residence pincode 440010 → Nagpur';
  t := bi.place_of_pin('440010'); passed := t = 'Nagpur'; detail := jsonb_build_object('place', t); return next;
  test := 'I06 Nagpur places follow the team of the file (the second team''s file → location 31; otherwise location 30)';
  passed := bi.loc_of_place('Nagpur', 'sudhir') = loc_ns and bi.loc_of_place('Nagpur', 'x') = loc_ny; detail := jsonb_build_object('sudhir', bi.loc_of_place('Nagpur', 'sudhir'), 'other', bi.loc_of_place('Nagpur', 'x')); return next;
  test := 'I07 Case Wise records: a case whose area office is "PUNE EAST" and whose branch name names no other place is stored in Pune';
  select count(*), count(*) filter (where cs.location_id = loc_pune) into c, v from bi.case_store cs join bi.dim d on d.id = cs.area_office_id
   where upper(btrim(d.val)) = 'PUNE EAST' and (bi.place_of_branch((select val from bi.dim where id = cs.branch_id)) is null or bi.place_of_branch((select val from bi.dim where id = cs.branch_id)) = 'Pune');
  passed := c > 0 and v = c; detail := jsonb_build_object('cases', c, 'in_pune', v); return next;
  test := 'I08 Case Wise: stored location = full run of the rules for every case; Σ by location = all cases';
  passed := (run->'case'->>'stored_differs_from_rules')::int = 0 and (run->'case'->>'sum_by_location_equals_rows')::boolean;
  detail := jsonb_build_object('differs', run->'case'->'stored_differs_from_rules', 'not_identified', run->'case'->'not_identified', 'ambiguous', run->'case'->'ambiguous_area_office_vs_branch'); return next;
  -- Point Wise
  test := 'I09 Point Wise: a point follows its case only when the case exists and the branch agrees; others are placed on their own evidence';
  select count(*) into c from bi.point_store ps join bi.case_store cs on cs.case_id = ps.case_id
   where ps.branch_id is not distinct from cs.branch_id and exists (select 1 from bi.point_loc pl where pl.point_id = ps.point_id and pl.active);
  passed := c = 0 and not exists (select 1 from bi.point_store ps where not exists (select 1 from bi.case_store cs where cs.case_id = ps.case_id)
                                    and not exists (select 1 from bi.point_loc pl where pl.point_id = ps.point_id and pl.active));
  detail := jsonb_build_object('proven_points_overridden', c, 'point', run->'point'); return next;
  test := 'I10 Point Wise: a point placed by its branch name gets the location of that place';
  select count(*), count(*) filter (where pl.location_id is distinct from bi.loc_of_place(bi.place_of_branch((select val from bi.dim where id = ps.branch_id)), ps.file_group))
    into c, v from bi.point_loc pl join bi.point_store ps on ps.point_id = pl.point_id where pl.active and pl.basis = 'place in the point''s branch name';
  passed := c > 0 and v = 0; detail := jsonb_build_object('points', c, 'mismatched', v); return next;
  test := 'I11 Point Wise: every point is counted once in the derived table (no loss, no double count)';
  passed := (select count(*) from bi.point_derived) = (select count(*) from bi.point_store where created_at >= '2024-03-31 18:30:00+00');
  detail := jsonb_build_object('derived', (select count(*) from bi.point_derived), 'source', (select count(*) from bi.point_store)); return next;
  -- Finance
  test := 'I12 invoice series MUM → Mumbai; a receipt from Bank of Maharashtra branch 2483 → Nanded (its branch-master location)';
  passed := (select location_id from bi.fin_loc_map where key_type = 'prefix' and key = 'MUM') = loc_mum and (bi.loc_of_payer('BOM', '2483', null)).location_id = loc_ned;
  detail := jsonb_build_object('mum', (select location_id from bi.fin_loc_map where key_type = 'prefix' and key = 'MUM'), 'payer', (bi.loc_of_payer('BOM', '2483', null)).location_id); return next;
  test := 'I13 finance totals reconcile to the workbooks (bi.test_fin_attr all pass)';
  passed := not exists (select 1 from bi.test_fin_attr() x where not x.passed); detail := jsonb_build_object('fin_attr_tests', (select count(*) from bi.test_fin_attr())); return next;
  -- Clients
  test := 'I14 clients: tracker "BOM MSME PRE" → BOM_MSME_PRE; finance text "MSME" → BOM; "Bank of Maharashtra" → BOM';
  passed := (select client_code from bi.client_alias where source = 'zonal' and alias = 'BOM MSME PRE') = 'BOM_MSME_PRE'
            and (select family from bi.fin_client_map where key = 'msme') = 'BOM' and (select family from bi.client_name_alias where alias = 'bank of maharashtra') = 'BOM';
  detail := null; return next;
  test := 'I15 clients: no tracker row or case without a known client';
  passed := (run->'client'->>'tracker_rows_without_client')::int = 0 and (run->'client'->>'cases_with_unknown_client')::int = 0; detail := run->'client'; return next;
end $f$;
