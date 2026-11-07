-- Applied to Supabase project via MCP on 20261107183134
-- wave 102n: a row whose last month fell below half of its 3-month average is flagged in the note ("check before sending")
do $m$
declare d text := pg_get_functiondef('bi.api_target_sheet(date, jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, $a$             case when v_sig then 'strong seasonal signal for ' || to_char(v_m, 'Mon') end,$a$,
                  $a$             case when r2.cap0 > 0 and r2.l3_rev > 0 and r2.lm_rev < 0.5 * r2.l3_rev then 'last month fell to ' || round(100 * r2.lm_rev / r2.l3_rev) || '% of the 3-month average: check before sending' end,
             case when v_sig then 'strong seasonal signal for ' || to_char(v_m, 'Mon') end,$a$);
  d := replace(d, $a$'dormant_rows', count(*) filter (where cap0 <= 0),$a$, $a$'dormant_rows', count(*) filter (where cap0 <= 0), 'falling_rows', count(*) filter (where cap0 > 0 and l3_rev > 0 and lm_rev < 0.5 * l3_rev),$a$);
  if position('check before sending' in d) = 0 or position('falling_rows' in d) = 0 then raise exception 'anchor not found'; end if;
  execute d;
end $m$;
