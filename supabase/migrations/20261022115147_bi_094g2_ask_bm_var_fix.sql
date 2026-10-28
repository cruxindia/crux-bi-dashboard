-- Applied to Supabase project via MCP on 20261022115147
-- bi_094g2 (22-Oct-2026): PL/pgSQL names are case-insensitive — the variable T clashed with the alias t; renamed to tt
do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.ask_h_bm(date,jsonb,text,text)'::regprocedure);
  if position('declare B jsonb; T jsonb;' in d) = 0 then raise exception 'ask_h_bm declaration not found'; end if;
  d := replace(d, 'declare B jsonb; T jsonb;', 'declare B jsonb; tt jsonb;');
  d := regexp_replace(d, '([^A-Za-z_])T(->|\s*:=)', '\1tt\2', 'g');
  if d ~ '[^A-Za-z_]T(->|\s*:=)' then raise exception 'a reference to T is left'; end if;
  execute d;
end $do$;
