-- Applied to Supabase project via MCP on 20261021121358
-- bi_089l (21-Oct-2026): ask_tat_stats — qualify the grp parameter (it clashed with tat_month_stat.grp once stored months existed)
create or replace function bi.ask_tat_stats(p_months date[], f jsonb, grp text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare om date := (select max(received_month) from bi.case_store); stored date[]; live date[]; r jsonb := '[]'; g text := ask_tat_stats.grp;
begin
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb and g in ('unit', 'client', 'location') then
    select array_agg(x.m) into stored from unnest(p_months) x(m)
     where x.m < om and exists (select 1 from bi.tat_month_stat t where t.month = x.m and t.grp = 'total');
  end if;
  select array_agg(x.m) into live from unnest(p_months) x(m) where stored is null or not (x.m = any (stored));
  if stored is not null then
    select coalesce(jsonb_agg(t.stat), '[]') into r from bi.tat_month_stat t where t.month = any (stored) and t.grp in (g, 'total');
  end if;
  if live is not null then r := r || bi.ask_tat_stats_live(live, f, g); end if;
  return r;
end $function$;
