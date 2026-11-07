-- Applied to Supabase project via MCP on 20261107115039
-- Wave 101 (owner, 7-Nov-2026 17:16 IST: "Organic and potential are same. Potential means organic"). Wording only: the
-- all-branch figure is the ORGANIC BUSINESS; the trend expectation of the existing business (formerly labelled "organic") is
-- now BUSINESS AS USUAL (BAU). Calculations, keys and field names are unchanged. Multi-word phrases only, so SQL identifiers
-- are never touched; Ask Crux routing patterns are left as they are (only answer labels change).
do $m$
declare f text; d text; o text; n int := 0;
  gen text[][] := array[
    ['Organic expectation','Business-as-usual expectation'],['organic expectation','business-as-usual expectation'],
    ['Growth beyond organic','Growth beyond business as usual'],['growth beyond organic','growth beyond business as usual'],
    ['effort above organic','effort above business as usual'],['effort vs organic','effort vs business as usual'],
    ['Organic to date = ','BAU to date = '],['Organic = ','Business as usual (BAU) = '],['Organic invoiced revenue','Business-as-usual invoiced revenue'],
    ['Organic totals','BAU totals'],['Organic is an estimate','Business as usual is an estimate'],['Organic vs actual','Business as usual vs actual'],
    ['no organic revenue estimate','no business-as-usual revenue estimate'],['no organic estimate','no business-as-usual estimate'],['an organic estimate','a business-as-usual estimate'],
    ['Actual growth − organic growth','Actual growth − business-as-usual growth'],['actual growth − organic growth','actual growth − business-as-usual growth'],
    ['effort = actual − organic.','effort = actual − business as usual.'],['organic to date = organic ×','BAU to date = BAU ×'],['organic for the month','business as usual for the month'],
    ['next to Organic)','next to Business as usual)'],['Revenue view: organic cases','Revenue view: BAU cases'],['the organic cases are valued','the BAU cases are valued'],
    ['Organic vs new-client','Business-as-usual vs new-client'],
    ['Potential = current business + headroom.','Organic business = current business + headroom.'],
    ['Organic is different: it is the trend expectation of the current business; potential is the market headroom across every branch.','Business as usual is different: it is the trend expectation of the current business (the yardstick for effort); the organic business (this figure) is what every client branch could bring.']];
  ask text[][] := array[['Organic expectation %s','Business-as-usual expectation %s'],['Organic is an estimate','Business as usual is an estimate'],
    ['Actual growth − organic growth = growth beyond organic.','Actual growth − business-as-usual growth = growth beyond business as usual.']];
  i int;
begin
  foreach f in array array['bi.api_bm(date,jsonb,jsonb)','bi.api_growth(date,jsonb,jsonb)','bi.api_growth_rev(date,jsonb,jsonb)','bi.api_market_potential(date,jsonb)',
                           'bi.api_organic(date,jsonb,text,text)','bi.api_potential(date,jsonb,text,text)','bi.api_tracker_sheet(date,jsonb,date,integer)',
                           'public.bi_ask(text,jsonb,uuid)'] loop
    d := pg_get_functiondef(f::regprocedure); o := d;
    for i in 1 .. array_length(gen, 1) loop d := replace(d, gen[i][1], gen[i][2]); end loop;
    if d <> o then execute d; n := n + 1; end if;
  end loop;
  d := pg_get_functiondef('bi.ask_h_revenue(date,jsonb,text)'::regprocedure); o := d;
  for i in 1 .. array_length(ask, 1) loop d := replace(d, ask[i][1], ask[i][2]); end loop;
  if d <> o then execute d; n := n + 1; end if;
  if n < 6 then raise exception 'only % functions changed', n; end if;
  raise notice '% functions reworded', n;
end $m$;
