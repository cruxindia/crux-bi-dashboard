-- Applied to Supabase project via MCP on 20261121075051
create or replace function bi.fin_upload_compare(p_upload bigint) returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare u bi.fin_upload; o bi.fin_upload; cur jsonb;
begin
  select * into u from bi.fin_upload where id = p_upload; if u.id is null then return null; end if;
  select * into o from bi.fin_upload x where x.kind = u.kind and x.id <> u.id and x.status in ('committed', 'superseded')
     and (u.kind <> 'collection' or bi.fin_fy(coalesce(x.period_from, x.as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of)))
   order by (x.status = 'committed') desc, x.as_of desc, x.id desc limit 1;
  if u.kind = 'collection' then
    with s as (select up, sum((v->>'credit')::numeric) credit, sum((v->>'invoice_credit')::numeric) inv_credit, sum((v->>'rows')::int) n, max(v->>'max_date') thru
                 from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'bank'
                       union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'bank') z group by 1),
         bm as (select up, mo, sum(val::numeric) amt from (select 'u' up, m.key mo, m.value #>> '{}' val from jsonb_each(u.controls->'sheets') e(k, v), jsonb_each(v->'by_month') m where v->>'role' = 'bank'
                                                            union all select 'o', m.key, m.value #>> '{}' from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v), jsonb_each(v->'by_month') m where v->>'role' = 'bank') z group by 1, 2),
         bmm as (select mo, max(amt) filter (where up = 'u') a_u, max(amt) filter (where up = 'o') a_o from bm group by mo)
    select jsonb_build_object('kind', 'collection', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'status', u.status, 'receipts_through', (select thru from s where up = 'u'), 'receipts', (select n from s where up = 'u'),
             'credit', (select round(credit) from s where up = 'u'), 'quoting_invoice', (select round(inv_credit) from s where up = 'u'), 'quoting_share', (select round(inv_credit / nullif(credit, 0), 3) from s where up = 'u')),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'status', o.status, 'receipts_through', (select thru from s where up = 'o'), 'receipts', (select n from s where up = 'o'),
             'credit', (select round(credit) from s where up = 'o'), 'quoting_invoice', (select round(inv_credit) from s where up = 'o'), 'quoting_share', (select round(inv_credit / nullif(credit, 0), 3) from s where up = 'o')) end,
           'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'this', round(a_u), 'before', round(a_o), 'change', round(coalesce(a_u, 0) - coalesce(a_o, 0))) order by mo) from bmm)) into cur;
    return cur;
  elsif u.kind = 'sales' then
    with c as (select up, coalesce(sum((v->>'basic')::numeric), 0) basic, coalesce(sum((v->>'rows')::int), 0) n from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'sales'
                 union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'sales') z group by 1),
         bm as (select up, mo, sum((m.value->>'basic')::numeric) basic from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'sales'
                 union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'sales') z, jsonb_each(v->'by_month') m(mo, value) group by 1, 2),
         bmm as (select mo, max(basic) filter (where up = 'u') b_u, max(basic) filter (where up = 'o') b_o from bm where mo >= '2024-04' group by mo)
    select jsonb_build_object('kind', 'sales', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status, 'lines', (select n from c where up = 'u'), 'basic', (select round(basic) from c where up = 'u'),
             'months', jsonb_build_array(u.period_from, u.period_to)),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of, 'lines', (select n from c where up = 'o'), 'basic', (select round(basic) from c where up = 'o')) end,
           'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'this', round(b_u), 'before', round(b_o), 'change', round(coalesce(b_u, 0) - coalesce(b_o, 0))) order by mo) from bmm)) into cur;
    return cur;
  elsif u.kind = 'unadjusted' then
    return jsonb_build_object('kind', 'unadjusted', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status,
             'total', (select round(sum((v->>'credit')::numeric)) from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'unadj'),
             'rows', (select sum((v->>'rows')::int) from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'unadj')),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of,
             'total', (select round(sum((v->>'credit')::numeric)) from jsonb_each(o.controls->'sheets') e(k, v) where v->>'role' = 'unadj')) end,
           'outstanding_note', 'Unadjusted receipts are money already in the bank; they are never added to cash collected.');
  else
    return jsonb_build_object('kind', 'outstanding', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of) end,
           'note', 'Snapshots are never added together; the latest date is used and older dates stay for history.');
  end if;
end $f$;
select id, kind, status, notes from bi.fin_upload where id > 38 order by id;
