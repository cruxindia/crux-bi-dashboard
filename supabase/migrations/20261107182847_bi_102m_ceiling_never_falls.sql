-- Applied to Supabase project via MCP on 20261107182847
-- wave 102m: the monthly ceiling of a team x client never falls with a seasonal dip (it grows with gmax and with seasonal rises only),
-- so the never-below-previous rule holds month to month except in a strong-signal month
do $m$
declare d text := pg_get_functiondef('bi.plan_compute(jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, 'r.u * (1 + v_gmax) * fs[r.i + 1] / fs[r.i]', 'r.u * (1 + v_gmax) * greatest(fs[r.i + 1] / fs[r.i], 1)');
  if d = o then raise exception 'anchor not found'; end if;
  execute d;
end $m$;
