-- Applied to Supabase project via MCP on 20261029060421
-- bi_097l (29-Oct-2026): acceptance T28 led to a double count. The tracker files of 26/27-Oct also carry month totals (Jan–Sep 2026) for every row;
-- they were written to the month history under the new Amaravati team location before that label was mapped to Amaravati. The retarget moved the
-- tracker rows but not the month history, so Aug-26 (349 cases) and Sep-26 (389 cases) were counted under both locations in month totals.
-- (1) Month-history rows can be marked superseded (kept for audit, never removed); month totals ignore them.
-- (2) A tracker-label retarget now also carries the month history written from that label's rows on or after the effective date: moved to the
--     new location, or — when the new location already holds that month and client — marked superseded (the newer report's values kept on the target).
-- (3) bi.test_identity I16: no month-history row stays counted under the old location of a retargeted tracker label.
alter table bi.zt_month_history add column if not exists superseded_by integer references bi.location(id),
  add column if not exists superseded_at timestamptz, add column if not exists superseded_reason text;

create or replace view bi.v_month_business as
 WITH snap AS (
         SELECT l.report_month AS month, l.location_id, l.client_code, l.target_cases, l.mtd_cases, l.revenue_target, l.revenue_actual, l.snapshot_date
           FROM (bi.v_zt_leaf l
             JOIN bi.v_latest_snapshot ls ON (((ls.report_month = l.report_month) AND (ls.snapshot_date = l.snapshot_date))))
        ), hist AS (
         SELECT h_1.month, h_1.location_id, h_1.client_code, h_1.cases, h_1.revenue, h_1.billing, h_1.source_snapshot, h_1.source_columns
           FROM bi.zt_month_history h_1
          WHERE (NOT (EXISTS ( SELECT 1 FROM bi.location lx WHERE ((lx.id = h_1.location_id) AND lx.is_rollup)))) AND h_1.superseded_by IS NULL
        )
 SELECT COALESCE(h.month, s.month) AS month,
    COALESCE(h.location_id, s.location_id) AS location_id,
    COALESCE(h.client_code, s.client_code) AS client_code,
    COALESCE(h.cases, s.mtd_cases) AS cases,
    COALESCE(h.revenue, s.revenue_actual) AS revenue,
    h.billing,
    s.target_cases,
    s.revenue_target,
        CASE
            WHEN (h.month IS NOT NULL) THEN 'tracker_history'::text
            ELSE 'tracker_snapshot'::text
        END AS cases_source,
    COALESCE(s.snapshot_date, h.source_snapshot) AS as_of,
    s.mtd_cases AS month_end_snapshot_mtd
   FROM (hist h
     FULL JOIN snap s ON (((s.month = h.month) AND (s.location_id = h.location_id) AND (s.client_code = h.client_code))));

do $do$
declare d text := pg_get_functiondef('bi.mapping_retarget(text,jsonb)'::regprocedure); i int;
        r text[][] := array[
  [$o$n_zt int := 0; n_cs int := 0;$o$, $n$n_zt int := 0; n_h int := 0; n_cs int := 0;$n$],
  [$o$into n_zt, snaps from bi.zt_row
       where bi.norm(location_label) = la.alias and snapshot_date >= wef and location_id is distinct from newloc;$o$,
   $n$into n_zt, snaps from bi.zt_row
       where bi.norm(location_label) = la.alias and snapshot_date >= wef and location_id is distinct from newloc;
      select count(*) into n_h from bi.zt_month_history h
       where h.location_id = la.location_id and h.superseded_by is null and h.source_snapshot >= wef
         and exists (select 1 from bi.zt_row zr where bi.norm(zr.location_label) = la.alias and zr.snapshot_date = h.source_snapshot and zr.client_code = h.client_code);$n$],
  [$o$aff := jsonb_build_object('tracker_rows', n_zt, 'tracker_snapshots', snaps, 'force1_cases', n_cs);$o$,
   $n$aff := jsonb_build_object('tracker_rows', n_zt, 'tracker_snapshots', snaps, 'force1_cases', n_cs, 'month_history_rows', n_h);$n$],
  [$o$update bi.zt_row set location_id = newloc where bi.norm(location_label) = la.alias and snapshot_date >= wef and location_id is distinct from newloc;$o$,
   $n$update bi.zt_row set location_id = newloc where bi.norm(location_label) = la.alias and snapshot_date >= wef and location_id is distinct from newloc;
        -- month history written from this label's rows on or after the effective date follows them (never counted under two locations)
        update bi.zt_month_history t set cases = h.cases, revenue = h.revenue, billing = h.billing, source_snapshot = h.source_snapshot, source_columns = h.source_columns
          from bi.zt_month_history h
         where h.location_id = la.location_id and h.superseded_by is null and h.source_snapshot >= wef
           and exists (select 1 from bi.zt_row zr where bi.norm(zr.location_label) = la.alias and zr.snapshot_date = h.source_snapshot and zr.client_code = h.client_code)
           and t.location_id = newloc and t.month = h.month and t.client_code = h.client_code and t.superseded_by is null and t.source_snapshot < h.source_snapshot;
        update bi.zt_month_history h set superseded_by = newloc, superseded_at = now(), superseded_reason = 'tracker label ' || la.alias || ' retargeted from ' || wef || '; location ' || newloc || ' holds this month'
         where h.location_id = la.location_id and h.superseded_by is null and h.source_snapshot >= wef
           and exists (select 1 from bi.zt_row zr where bi.norm(zr.location_label) = la.alias and zr.snapshot_date = h.source_snapshot and zr.client_code = h.client_code)
           and exists (select 1 from bi.zt_month_history t where t.location_id = newloc and t.month = h.month and t.client_code = h.client_code);
        update bi.zt_month_history h set location_id = newloc
         where h.location_id = la.location_id and h.superseded_by is null and h.source_snapshot >= wef
           and exists (select 1 from bi.zt_row zr where bi.norm(zr.location_label) = la.alias and zr.snapshot_date = h.source_snapshot and zr.client_code = h.client_code);$n$]];
begin
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'mapping_retarget fragment % not found exactly once', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
  d := pg_get_functiondef('bi.test_identity()'::regprocedure);
  if (length(d) - length(replace(d, $o$detail := run->'client'; return next;$o$, ''))) / length($o$detail := run->'client'; return next;$o$) <> 1 then raise exception 'test_identity fragment'; end if;
  execute replace(d, $o$detail := run->'client'; return next;$o$, $n$detail := run->'client'; return next;
  test := 'I16 month history: nothing stays counted under the old location of a retargeted tracker label (month totals never count one row twice)';
  select count(*) into c from bi.zt_month_history h join bi.mapping_correction mc on mc.source = 'zonal_label' and mc.old_target = h.location_id::text
   where h.superseded_by is null and h.source_snapshot >= mc.effective_from
     and exists (select 1 from bi.zt_row zr where bi.norm(zr.location_label) = mc.alias and zr.snapshot_date = h.source_snapshot and zr.client_code = h.client_code);
  passed := c = 0; detail := jsonb_build_object('rows_left_at_old_location', c, 'superseded_rows', (select count(*) from bi.zt_month_history where superseded_by is not null)); return next;$n$);
end $do$;
