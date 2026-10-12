-- Applied to Supabase project via MCP on 20261012095357

do $$
declare d text;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if position($a$when 'meta' then bi.api_meta()$a$ in d) = 0 then raise exception 'meta branch not found'; end if;
  d := replace(d, $a$when 'meta' then bi.api_meta()$a$, $a$when 'meta' then bi.api_meta() || jsonb_build_object('role', v_role, 'email', bi.current_email())$a$);
  execute d;
end $$;

