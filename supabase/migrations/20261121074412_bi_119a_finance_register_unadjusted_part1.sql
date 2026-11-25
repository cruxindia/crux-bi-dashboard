-- Applied to Supabase project via MCP on 20261121074412
insert into bi.fn_backup (fn, def, wave)
select p::text, pg_get_functiondef(p), '119a' from unnest(array['bi.fin_ingest_as(text,text,jsonb)'::regprocedure, 'bi.fin_derive(text)'::regprocedure,
  'bi.fin_attr_refresh(bigint,bigint[])'::regprocedure, 'bi.fin_billing_basis()'::regprocedure]) p;

alter table bi.fin_upload drop constraint if exists fin_upload_kind_check;
alter table bi.fin_upload add constraint fin_upload_kind_check check (kind in ('collection', 'outstanding', 'sales', 'unadjusted'));
alter table bi.fin_part drop constraint if exists fin_part_role_check;
alter table bi.fin_part add constraint fin_part_role_check check (role in ('ledger', 'bank', 'main', 'sales', 'unadj'));
alter table bi.fin_inv_month add column if not exists traced_basic numeric, add column if not exists reg_basic numeric, add column if not exists reg_n integer,
  add column if not exists untraced_basic numeric, add column if not exists untraced_n integer, add column if not exists reg_open_basic numeric;

create table if not exists bi.fin_unadj_txn (
  upload_id bigint not null, location_id integer not null, family text not null, bank text not null, rcpt_month date not null, status text not null,
  n integer not null default 0, amount numeric not null default 0, dup_n integer not null default 0, dup_amount numeric not null default 0, run_id bigint,
  primary key (upload_id, location_id, family, bank, rcpt_month, status));
alter table bi.fin_unadj_txn enable row level security;
revoke all on bi.fin_unadj_txn from anon, authenticated;
comment on table bi.fin_unadj_txn is 'wave 119a: unadjusted receipts (latest unadjusted snapshot) by location, family, bank family, receipt month and match status against the receipt files: in_receipts (already in cash collected), before_receipts, after_receipts, not_found.';

create or replace function bi.fin_bank_family(p text) returns text language sql immutable as $f$
  select case when p is null then null when p ~* '^\s*bom|maharashtra' then 'BOM' when p ~* 'sbi|ghatkopar|pbb|aundh|\mcit\M' then 'SBI'
              when p ~* 'canara' then 'CANB' when p ~* 'icici' then 'ICICI' when p ~* 'axis' then 'AXIS' else upper(left(trim(p), 12)) end $f$;

create or replace function bi.fin_sales_lines(p_upload bigint)
returns table(sheet text, r integer, im date, cl text, hint text, inv text, inv_key text, prefix text, basic numeric, gross numeric, tds numeric, net numeric,
              partial numeric, os numeric, rk text, idt date, gst numeric, location_id integer, loc_src text, family text)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  with x0 as materialized (
    select p.sheet, (x->>0)::int r, to_date(x->>2, 'YYYY-MM') im, x->>4 cl, x->>5 hint, x->>6 inv, bi.fin_inv_key(x->>6) k,
           (x->>7)::numeric basic, (x->>8)::numeric gross, (x->>9)::numeric tds, (x->>10)::numeric net, (x->>11)::numeric partial,
           (x->>12)::numeric os, x->>13 rk, nullif(x->>14, '')::date idt, (x->>15)::numeric gst, bi.fin_label(x->>4) lcl
      from bi.fin_part p cross join lateral jsonb_array_elements(p.rows) x
     where p.upload_id = p_upload and p.role = 'sales'
       and not exists (select 1 from bi.fin_line_exclusion z where z.upload_id = p.upload_id and z.sheet = p.sheet and z.r = (x->>0)::int)),
  e as materialized (select x0.*, substring(x0.k from '^[A-Z]{2,5}') pfx from x0),
  b as materialized (
    select e.*, coalesce(pm.location_id, 0) l0, case when pm.location_id is not null then 'prefix' else 'none' end s0,
           coalesce(cm.family, case when e.lcl is null then '(none)' when e.lcl ~ '^boi' then 'BOI' when e.lcl ~ '^bom' then 'BOM'
                                    when e.lcl ~ '^sbi' then 'SBI' when e.lcl ~ '^canara' then 'CANB' else 'OTHERS' end) fam
      from e left join bi.fin_loc_map pm on pm.key_type = 'prefix' and pm.key = e.pfx
             left join bi.fin_client_map cm on cm.key = e.lcl),
  rf as materialized (
    select q.l0, q.hint, bi.loc_refine(q.l0, array[bi.loc_of_place(bi.place_of_branch(regexp_replace(q.hint, '\s*zone\s*$', '', 'i')), null)]) l1
      from (select distinct b.l0, b.hint from b left join bi.location z on z.id = b.l0
             where b.hint is not null and b.hint !~ '^GST state' and (b.l0 = 0 or z.is_rollup)) q)
  select b.sheet, b.r, b.im, b.cl, b.hint, b.inv, b.k, b.pfx, b.basic, b.gross, b.tds, b.net, b.partial, b.os, b.rk, b.idt, b.gst,
         coalesce(rf.l1, b.l0), case when rf.l1 is not null then b.s0 || '+zone hint' else b.s0 end, b.fam
    from b left join rf on rf.l0 = b.l0 and rf.hint = b.hint $f$;

create or replace function bi.fin_unadj_lines(p_upload bigint)
returns table(sheet text, r integer, loc text, bank text, bfam text, rm date, d date, amt numeric, h text, pbc text, pbn text, ir text, location_id integer, loc_src text, family text)
language sql stable security definer set search_path to 'bi', 'public' as $f$
  with x0 as materialized (
    select p.sheet, (x->>0)::int r, x->>1 loc, x->>2 bank, bi.fin_bank_family(x->>2) bfam, to_date(x->>3, 'YYYY-MM') rm, nullif(x->>4, '')::date d,
           (x->>5)::numeric amt, x->>6 h, nullif(x->>7, '') pbc, nullif(x->>8, '') pbn, bi.fin_inv_key(x->>9) ir, bi.fin_label(x->>1) lloc
      from bi.fin_part p cross join lateral jsonb_array_elements(p.rows) x
     where p.upload_id = p_upload and p.role = 'unadj'
       and not exists (select 1 from bi.fin_line_exclusion z where z.upload_id = p.upload_id and z.sheet = p.sheet and z.r = (x->>0)::int)),
  py as materialized (select distinct x0.bfam, x0.pbc, x0.pbn from x0 where x0.pbc is not null or x0.pbn is not null),
  pz as materialized (select py.bfam, py.pbc, py.pbn, z.location_id, z.family, z.basis
                        from py cross join lateral bi.loc_of_payer(case when py.bfam in ('BOM', 'SBI', 'CANB') then py.bfam end, py.pbc, py.pbn) z)
  select x0.sheet, x0.r, x0.loc, x0.bank, x0.bfam, x0.rm, x0.d, x0.amt, x0.h, x0.pbc, x0.pbn, x0.ir,
         coalesce(case when x0.lloc is not null and x0.lloc !~ '^unadj' and lm.confidence is distinct from 'unallocated' then lm.location_id end, pz.location_id, 0),
         case when x0.lloc is not null and x0.lloc !~ '^unadj' and lm.location_id is not null and lm.confidence is distinct from 'unallocated' then 'label'
              when pz.location_id is not null then coalesce(pz.basis, 'paying branch') else 'none' end,
         coalesce(pz.family, case when x0.bfam in ('BOM', 'SBI') then x0.bfam when x0.bfam = 'CANB' then 'CANB' else '(none)' end)
    from x0 left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = x0.lloc
            left join pz on pz.bfam is not distinct from x0.bfam and pz.pbc is not distinct from x0.pbc and pz.pbn is not distinct from x0.pbn $f$;

revoke all on function bi.fin_bank_family(text), bi.fin_sales_lines(bigint), bi.fin_unadj_lines(bigint) from public, anon, authenticated;

create or replace function bi.fin_ingest_as(p_actor text, p_action text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '120s' as $function$
declare u bi.fin_upload; u2 bi.fin_upload; v_h text; v_id bigint; v_cols text[]; v_exp text[]; n int; bad jsonb; d jsonb; v_role text;
begin
  if p_action = 'begin' then
    if p->>'kind' not in ('collection', 'outstanding', 'sales', 'unadjusted') then raise exception 'kind must be collection, outstanding, sales or unadjusted'; end if;
    if coalesce(p->>'file_hash', '') !~ '^[0-9a-f]{64}$' then raise exception 'file_hash (sha-256 hex) required'; end if;
    if nullif(p->>'as_of', '') is null then raise exception 'as_of date required'; end if;
    if (p->>'as_of')::date > current_date + 1 then raise exception 'as_of % is in the future', p->>'as_of'; end if;
    select * into u from bi.fin_upload where kind = p->>'kind' and file_hash = p->>'file_hash';
    if found and u.status in ('committed', 'superseded') then
      return jsonb_build_object('duplicate', true, 'upload_id', u.id, 'status', u.status, 'committed_at', u.committed_at);
    end if;
    if nullif(p->>'content_sha256', '') is not null then
      select * into u2 from bi.fin_upload x where x.kind = p->>'kind' and x.status in ('committed', 'superseded') and x.controls->>'content_sha256' = p->>'content_sha256'
       order by x.id desc limit 1;
      if found then
        return jsonb_build_object('duplicate', true, 'duplicate_content', true, 'upload_id', u2.id, 'status', u2.status, 'committed_at', u2.committed_at,
          'message', 'This workbook has exactly the same rows as ' || u2.file_name || ' (upload ' || u2.id || '); nothing was imported.');
      end if;
    end if;
    if u.id is not null then
      update bi.fin_upload set status = 'staging', file_name = p->>'file_name', source_ref = p->>'source_ref', as_of = (p->>'as_of')::date,
             as_of_basis = p->>'as_of_basis', period_from = nullif(p->>'period_from', '')::date, period_to = nullif(p->>'period_to', '')::date,
             name_period = nullif(p->>'name_period', '')::date, controls = coalesce(p->'controls', '{}'::jsonb) || case when nullif(p->>'content_sha256', '') is not null then jsonb_build_object('content_sha256', p->>'content_sha256') else '{}'::jsonb end, uploaded_by = p_actor, notes = null
       where id = u.id;
      return jsonb_build_object('upload_id', u.id, 'resumed', true, 'parts', (select count(*) from bi.fin_part where upload_id = u.id));
    end if;
    insert into bi.fin_upload (kind, file_name, file_hash, source_ref, as_of, as_of_basis, period_from, period_to, name_period, controls, uploaded_by)
    values (p->>'kind', p->>'file_name', p->>'file_hash', p->>'source_ref', (p->>'as_of')::date, p->>'as_of_basis', nullif(p->>'period_from', '')::date,
            nullif(p->>'period_to', '')::date, nullif(p->>'name_period', '')::date, coalesce(p->'controls', '{}'::jsonb) || case when nullif(p->>'content_sha256', '') is not null then jsonb_build_object('content_sha256', p->>'content_sha256') else '{}'::jsonb end, p_actor)
    returning id into v_id;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_begin', 'fin_upload', v_id::text, jsonb_build_object('kind', p->>'kind', 'file', p->>'file_name'));
    return jsonb_build_object('upload_id', v_id);

  elsif p_action = 'stage' then
    select * into u from bi.fin_upload where id = (p->>'upload_id')::bigint;
    if not found or u.status <> 'staging' then raise exception 'upload % is not open for staging', p->>'upload_id'; end if;
    select array_agg(x order by o) into v_cols from jsonb_array_elements_text(p->'cols') with ordinality t(x, o);
    v_role := p->>'role';
    v_exp := case
      when u.kind = 'outstanding' and v_role = 'ledger' then array['r','loc','im','ims','cl','br','inv','basic','gross','tds','net','partial','os','rk']
      when u.kind = 'sales' and v_role = 'sales' then array['r','loc','im','ims','cl','br','inv','basic','gross','tds','net','partial','os','rk','idt','gst']
      when u.kind = 'unadjusted' and v_role = 'unadj' then array['r','loc','bank','rm','d','amt','h','pbc','pbn','ir']
      when u.kind = 'collection' and v_role in ('bank', 'main') then
        case when v_cols = array['r','loc','bank','rm','d','amt','cl','br','inv','basic','im','ims','h','pbc','pbn','ir'] then v_cols
             else array['r','loc','bank','rm','d','amt','cl','br','inv','basic','im','ims','h'] end end;
    if v_exp is null or v_cols is distinct from v_exp then raise exception 'unexpected columns or role % for a % upload', v_role, u.kind; end if;
    if jsonb_typeof(p->'rows') <> 'array' then raise exception 'rows must be an array'; end if;
    insert into bi.fin_part (upload_id, sheet, seq, role, cols, rows) values (u.id, p->>'sheet', (p->>'seq')::int, v_role, v_cols, p->'rows')
    on conflict (upload_id, sheet, seq) do update set rows = excluded.rows, role = excluded.role, cols = excluded.cols;
    return jsonb_build_object('ok', true, 'rows', jsonb_array_length(p->'rows'));

  elsif p_action = 'commit' then
    select * into u from bi.fin_upload where id = (p->>'upload_id')::bigint for update;
    if not found or u.status <> 'staging' then raise exception 'upload % is not open', p->>'upload_id'; end if;
    select jsonb_object_agg(e.key, jsonb_build_object('expected', e.value::int, 'stored', coalesce(s.n, 0))) into bad
    from jsonb_each_text(coalesce(p->'expected', '{}'::jsonb)) e
    left join (select sheet, sum(jsonb_array_length(rows))::int n from bi.fin_part where upload_id = u.id group by 1) s on s.sheet = e.key
    where coalesce(s.n, 0) <> e.value::int;
    if bad is not null then raise exception 'row counts differ from the file: %', bad; end if;
    if (select count(*) from bi.fin_part where upload_id = u.id) = 0 then raise exception 'nothing staged'; end if;
    v_h := (select encode(extensions.digest(string_agg(fp.sheet || '|' || fp.seq || '|' || encode(extensions.digest(fp.rows::text, 'sha256'), 'hex'), ';' order by fp.sheet collate "C", fp.seq), 'sha256'), 'hex')
            from bi.fin_part fp where fp.upload_id = u.id);
    select * into u2 from bi.fin_upload x where x.kind = u.kind and x.status in ('committed', 'superseded') and x.id <> u.id and x.controls->>'content_sha256' = v_h order by x.id desc limit 1;
    if found then
      update bi.fin_upload set status = 'rejected', notes = 'identical rows to upload ' || u2.id || ' (' || u2.file_name || ')', controls = controls || jsonb_build_object('content_sha256', v_h) where id = u.id;
      insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_duplicate_content', 'fin_upload', u.id::text, jsonb_build_object('same_as', u2.id));
      return jsonb_build_object('ok', false, 'duplicate_content', true, 'upload_id', u.id, 'same_as', u2.id, 'status', 'rejected');
    end if;
    update bi.fin_upload set controls = controls || jsonb_build_object('content_sha256', v_h) where id = u.id;
    update bi.fin_upload set status = 'committed', committed_at = now() where id = u.id;
    if u.kind in ('outstanding', 'sales', 'unadjusted') then
      update bi.fin_upload set status = 'superseded', notes = coalesce(notes || ' ', '') || 'replaced by upload ' || u.id || ' (same date)'
       where kind = u.kind and status = 'committed' and as_of = u.as_of and id <> u.id;
    else
      update bi.fin_upload set status = 'superseded', notes = coalesce(notes || ' ', '') || 'replaced by upload ' || u.id
       where kind = 'collection' and status = 'committed' and id <> u.id and bi.fin_fy(coalesce(period_from, as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of))
         and (as_of < u.as_of or (as_of = u.as_of and id < u.id))
         and coalesce(u.period_from, u.as_of) <= coalesce(period_from, as_of);
      update bi.fin_upload set status = 'superseded', notes = coalesce(notes || ' ', '') || 'a file with later receipts is already current'
       where id = u.id and exists (select 1 from bi.fin_upload o where o.kind = 'collection' and o.status = 'committed' and o.id <> u.id
                                     and bi.fin_fy(coalesce(o.period_from, o.as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of)) and o.as_of > u.as_of
                                     and coalesce(o.period_from, o.as_of) <= coalesce(u.period_from, u.as_of));
    end if;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_commit', 'fin_upload', u.id::text,
      jsonb_build_object('kind', u.kind, 'file', u.file_name, 'as_of', u.as_of, 'status', (select status from bi.fin_upload where id = u.id)));
    return jsonb_build_object('ok', true, 'upload_id', u.id, 'status', (select status from bi.fin_upload where id = u.id),
      'notes', (select notes from bi.fin_upload where id = u.id), 'derive_pending', true, 'compare', bi.fin_upload_compare(u.id));

  elsif p_action = 'derive' then
    d := bi.fin_derive(p_actor);
    update bi.fin_upload set summary = d where id = (select max(id) from bi.fin_upload where status in ('committed', 'superseded') and committed_at is not null);
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_derive', 'fin_run', d->>'run', d);
    return d;

  elsif p_action = 'compare' then
    return bi.fin_upload_compare((p->>'upload_id')::bigint);

  elsif p_action = 'admin' then
    return bi.fin_admin(p_actor, p);

  elsif p_action = 'reject' then
    update bi.fin_upload set status = 'rejected', notes = left(p->>'reason', 300) where id = (p->>'upload_id')::bigint and status = 'staging';
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'unknown action %', p_action;
end $function$;

create or replace function bi.fin_upload_compare(p_upload bigint) returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare u bi.fin_upload; o bi.fin_upload; cur jsonb; prev jsonb;
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
                                                            union all select 'o', m.key, m.value #>> '{}' from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v), jsonb_each(v->'by_month') m where v->>'role' = 'bank') z group by 1, 2)
    select jsonb_build_object('kind', 'collection', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'status', u.status, 'receipts_through', (select thru from s where up = 'u'), 'receipts', (select n from s where up = 'u'),
             'credit', (select round(credit) from s where up = 'u'), 'quoting_invoice', (select round(inv_credit) from s where up = 'u'), 'quoting_share', (select round(inv_credit / nullif(credit, 0), 3) from s where up = 'u')),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'status', o.status, 'receipts_through', (select thru from s where up = 'o'), 'receipts', (select n from s where up = 'o'),
             'credit', (select round(credit) from s where up = 'o'), 'quoting_invoice', (select round(inv_credit) from s where up = 'o'), 'quoting_share', (select round(inv_credit / nullif(credit, 0), 3) from s where up = 'o')) end,
           'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'this', round(max(amt) filter (where up = 'u')), 'before', round(max(amt) filter (where up = 'o')),
                                         'change', round(coalesce(max(amt) filter (where up = 'u'), 0) - coalesce(max(amt) filter (where up = 'o'), 0))) order by mo) from bm group by mo)) into cur;
    return cur;
  elsif u.kind = 'sales' then
    with c as (select up, coalesce(sum((v->>'basic')::numeric), 0) basic, coalesce(sum((v->>'rows')::int), 0) n from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'sales'
                 union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'sales') z group by 1),
         bm as (select up, mo, sum((m.value->>'basic')::numeric) basic, sum((m.value->>'n')::int) n from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'sales'
                 union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'sales') z, jsonb_each(v->'by_month') m(mo, value) group by 1, 2)
    select jsonb_build_object('kind', 'sales', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status, 'lines', (select n from c where up = 'u'), 'basic', (select round(basic) from c where up = 'u'),
             'months', jsonb_build_array(u.period_from, u.period_to)),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of, 'lines', (select n from c where up = 'o'), 'basic', (select round(basic) from c where up = 'o')) end,
           'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'this', round(max(basic) filter (where up = 'u')), 'before', round(max(basic) filter (where up = 'o')),
                                         'change', round(coalesce(max(basic) filter (where up = 'u'), 0) - coalesce(max(basic) filter (where up = 'o'), 0))) order by mo) from bm where mo >= '2024-04' group by mo)) into cur;
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
revoke all on function bi.fin_upload_compare(bigint) from public, anon, authenticated;
