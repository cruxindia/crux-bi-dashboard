-- Applied to Supabase project via MCP on 20261029055958
-- bi_097k (29-Oct-2026): acceptance T28 found two different month-end projections on the page (Overview 62,077, Business Tracker potential 61,890).
-- Cause: when a past month has two reports with the same working-day count (Saturday and Sunday, e.g. 26- and 27-Sep-2026), the forecast counted
-- that month twice in the curve average; the potential view used one report per month (the later one, as "same working day last month" does).
-- Fix: the forecast also uses one report per past month — the latest with that working-day count — so every month weighs the same.
do $do$
declare d text := pg_get_functiondef('bi.api_forecast(date,jsonb)'::regprocedure);
        o1 text := $o$r as (select s.report_month, s.mtd / nullif(fin.final,0) frac from s join fin on fin.month=s.report_month$o$;
        n1 text := $n$r as (select distinct on (s.report_month) s.report_month, s.mtd / nullif(fin.final,0) frac from s join fin on fin.month=s.report_month$n$;
        o2 text := $o$where bi.workdays(s.report_month, s.snapshot_date) = v_k)$o$;
        n2 text := $n$where bi.workdays(s.report_month, s.snapshot_date) = v_k order by s.report_month, s.snapshot_date desc)$n$;
begin
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'api_forecast fragment 1 not found exactly once'; end if;
  if (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'api_forecast fragment 2 not found exactly once'; end if;
  execute replace(replace(d, o1, n1), o2, n2);
end $do$;
