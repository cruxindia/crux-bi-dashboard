-- Applied to Supabase project via MCP on 20261118143511
-- wave 113d (18-Nov-2026): a client code asked for (e.g. BRT, a Bank of Maharashtra product) resolves to its client family (BOM) in the structure reference.
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '113d');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.api_client_structure(jsonb,jsonb)'::regprocedure, array[
  $r$  v_fam := nullif(coalesce(p->>'client_family', f->>'client_family'), '');$r$,
  $r$  v_fam := nullif(coalesce(p->>'client_family', f->>'client_family'), '');
  v_fam := coalesce((select c.family from bi.client c where upper(c.code) = upper(v_fam) or upper(c.label) = upper(v_fam) limit 1), v_fam);   -- wave 113d: a client code (BRT) → its family (BOM)$r$], array[1]);
insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('wave 113d', 'code_change', 'function', 'bi.api_client_structure', '{"change":"client code resolves to its family"}');
