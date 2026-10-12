-- Applied to Supabase project via MCP on 20261012103849

create table if not exists bi.api_cache (k text primary key, v jsonb not null, version bigint not null, computed_at timestamptz not null default now());
alter table bi.api_cache enable row level security;

create or replace function public.bi_call(p_fn text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare m date := nullif(p_args->>'month','')::date; f jsonb := coalesce(p_args->'filters','{}');
        v_admin boolean := bi.admin_ok(p_args->>'admin_key');
        v_ver bigint := (select coalesce(max(id),0) from bi.audit_log);
        v_key text := md5(p_fn || '|' || coalesce((p_args - 'admin_key')::text,''));
        r jsonb;
begin
  if p_fn in ('exceptions','mapping_queue') then
    if not v_admin then return jsonb_build_object('error','admin key required'); end if;
    return case p_fn when 'exceptions' then bi.api_exceptions() else bi.api_mapping_queue() end;
  end if;
  select v into r from bi.api_cache where k = v_key and version = v_ver;
  if r is null then
    r := case p_fn
      when 'meta' then bi.api_meta()
      when 'overview' then bi.api_overview(m,f) when 'forecast' then bi.api_forecast(m,f)
      when 'zonal' then bi.api_zonal((p_args->>'snapshot')::date,f) when 'daily' then bi.api_daily(m,f)
      when 'monthly' then bi.api_monthly((p_args->>'from')::date,(p_args->>'to')::date,f,coalesce(p_args->>'group','total'))
      when 'force' then bi.api_force(m,f) when 'force_trend' then bi.api_force_trend(f)
      when 'case_tat' then bi.api_case_tat(m,f,coalesce(p_args->>'group','location'))
      when 'point_tat' then bi.api_point_tat(m,f,coalesce(p_args->>'group','category'))
      when 'manual_tat' then bi.api_manual_tat(m,f) when 'employees' then bi.api_employees(m,f) when 'insights' then bi.api_insights(m,f)
      when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)
      else null end;
    if r is not null then
      insert into bi.api_cache(k, v, version) values (v_key, r, v_ver)
      on conflict (k) do update set v = excluded.v, version = excluded.version, computed_at = now();
    end if;
  end if;
  if p_fn = 'meta' then r := r || jsonb_build_object('role', case when v_admin then 'admin' else 'viewer' end); end if;
  return r;
end $$;
grant execute on function public.bi_call(text, jsonb) to anon, authenticated;

alter role anon set statement_timeout = '20s';
alter role authenticated set statement_timeout = '20s';
notify pgrst, 'reload config';

