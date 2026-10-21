-- Applied to Supabase project via MCP on 20261021075128
-- bi_089i: data-health answer reads back-entered cases straight from the case store (17 s -> a few seconds)
do $do$
declare d text := pg_get_functiondef('bi.ask_h_health(date,jsonb)'::regprocedure); a text; b text;
begin
  a := $a$  select string_agg(format('%s %s', x->>'key', bi.fmt_p((x->>'case_back_entered')::numeric / nullif((x->>'case_n')::numeric, 0))), '; ') into back
    from jsonb_array_elements(bi.ask_tat_stats(array[m]::date[], f, 'unit')) x
   where x->>'key' <> '~total' and (x->>'case_n')::int >= 30 and (x->>'case_back_entered')::numeric / nullif((x->>'case_n')::numeric, 0) > 0.5;$a$;
  b := $b$  select string_agg(format('%s %s', z.recon_unit, bi.fmt_p(z.be::numeric / z.n)), '; ') into back from (
    select s.recon_unit, count(*) n, count(*) filter (where extract(epoch from s.completed_at - s.received_at) < 60 * coalesce((select back_entry_minutes from bi.tat_rule where measure = 'case'), 15)) be
      from bi.case_store s left join bi.client cl on cl.code = s.client_code
     where s.received_month = m and upper(s.status) = 'COMPLETED' and s.completed_at >= s.received_at
       and bi.loc_ok(s.location_id, s.recon_unit, f) and (f->>'client_family' is null or cl.family = f->>'client_family')
     group by 1) z where z.n >= 30 and z.be::numeric / z.n > 0.5;$b$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'anchor'; end if;
  execute replace(d, a, b);
end $do$;
