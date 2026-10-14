-- Applied to Supabase project via MCP on 20261014112419
do $do$
declare d text := pg_get_functiondef('bi.api_matrix(date,date)'::regprocedure);
begin
  if position('''location_id'', location_id' in d) = 0 then
    d := replace(d, 'rows as (select r.sheet_row, r.location_label, r.client_label, r.rate,', 'rows as (select r.sheet_row, r.location_label, r.client_label, r.location_id, r.client_code, r.rate,');
    d := replace(d, '''location'', location_label, ''client'', client_label,', '''location'', location_label, ''client'', client_label, ''location_id'', location_id, ''client_code'', client_code,');
    if position('''location_id'', location_id' in d) = 0 then raise exception 'api_matrix patch failed'; end if;
    execute d;
  end if;
end $do$;
