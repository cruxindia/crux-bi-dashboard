-- Applied to Supabase project via MCP on 20261121075317
-- wave 119d: a scheduled finance rebuild now writes an audit row (fin_derive), so cached figures (keyed by the data version = latest audit row) are
-- recomputed after it — before, figures cached between an upload and the rebuild could stay until the next audited change. api_fin_sources is not cached.
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '119d');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.fin_derive_if_stale()'::regprocedure, array[
  $r$declare last timestamptz := (select max(finished_at) from bi.fin_run);$r$, $r$declare last timestamptz := (select max(finished_at) from bi.fin_run); d jsonb;$r$,
  $r$  return bi.fin_derive('scheduled');$r$,
  $r$  d := bi.fin_derive('scheduled');
  insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('scheduled', 'fin_derive', 'fin_run', d->>'run', d - 'attribution');   -- wave 119d: new data version
  return d;$r$], array[1, 1]);
select pg_temp.patch('public.bi_call(text,jsonb)'::regprocedure, array[
  $r$  if p_fn = 'coverage_status' then return bi.api_coverage_status(); end if;$r$,
  $r$  if p_fn = 'coverage_status' then return bi.api_coverage_status(); end if;
  if p_fn = 'fin_sources' then return bi.api_fin_sources(f); end if;   -- wave 119d: small, shows the last rebuild; not cached$r$], array[1]);
