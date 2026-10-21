-- Applied to Supabase project via MCP on 20261021075202
do $do$
declare d text := pg_get_functiondef('bi.ask_h_health(date,jsonb)'::regprocedure); a text; b text;
begin
  a := $a$  for ctl in select s.snapshot_date, s.pan_india_mtd, (select sum(mtd_cases) from bi.v_zt_leaf l where l.snapshot_date = s.snapshot_date) leaf
             from bi.zt_snapshot s where s.report_month in (m, (m - interval '1 month')::date) order by 1 desc loop$a$;
  b := $b$  for ctl in select s.snapshot_date, s.pan_india_mtd, lf.leaf
             from bi.zt_snapshot s
             left join (select r.snapshot_date, sum(r.mtd_cases) leaf from bi.zt_row r join bi.zt_snapshot s2 using (snapshot_date)
                         where r.row_type = 'leaf' and r.location_id is not null and s2.report_month in (m, (m - interval '1 month')::date)
                           and not exists (select 1 from bi.location lx where lx.id = r.location_id and lx.is_rollup) group by 1) lf using (snapshot_date)
             where s.report_month in (m, (m - interval '1 month')::date) order by 1 desc loop$b$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'anchor'; end if;
  execute replace(d, a, b);
end $do$;
