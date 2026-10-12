-- Applied to Supabase project via MCP on 20261012104942
do $$ declare d text; old text; new text; begin
 d := pg_get_functiondef('bi.run_acceptance_tests()'::regprocedure);
 old := $o$  begin
    perform set_config('request.jwt.claims','{}',true);
    perform public.bi_call('meta','{}'); ok := false;
  exception when insufficient_privilege then null; end;$o$;
 new := $n$  perform set_config('request.jwt.claims','{}',true);
  -- access model (12-Oct-2026): public read allowed; admin/exceptions/ingest/stash need a valid admin key
  if coalesce(public.bi_call('meta','{}')->>'role','') <> 'viewer' then ok := false; end if;
  if (public.bi_call('exceptions','{"admin_key":"wrong"}')->>'error') is null then ok := false; end if;
  if bi.admin_ok(null) or bi.admin_ok('wrong') then ok := false; end if;
  begin perform public.bi_admin('verify','{"admin_key":"wrong"}'); ok := false; exception when insufficient_privilege then null; end;
  begin perform public.bi_repo_stash('wrong','{}'); ok := false; exception when insufficient_privilege then null; end;$n$;
 if position(old in d) = 0 then raise exception 'T16 block not found'; end if;
 d := replace(d, old, new);
 d := replace(d, $a$test:='T16 unauthorised access rejected'$a$, $a$test:='T16 public read only; privileged actions need admin key'$a$);
 execute d;
end $$;
