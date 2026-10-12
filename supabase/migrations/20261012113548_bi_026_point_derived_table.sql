-- Applied to Supabase project via MCP on 20261012113548

create table if not exists bi.point_derived (
  point_id bigint primary key, created_month date, recon_unit text, location_id int, client_code text,
  category text, processing_route text, verified_by text, verifier_class text, field_tat_hours real);
alter table bi.point_derived enable row level security;
create index if not exists point_derived_month on bi.point_derived(created_month, recon_unit);
create table if not exists bi.refresh_state (name text primary key, refreshed_at timestamptz, source_version bigint, rows int, ms int);
alter table bi.refresh_state enable row level security;

create or replace function bi.refresh_point_derived() returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare t0 timestamptz := clock_timestamp(); n int; v bigint := (select coalesce(max(id),0) from bi.audit_log);
begin
  truncate bi.point_derived;
  insert into bi.point_derived
  select point_id, created_month, recon_unit, location_id, client_code, category, processing_route, verified_by, verifier_class, field_tat_hours
  from bi.v_point;
  get diagnostics n = row_count;
  insert into bi.refresh_state values ('point_derived', now(), v, n, round(extract(epoch from clock_timestamp()-t0)*1000))
  on conflict (name) do update set refreshed_at=excluded.refreshed_at, source_version=excluded.source_version, rows=excluded.rows, ms=excluded.ms;
  return jsonb_build_object('rows', n, 'ms', round(extract(epoch from clock_timestamp()-t0)*1000));
end $$;
revoke all on function bi.refresh_point_derived() from public, anon, authenticated;

