-- Applied to Supabase project via MCP on 20261029150234
-- Wave 098: once holidays are declared in the report calendar, comparing "the same working day number" with past months (whose holidays were
-- never declared) overstates the month-end curve (Oct-2026: 63,043 → 68,311 after marking 2-Oct and 20-Oct). Past months are now matched on the
-- same number of working days LEFT in the month, so a holiday already passed does not move the curve and a declared future holiday lowers it.
-- Overview forecast and Business Tracker potential stay consistent (acceptance T28).
do $mig$
declare d text; a text; b text;
begin
  d := pg_get_functiondef('bi.api_forecast(date,jsonb)'::regprocedure);
  a := 'where bi.workdays(s.report_month, s.snapshot_date) = v_k order by s.report_month, s.snapshot_date desc)';
  b := 'where bi.workdays(s.snapshot_date + 1, (s.report_month + interval ''1 month - 1 day'')::date) = v_total - v_k order by s.report_month, s.snapshot_date desc)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_forecast fragment'; end if;
  d := replace(d, a, b);
  d := replace(d, 'Curve = MTD / average share of month-end volume reached by the same working day in past months',
                  'Curve = MTD / average share of month-end volume reached in past months with the same number of working days left');
  execute d;

  d := pg_get_functiondef('bi.api_potential(date,jsonb,text,text)'::regprocedure);
  a := 'bi.workdays(lf.mon, lf.d) wk from leaf lf';
  b := 'bi.workdays(lf.mon, lf.d) wk, bi.workdays(lf.d + 1, (lf.mon + interval ''1 month - 1 day'')::date) wr from leaf lf';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_potential fragment 1'; end if;
  d := replace(d, a, b);
  a := 'where s.mon < m and s.wk = k group by 1, 2)';
  b := 'where s.mon < m and s.wr = rem group by 1, 2)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_potential fragment 2'; end if;
  execute replace(d, a, b);
end $mig$;
