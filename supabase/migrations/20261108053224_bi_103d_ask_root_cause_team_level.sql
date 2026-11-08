-- Applied to Supabase project via MCP on 20261108053224
do $m$ declare d text; o text; begin
  d := pg_get_functiondef('bi.ask_h_rca(date, jsonb, text)'::regprocedure); o := d;
  d := replace(d, $a$declare lv text := case when nullif(f->>'location_id', '') is not null then 'client' when nullif(f->>'zone_group', '') is not null then 'location' else 'zone' end;$a$,
                  $a$declare lv text := case when nullif(f->>'location_id', '') is not null then 'client' when nullif(f->>'zone_group', '') is not null then 'location' when q ~ '\m(teams?|locations?|branches)\M' then 'location' else 'zone' end;$a$);
  if d = o then raise exception 'ask_h_rca anchor not found'; end if;
  execute d;
end $m$;
