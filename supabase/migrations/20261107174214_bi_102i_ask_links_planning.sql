-- Applied to Supabase project via MCP on 20261107174214
-- wave 102i: Ask Crux links for potential, plan and targets open the new Planning & forecasting page
do $m$
declare fn text; d text; o text;
begin
  foreach fn in array array['bi.ask_h_potential(date, jsonb, text, text)', 'bi.ask_h_plan(date, jsonb, text)'] loop
    d := pg_get_functiondef(fn::regprocedure); o := d;
    d := replace(d, $a$'section', 'growth'$a$, $a$'section', 'planning'$a$);
    d := replace(d, 'Open Potential (Growth)', 'Open Planning & forecasting → Potential & branches');
    d := replace(d, 'Growth → Potential → Top branches to win', 'Planning & forecasting → Potential & branches');
    if d = o then raise exception '% unchanged', fn; end if;
    execute d;
  end loop;
end $m$;
