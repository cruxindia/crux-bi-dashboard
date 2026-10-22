-- Applied to Supabase project via MCP on 20261022092626
-- bi_093c (22-Oct-2026): tracker view rows carry the organic bases (MoM, QoQ, YoY) for the per-cell explanation
do $do$
declare d text; o text[]; n text[]; i int; f regprocedure := 'bi.api_tracker_sheet(date,jsonb,date,integer)'::regprocedure;
begin
  d := pg_get_functiondef(f);
  o := array[
$o0$os.organic org, os.v1 ov1, os.v2 ov2, os.v3 ov3$o0$,
$o1$sum(l.ov3) filter (where l.ok) ov3$o1$,
$o2$'ov', case when a.org is not null then jsonb_build_array(a.ov1, a.ov2, a.ov3) end$o2$];
  n := array[
$n0$os.organic org, os.v1 ov1, os.v2 ov2, os.v3 ov3, os.b_mom obm, os.b_qoq obq, os.b_yoy oby, os.q_trend oqt, os.y_shape oys$n0$,
$n1$sum(l.ov3) filter (where l.ok) ov3, sum(l.obm) filter (where l.ok) obm, sum(l.obq) filter (where l.ok) obq, sum(l.oby) filter (where l.ok) oby,
      count(l.oby) filter (where l.ok) noy, sum(l.org) filter (where l.ok and l.oby is not null) orgy, max(l.oqt) filter (where l.ok) oqt, max(l.oys) filter (where l.ok) oys$n1$,
$n2$'ov', case when a.org is not null then jsonb_build_array(a.ov1, a.ov2, a.ov3) end,
      'ob', case when a.org is not null then jsonb_build_array(round(a.obm, 1), round(a.obq, 1), round(a.oby, 1), a.noy, round(a.orgy, 1), a.oqt, a.oys) end$n2$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_tracker_sheet fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
