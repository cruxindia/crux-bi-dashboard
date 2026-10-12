-- Applied to Supabase project via MCP on 20261012054126

do $$
declare d text;
begin
  d := pg_get_functiondef('bi.commit_zonal(bigint)'::regprocedure);
  if position($a$in ('leaf','zone_client_rollup','location_total') then bi.resolve_location$a$ in d) = 0 then
    raise exception 'expected resolver call not found; aborting patch';
  end if;
  d := replace(d, $a$in ('leaf','zone_client_rollup','location_total') then bi.resolve_location$a$, $a$= 'leaf' then bi.resolve_location$a$);
  execute d;
end $$;

-- Data repair: non-leaf rows carry raw labels only; remove locations auto-created from total/roll-up labels.
update bi.zt_row set location_id = null where row_type <> 'leaf' and location_id is not null;
delete from bi.location_alias where location_id in (select id from bi.location l
  where not exists (select 1 from bi.zt_row r where r.location_id=l.id)
    and not exists (select 1 from bi.zt_month_history h where h.location_id=l.id)
    and not exists (select 1 from bi.fact_case c where c.location_id=l.id)
    and l.recon_unit is null and l.zone_group is null);
delete from bi.location l
  where not exists (select 1 from bi.zt_row r where r.location_id=l.id)
    and not exists (select 1 from bi.zt_month_history h where h.location_id=l.id)
    and not exists (select 1 from bi.fact_case c where c.location_id=l.id)
    and not exists (select 1 from bi.location_alias a where a.location_id=l.id)
    and l.recon_unit is null and l.zone_group is null;
update bi.dq_exception set status='resolved', detail = detail || '{"resolution":"label was a total/roll-up row, not a location; removed (bi_010)"}'
  where rule='new_location_created' and status='open'
    and not exists (select 1 from bi.location where label = detail->>'label');
insert into bi.audit_log(actor,action,entity,detail) values ('migration','repair','location','{"migration":"bi_010","note":"removed locations auto-created from total/rollup labels"}');

