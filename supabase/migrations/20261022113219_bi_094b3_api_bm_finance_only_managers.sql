-- Applied to Supabase project via MCP on 20261022113219
-- bi_094b3 (22-Oct-2026): managers who were in charge of a billed or collected month but have no business this month (e.g. before a hand-over)
-- are listed too, so manager rows + unallocated reconcile to the finance totals; 'current' marks managers with business this month.
do $do$
declare d text;
        o1 text := $o$      from mg g left join fin fi on fi.mgr = g.mgr left join exb xc on xc.m = v_bc and xc.mgr = g.mgr left join exb xp on xp.m = v_bp and xp.mgr = g.mgr
      where coalesce(g.r1, 0) > 0 or coalesce(g.tr, 0) > 0 or coalesce(g.cm_r1, 0) > 0),$o$;
        n1 text := $n$      from (select mgr from mg union select mgr from fin union select mgr from exb) am left join mg g on g.mgr = am.mgr left join fin fi on fi.mgr = am.mgr
        left join exb xc on xc.m = v_bc and xc.mgr = am.mgr left join exb xp on xp.m = v_bp and xp.mgr = am.mgr
      where coalesce(g.r1, 0) > 0 or coalesce(g.tr, 0) > 0 or coalesce(g.cm_r1, 0) > 0 or coalesce(fi.bc, fi.bp, fi.rc1, fi.rc0, fi.os, xc.rev, xp.rev) is not null),$n$;
        o2 text := $o$        'manager', g.mgr, 'locations', g.locs,$o$;
        n2 text := $n$        'manager', am.mgr, 'current', coalesce(g.r1, 0) > 0 or coalesce(g.tr, 0) > 0, 'locations', g.locs,$n$;
        a text; b text;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'api_bm fragment 1 not found exactly once'; end if;
  if (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'api_bm fragment 2 not found exactly once'; end if;
  d := replace(replace(d, o1, n1), o2, n2);
  a := substr(d, 1, position($m$'managers', (select$m$ in d) - 1);
  b := substr(d, position($m$'managers', (select$m$ in d));
  b := replace(b, 'm.manager = g.mgr', 'm.manager = am.mgr');
  b := replace(b, 'e.new_mgr = g.mgr', 'e.new_mgr = am.mgr');
  b := replace(b, 'e.prev_mgr = g.mgr', 'e.prev_mgr = am.mgr');
  execute a || b;
end $do$;
