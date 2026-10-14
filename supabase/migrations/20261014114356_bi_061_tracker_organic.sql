-- Applied to Supabase project via MCP on 20261014114356
do $do$
declare d text := pg_get_functiondef('bi.api_tracker_sheet(date,jsonb,date,integer)'::regprocedure); n0 text;
begin
  if position('organic_store' in d) = 0 then
    n0 := d;
    d := replace(d, 'bi.fam_ok(z.client_code, f)) ok', 'bi.fam_ok(z.client_code, f)) ok, os.organic org, os.v1 ov1, os.v2 ov2, os.v3 ov3');
    d := replace(d, 'from r z left join bi.location l on l.id = z.location_id',
                    'from r z left join bi.location l on l.id = z.location_id left join bi.organic_store os on os.month = rm and os.location_id = z.location_id and os.client_code = z.client_code');
    d := replace(d, 'sum(l.ct) filter (where l.ok) ct',
                    'sum(l.ct) filter (where l.ok) ct, sum(l.org) filter (where l.ok) org, sum(l.ov1) filter (where l.ok) ov1, sum(l.ov2) filter (where l.ok) ov2, sum(l.ov3) filter (where l.ok) ov3');
    d := replace(d, '''k'', a.k, ''mem'', a.members, ''h'', h.h',
                    '''k'', a.k, ''mem'', a.members, ''h'', h.h, ''org'', round(a.org), ''ov'', case when a.org is not null then jsonb_build_array(a.ov1, a.ov2, a.ov3) end');
    d := replace(d, '''filters'', f,',
      '''filters'', f,' || chr(10) ||
      '    ''organic'', (select jsonb_build_object(''share'', case when rm < date_trunc(''month'', (select max(snapshot_date) from bi.zt_snapshot))::date and s = (select max(snapshot_date) from bi.zt_snapshot where report_month = rm) then 1' ||
      ' else coalesce(bi.organic_share(rm, bi.workdays(rm, s)), round(bi.workdays(rm, s)::numeric / bi.workdays(rm, (rm + interval ''1 month - 1 day'')::date), 4)) end,' ||
      ' ''k'', bi.workdays(rm, s), ''kk'', bi.workdays(rm, (rm + interval ''1 month - 1 day'')::date), ''si'', max(si_t), ''si1'', max(si1), ''si2'', max(si2), ''si3'', max(si3),' ||
      ' ''wd'', max(wd), ''wd1'', max(wd1), ''wd2'', max(wd2), ''wd3'', max(wd3), ''m1'', to_char(rm - interval ''1 month'', ''Mon-YY''), ''m2'', to_char(rm - interval ''2 months'', ''Mon-YY''), ''m3'', to_char(rm - interval ''3 months'', ''Mon-YY''))' ||
      ' from bi.organic_store where month = rm),');
    d := regexp_replace(d, '''notes'', jsonb_build_array\(.*?\)\)\s*into res;',
      '''notes'', jsonb_build_array(' ||
      '''Every total — location, zone, region, Pan India, client-wise and stakeholder-wise — is the sum of its client rows, so the sheet always adds up.'', ' ||
      '''Daily = cases added since the previous report this month (the first report of the month shows the full month-to-date).'', ' ||
      '''Monthly history columns show each past month''''s final cases, revenue and billing.'', ' ||
      '''Client-wise block: SBI Car Loan+ is counted under SBI (product: Car Loan).'', ' ||
      '''Organic = business-as-usual expectation for the month; organic to date = organic × the share of a month normally done by this working day. Click ? on any organic figure to see its calculation.''))' || chr(10) || '  into res;', 's');
    if position('organic_store' in d) = 0 or position('''org'', round(a.org)' in d) = 0 or position('''organic'', (select' in d) = 0 or position('so the sheet always adds up' in d) = 0 then
      raise exception 'api_tracker_sheet patch incomplete';
    end if;
    execute d;
  end if;
end $do$;
