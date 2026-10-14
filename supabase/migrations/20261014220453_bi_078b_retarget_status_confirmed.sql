-- Applied to Supabase project via MCP on 20261014220453
do $$
declare d text := pg_get_functiondef('bi.mapping_retarget(text,jsonb)'::regprocedure);
begin
  execute replace(d, $x$review_status = 'accepted'$x$, $x$review_status = 'confirmed'$x$);
end $$;
