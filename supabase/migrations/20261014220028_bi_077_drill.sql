-- Applied to Supabase project via MCP on 20261014220028
create or replace function bi.api_drill(m date, f jsonb, lvl text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare sel jsonb; par jsonb; pf jsonb; kids jsonb; lf jsonb; hist jsonb; br jsonb; f1tot int; fam text := f->>'client_family';
        ccode text := nullif(p->>'client_code', '');
begin
  f := coalesce(f, '{}'::jsonb);
  if lvl not in ('zone', 'location', 'client', 'branch', 'none') then raise exception 'level must be zone, location, client, branch or none'; end if;
  sel := bi.api_potential(m, f, 'cases', 'total')->'rows'->0;
  pf := case when f ? 'client_family' then f - 'client_family' when f ? 'location_id' then f - 'location_id'
             when f ? 'zone_group' then f - 'zone_group' when f ? 'region' then f - 'region' when f ? 'stakeholder' then f - 'stakeholder' end;
  if pf is not null then par := bi.api_potential(m, pf, 'cases', 'total')->'rows'->0; end if;
  if lvl in ('zone', 'location', 'client') then
    lf := bi.api_lfl(m, f, lvl)->'rows';
    select coalesce(jsonb_agg(r || jsonb_build_object(
             'id', case lvl when 'zone' then (select z.code from bi.zone_group z where z.label = r->>'group' limit 1)
                            when 'location' then (select l.id::text from bi.location l where l.label = r->>'group' limit 1)
                            else (select c.family from bi.client c where c.label = r->>'group' or c.code = r->>'group' limit 1) end,
             'client_code', case when lvl = 'client' then (select c.code from bi.client c where c.label = r->>'group' or c.code = r->>'group' limit 1) end,
             'previous', (select (x->>'previous')::numeric from jsonb_array_elements(lf) x where x->>'group' = r->>'group' limit 1),
             'change', (select (x->>'change')::numeric from jsonb_array_elements(lf) x where x->>'group' = r->>'group' limit 1))
           order by (r->>'mtd')::numeric desc nulls last), '[]'::jsonb)
      into kids from jsonb_array_elements(bi.api_potential(m, f, 'cases', lvl)->'rows') r;
  end if;
  hist := bi.api_monthly((m - interval '11 months')::date, m, f, 'total');
  if lvl = 'branch' then
    with cs as (
      select c.branch_code, c.client_code, c.location_id, c.received_month
      from bi.case_store c
      where c.received_month between (m - interval '2 months')::date and m
        and nullif(c.branch_code, '') is not null
        and bi.loc_ok(c.location_id, c.recon_unit, f - 'client_family')
        and (ccode is null or c.client_code = ccode)
        and (fam is null or c.client_code in (select code from bi.client where family = fam))),
    agg as (select client_code, bi.norm_code(branch_code) code_norm, min(branch_code) branch_code,
                   count(*) filter (where received_month = m) cases_month, count(*) last3, max(received_month) last_month
            from cs group by 1, 2)
    select coalesce(jsonb_agg(jsonb_build_object('client_code', a.client_code, 'client_family', cl.family, 'branch_code', a.branch_code,
             'branch', coalesce(mm.branch_name, a.branch_code), 'ifsc', mm.ifsc, 'district', mm.district, 'in_master', mm.branch_name is not null,
             'cases_month', a.cases_month, 'cases_last3', a.last3) order by a.cases_month desc, a.last3 desc), '[]'::jsonb)
      into br
      from (select * from agg order by cases_month desc, last3 desc limit 200) a
      left join bi.client cl on cl.code = a.client_code
      left join lateral (select b.branch_name, b.ifsc, b.district from bi.client_branch_master b
                         where b.client_family = cl.family and b.code_norm = a.code_norm and b.status = 'active' limit 1) mm on true;
    select count(*) into f1tot from bi.case_store c
     where c.received_month = m and bi.loc_ok(c.location_id, c.recon_unit, f - 'client_family')
       and (ccode is null or c.client_code = ccode) and (fam is null or c.client_code in (select code from bi.client where family = fam));
  end if;
  return jsonb_build_object('month', m, 'filters', f, 'level', lvl, 'selected', sel, 'parent', par, 'parent_filters', pf,
    'children', kids, 'history', hist, 'branches', br, 'force1_cases_month', f1tot,
    'method', 'Selected and child values use the same month-to-date figures as the Overview and Business tracker (latest snapshot of the month); likely month end = Overview projection; previous = same point last month. Branch rows are Force1 cases (operational system), which are counted differently from tracker figures and do not add up to them.');
end $function$;

create or replace function bi.api_branch_detail(f jsonb)
returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
with k as (select coalesce(f->>'client_family', (select family from bi.client where code = f->>'client_code')) fam, bi.norm_code(f->>'branch_code') cn),
codes as (select code from bi.client, k where family = k.fam),
cs as (select c.* from bi.case_store c, k where c.client_code in (select code from codes) and bi.norm_code(c.branch_code) = k.cn),
mon as (select received_month m, count(*) n from cs group by 1),
mst as (select b.* from bi.client_branch_master b, k where b.client_family = k.fam and b.code_norm = k.cn order by (b.status = 'active') desc, b.verified_on desc limit 1),
act as (select a.* from bi.branch_activity a, k where a.fam = k.fam and a.code_norm = k.cn),
loc as (select coalesce((select location_id from mst), (select location_id from cs group by 1 order by count(*) desc limit 1)) id),
peer as (select percentile_cont(0.5) within group (order by a.n3 / 3.0) med, count(*) n
         from bi.branch_activity a join bi.client_branch_master b on b.client_family = a.fam and b.code_norm = a.code_norm and b.status = 'active', k
         where a.fam = k.fam and a.n3 > 0 and b.location_id = (select id from loc))
select jsonb_build_object(
  'client_family', (select fam from k), 'branch_code', f->>'branch_code',
  'master', (select jsonb_build_object('name', branch_name, 'ifsc', ifsc, 'address', address, 'district', district, 'state', state, 'pincode', pincode,
               'status', status, 'verification', verification_status, 'source', source, 'source_version', source_version, 'verified_on', verified_on,
               'first_seen', first_seen, 'type', branch_type) from mst),
  'location', (select label from bi.location where id = (select id from loc)),
  'months', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'cases', n) order by m), '[]'::jsonb) from mon),
  'activity', (select jsonb_build_object('first_month', first_m, 'last_month', last_m, 'cases_total', n, 'cases_last3', n3) from act),
  'peer_median_per_month', (select round(med::numeric, 1) from peer where n >= 5), 'peers', (select n from peer),
  'note', 'Force1 cases matched by client family and branch code (leading zeros ignored). Peer median = median monthly cases (last 3 months) of active branches of the same client in the same Crux location, shown when at least 5 exist.')
$function$;

do $$
declare d text := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
        anchor text := $a$      when 'potential' then$a$;
        addition text := $s$      when 'drill' then bi.api_drill(m, f, coalesce(p_args->>'level', 'zone'), coalesce(p_args->'p', '{}'::jsonb))
      when 'branch_detail' then bi.api_branch_detail(coalesce(p_args->'p', '{}'::jsonb))
$s$;
begin
  if position('when ''drill''' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then raise exception 'anchor not unique'; end if;
  execute replace(d, anchor, addition || anchor);
end $$;
