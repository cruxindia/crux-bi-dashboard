-- Applied to Supabase project via MCP on 20261029150100
-- Wave 098: wire the report calendar into the admin API; the daily update table and the month-end potential use the active, non-working days.
do $mig$
declare dd text; a text; b text;
begin
  dd := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
  a := '    when ''matrix_no_report'' then return bi.matrix_mark_no_report(''admin-key'', (p->>''date'')::date, p->>''reason'');';
  b := a || chr(10) || '    when ''report_calendar'' then return bi.report_calendar_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');';
  if (length(dd) - length(replace(dd, a, ''))) / length(a) <> 1 then raise exception 'bi_admin fragment'; end if;
  execute replace(dd, a, b);

  dd := pg_get_functiondef('bi.api_matrix(date,date)'::regprocedure);
  a := 'when exists (select 1 from bi.report_calendar_exception e where e.report_date = dt) then ''no_report''';
  b := 'when exists (select 1 from bi.report_calendar_exception e where e.report_date = dt and e.active) then ''no_report''';
  if (length(dd) - length(replace(dd, a, ''))) / length(a) <> 1 then raise exception 'api_matrix fragment 1'; end if;
  dd := replace(dd, a, b);
  a := '(select reason from bi.report_calendar_exception where report_date = dt) no_report_reason,';
  b := '(select reason || coalesce('' — '' || note, '''') from bi.report_calendar_exception where report_date = dt and active) no_report_reason,';
  if (length(dd) - length(replace(dd, a, ''))) / length(a) <> 1 then raise exception 'api_matrix fragment 2'; end if;
  execute replace(dd, a, b);

  dd := pg_get_functiondef('bi.api_potential(date,jsonb,text,text)'::regprocedure);
  a := 'rem := greatest(0, bi.workdays(asof + 1, me) - (select count(*) from bi.report_calendar_exception e where e.report_date > asof and e.report_date <= me and extract(isodow from e.report_date) <> 7));';
  b := 'rem := greatest(0, bi.workdays(asof + 1, me));   -- wave 098: workdays() itself leaves out declared non-working days';
  if (length(dd) - length(replace(dd, a, ''))) / length(a) <> 1 then raise exception 'api_potential fragment'; end if;
  execute replace(dd, a, b);
end $mig$;
