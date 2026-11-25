-- NOTE (25-Nov-2026): bi.fin_upload_compare, bi.fin_derive, bi.fin_attr_refresh, bi.fin_billing_basis and bi.api_fin_sources were changed again by 119b–119e;
-- the live definitions are in 20261121_bi_119b-e_live_definitions.sql (run after this file).
-- wave 119a (21-Nov-2026, owner 12:54 IST): uploads for the sales register (Sale.xlsx) and the unadjusted receipts (Unadj till Oct26.xlsx); the
-- consolidated Collection Sheet uses the existing collection kind. See SOW wave 119, D406–D411.
--  * fin_upload kinds sales / unadjusted; fin_part roles sales / unadj; staging checks the column layout per role.
--  * A corrected file for the same date replaces the earlier one (sales and unadjusted, as for outstanding); newer dates sit beside older ones.
--  * Billed revenue (fin_inv_month.basic) = invoices known from the outstanding ledger, the receipts and the latest sales register, each invoice once,
--    its basic taken from the register when present. traced_basic keeps the old meaning (ledger ∪ receipts) and realisation stays settled ÷ traced.
--    untraced = register invoices with no ledger line and no receipt — never counted as settled.
--  * Unadjusted receipts: transaction level, matched to the receipt files (bank family, amount, date ± 3 days) — never added to cash collected.
-- Additive: new columns, a new table and functions; fin_ingest_as / fin_derive / fin_attr_refresh / fin_billing_basis replaced (old bodies in fn_backup).

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

-- bank family of a receipt / unadjusted line (bank column or sheet name)
create or replace function bi.fin_bank_family(p text) returns text language sql immutable as $f$
  select case when p is null then null when p ~* '^\s*bom|maharashtra' then 'BOM' when p ~* 'sbi|ghatkopar|pbb|aundh|\mcit\M' then 'SBI'
              when p ~* 'canara' then 'CANB' when p ~* 'icici' then 'ICICI' when p ~* 'axis' then 'AXIS' else upper(left(trim(p), 12)) end $f$;

-- sales register lines with location: invoice series → place in the client-zone hint inside the series' zone (same invoice elsewhere: in fin_derive)
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

-- unadjusted lines with location: label → paying bank branch → not identified ("Unadj" labels)
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

-- ---------- upload: kinds, roles, layouts, supersede rules ----------
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
    -- same rows under a different file (re-saved or re-downloaded copy): nothing to import
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
    if u.kind in ('outstanding', 'sales', 'unadjusted') then   -- dated snapshots: a corrected file for the same date replaces it; other dates stay
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

-- what a newly committed file changes against the file of the same kind in use before it (receipts by month, invoices, outstanding, unadjusted)
create or replace function bi.fin_upload_compare(p_upload bigint) returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare u bi.fin_upload; o bi.fin_upload; cur jsonb; prev jsonb;
begin
  select * into u from bi.fin_upload where id = p_upload; if u.id is null then return null; end if;
  -- the file this one is compared with: the current file of the kind other than this one (for collection: same financial year)
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
  else   -- outstanding
    return jsonb_build_object('kind', 'outstanding', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of) end,
           'note', 'Snapshots are never added together; the latest date is used and older dates stay for history.');
  end if;
end $f$;
revoke all on function bi.fin_upload_compare(bigint) from public, anon, authenticated;

-- ---------- derive: ledger + receipts + sales register + unadjusted receipts ----------
create or replace function bi.fin_derive(p_actor text default 'system'::text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '170s' as $function$
declare v_run bigint; v_os bigint; v_asof date; v_co bigint[]; v_sr bigint; v_ua bigint; v_rfrom date; v_rthru date; v_grace int; t0 timestamptz := clock_timestamp(); c jsonb; s jsonb;
begin
  perform bi.fin_apply_duplicate_rule('derive: ' || coalesce(p_actor, 'unknown'));
  v_grace := coalesce((select (value #>> '{}')::int from bi.fin_config where key = 'recon_grace_days'), 7);
  insert into bi.fin_run (actor) values (p_actor) returning id into v_run;
  select id, as_of into v_os, v_asof from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select array_agg(id order by id) into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;        -- wave 119a
  select id into v_ua from bi.fin_upload where kind = 'unadjusted' and status = 'committed' order by as_of desc, id desc limit 1;   -- wave 119a
  select min(coalesce(period_from, as_of)), max(as_of) into v_rfrom, v_rthru from bi.fin_upload where kind = 'collection' and status = 'committed';
  v_co := coalesce(v_co, '{}'::bigint[]); v_asof := coalesce(v_asof, current_date);

  with l as materialized (select * from bi.fin_os_lines(v_os)),
  dk as materialized (select inv_key, basic, net, os, count(*) c, jsonb_agg(jsonb_build_object('sheet', sheet, 'row', r)) rows_, max(location_id) loc
                      from l where inv_key is not null group by 1, 2, 3, 4),
  osk as materialized (select inv_key, sum(partial) partial, max(location_id) filter (where location_id > 0) loc from l where inv_key is not null group by 1),
  rc0 as materialized (select u.id upload_id, x.*, row_number() over (partition by u.id, x.sheet, x.d, x.amt, coalesce(x.inv_key, ''), coalesce(x.h, '') order by x.r) dup_k
                       from unnest(v_co) u(id) cross join lateral bi.fin_receipts(u.id) x where x.role = 'bank'),
  rc as materialized (select distinct on (q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k) q.*
                      from rc0 q order by q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k, q.upload_id desc),
  m as materialized (
    select rc.upload_id, rc.sheet, rc.r, rc.loc, rc.rm, rc.d, rc.amt, rc.inv, rc.inv_key, rc.basic, rc.im, rc.h, rc.family,
           coalesce(bi.fin_bank_family(rc.bank), bi.fin_bank_family(rc.sheet)) bfam,
           coalesce(case when rc.inv_key is not null then o.loc end, nullif(rc.map_loc, 0), 0) location_id,
           case when rc.inv_key is not null and o.loc is not null then 'ledger' else rc.map_state end loc_src,
           case when rc.inv_key is null then 'none' when o.inv_key is null then 'closed' when o.partial > 0.5 then 'partial'
                when rc.d is not null and rc.d <= v_asof - v_grace then 'open' else 'recent' end mstat,
           case when rc.d is not null and rc.im is not null then greatest(rc.d - (rc.im + interval '1 month' - interval '1 day')::date, 0) end lag
    from rc left join osk o on o.inv_key = rc.inv_key),
  -- sales register (wave 119a): exact repeated lines once; a line without a series location takes the same invoice's location in the ledger / receipts
  s0 as materialized (select * from bi.fin_sales_lines(v_sr) where v_sr is not null),
  sdup as materialized (select inv_key, basic, net, os, lower(coalesce(cl, '')) lcl, count(*) c, min(r) r1, min(location_id) loc from s0 where inv_key is not null group by 1, 2, 3, 4, 5),
  rkl as materialized (select inv_key, max(location_id) filter (where location_id > 0) loc from m where inv_key is not null group by 1),
  sl as materialized (
    select s0.inv_key, min(s0.im) im, min(s0.family) fam, max(s0.basic) basic, max(s0.net) net, max(s0.os) os, max(s0.partial) partial, bool_or(s0.rk ~* '^\s*paid') paid,
           max(s0.location_id) loc, min(s0.loc_src) src
      from s0 where s0.inv_key is not null group by s0.inv_key, s0.basic, s0.net, s0.os, lower(coalesce(s0.cl, ''))),
  sl2 as materialized (select sl.*, coalesce(z.is_rollup, false) rollup from sl left join bi.location z on z.id = sl.loc),
  sk as materialized (
    select sl2.inv_key, min(sl2.im) im, min(sl2.fam) fam, sum(coalesce(sl2.basic, 0)) basic, count(*) lines,
           sum(case when sl2.paid then 0 when sl2.net > 0 then coalesce(sl2.basic, 0) * least(greatest(coalesce(sl2.os, sl2.net - coalesce(sl2.partial, 0)) / sl2.net, 0), 1) else coalesce(sl2.basic, 0) end) reg_open,
           coalesce(max(sl2.loc) filter (where sl2.loc > 0 and not sl2.rollup), max(o2.loc), max(r2.loc), max(sl2.loc) filter (where sl2.loc > 0), 0) loc,
           case when max(sl2.loc) filter (where sl2.loc > 0 and not sl2.rollup) is not null then min(sl2.src)
                when max(o2.loc) is not null then 'same invoice in the ledger' when max(r2.loc) is not null then 'same invoice in receipts'
                when max(sl2.loc) filter (where sl2.loc > 0) is not null then min(sl2.src) else 'none' end src
      from sl2 left join osk o2 on o2.inv_key = sl2.inv_key left join rkl r2 on r2.inv_key = sl2.inv_key group by sl2.inv_key),
  i_os as (
    insert into bi.fin_os_agg as t (upload_id, location_id, family, inv_month, n, basic, net, partial, os, os_basic, neg_n, neg_os, dup_n, dup_os, run_id, gross, tds)
    select v_os, l.location_id, l.family, coalesce(l.im, date '1900-01-01'), count(*), coalesce(sum(l.basic), 0), coalesce(sum(l.net), 0), sum(l.partial), sum(l.os),
           sum(case when l.net > 0 then coalesce(l.basic, 0) * least(greatest(l.os / l.net, 0), 1) when l.os > 0 then coalesce(l.basic, 0) else 0 end),
           count(*) filter (where l.os < 0), coalesce(sum(l.os) filter (where l.os < 0), 0),
           count(*) filter (where dk.c > 1), coalesce(sum(l.os * (dk.c - 1)::numeric / dk.c) filter (where dk.c > 1), 0), v_run,
           coalesce(sum(l.gross), 0), coalesce(sum(l.tds), 0)
    from l left join dk on dk.inv_key = l.inv_key and dk.basic is not distinct from l.basic and dk.net is not distinct from l.net and dk.os = l.os
    where v_os is not null
    group by 2, 3, 4
    on conflict (upload_id, location_id, family, inv_month) do update set n = excluded.n, basic = excluded.basic, net = excluded.net, partial = excluded.partial,
      os = excluded.os, os_basic = excluded.os_basic, neg_n = excluded.neg_n, neg_os = excluded.neg_os, dup_n = excluded.dup_n, dup_os = excluded.dup_os, run_id = v_run,
      gross = excluded.gross, tds = excluded.tds
    returning 1),
  i_un as (
    insert into bi.fin_unadj as t (upload_id, label, location_id, amount, run_id)
    select v_os, sh.key || ' · ' || coalesce(u->>'label', ''),
           coalesce(case when coalesce(u->>'label', '') ~* 'unadj' or jsonb_array_length(sh.value->'unadj') = 1 then sm.location_id end, lm.location_id, 0),
           coalesce((u->>'amount')::numeric, 0), v_run
    from bi.fin_upload fu cross join lateral jsonb_each(coalesce(fu.controls->'sheets', '{}'::jsonb)) sh
    cross join lateral jsonb_array_elements(coalesce(sh.value->'unadj', '[]'::jsonb)) u
    left join bi.fin_loc_map sm on sm.key_type = 'sheet' and sm.key = bi.fin_label(sh.key)
    left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = bi.fin_label(u->>'label')
    where fu.id = v_os
    on conflict (upload_id, label) do update set location_id = excluded.location_id, amount = excluded.amount, run_id = v_run
    returning 1),
  i_rc as (
    insert into bi.fin_rcpt_agg as t (upload_id, location_id, family, bank, rcpt_month, n, amount, inv_n, inv_amount, basic,
                                      closed_n, closed_amount, partial_n, partial_amount, open_n, open_amount, lag_x_amount, lag_amount, run_id)
    select m.upload_id, m.location_id, m.family, m.sheet, coalesce(m.rm, date '1900-01-01'),
           count(*), sum(m.amt), count(*) filter (where m.inv_key is not null), coalesce(sum(m.amt) filter (where m.inv_key is not null), 0),
           coalesce(sum(m.basic) filter (where m.inv_key is not null), 0),
           count(*) filter (where m.mstat = 'closed'), coalesce(sum(m.amt) filter (where m.mstat = 'closed'), 0),
           count(*) filter (where m.mstat = 'partial'), coalesce(sum(m.amt) filter (where m.mstat = 'partial'), 0),
           count(*) filter (where m.mstat = 'open'), coalesce(sum(m.amt) filter (where m.mstat = 'open'), 0),
           coalesce(sum(m.lag * m.amt) filter (where m.lag is not null and m.amt > 0), 0), coalesce(sum(m.amt) filter (where m.lag is not null and m.amt > 0), 0), v_run
    from m group by 1, 2, 3, 4, 5
    on conflict (upload_id, location_id, family, bank, rcpt_month) do update set n = excluded.n, amount = excluded.amount, inv_n = excluded.inv_n,
      inv_amount = excluded.inv_amount, basic = excluded.basic, closed_n = excluded.closed_n, closed_amount = excluded.closed_amount, partial_n = excluded.partial_n,
      partial_amount = excluded.partial_amount, open_n = excluded.open_n, open_amount = excluded.open_amount, lag_x_amount = excluded.lag_x_amount,
      lag_amount = excluded.lag_amount, run_id = v_run
    returning 1),
  ou as (select inv_key, basic, net, os, min(im) im, max(location_id) loc, min(family) fam, max(gross) gross, max(tds) tds from l where inv_key is not null group by 1, 2, 3, 4),
  ok as (select inv_key, min(im) im, coalesce(max(loc) filter (where loc > 0), 0) loc, min(fam) fam, sum(coalesce(basic, 0)) basic,
                sum(case when net > 0 then coalesce(basic, 0) * least(greatest(os / net, 0), 1) when os > 0 then coalesce(basic, 0) else 0 end) open_basic,
                sum(coalesce(gross, 0)) gross_l, sum(coalesce(tds, 0)) tds_l, sum(coalesce(net, 0)) net_l
         from ou group by 1),
  rk as (select inv_key, min(im) im, coalesce(max(location_id) filter (where location_id > 0), 0) loc, min(family) fam, max(coalesce(basic, 0)) basic, sum(amt) collected
         from m where inv_key is not null group by 1),
  -- every invoice once: ledger ∪ receipts ∪ register; basic from the register when present (billed), traced = ledger ∪ receipts (realisation base)
  k as (select coalesce(nullif(ok.loc, 0), nullif(sk.loc, 0), rk.loc, 0) loc, coalesce(ok.fam, sk.fam, rk.fam, '(none)') fam, coalesce(ok.im, sk.im, rk.im) im,
               coalesce(sk.basic, ok.basic, rk.basic, 0) basic,
               case when ok.inv_key is not null or rk.inv_key is not null then coalesce(ok.basic, rk.basic, 0) else 0 end traced_basic,
               coalesce(ok.open_basic, 0) open_basic, coalesce(rk.collected, 0) collected, ok.inv_key is not null in_ledger, rk.inv_key is not null in_receipts,
               sk.inv_key is not null in_register, coalesce(sk.basic, 0) reg_basic, coalesce(sk.reg_open, 0) reg_open,
               coalesce(ok.gross_l, 0) gross_l, coalesce(ok.tds_l, 0) tds_l, coalesce(ok.net_l, 0) net_l
        from ok full join rk on rk.inv_key = ok.inv_key full join sk on sk.inv_key = coalesce(ok.inv_key, rk.inv_key)),
  i_inv as (
    insert into bi.fin_inv_month as t (location_id, family, inv_month, inv_n, basic, open_basic, settled_basic, collected, in_ledger_n, receipt_only_n, run_id, gross_l, tds_l, net_l,
                                       traced_basic, reg_basic, reg_n, untraced_basic, untraced_n, reg_open_basic)
    select loc, fam, coalesce(im, date '1900-01-01'), count(*), sum(basic), sum(open_basic), sum(traced_basic - open_basic), sum(collected),
           count(*) filter (where in_ledger), count(*) filter (where not in_ledger and in_receipts), v_run, sum(gross_l), sum(tds_l), sum(net_l),
           sum(traced_basic), sum(reg_basic), count(*) filter (where in_register), coalesce(sum(basic) filter (where in_register and not in_ledger and not in_receipts), 0),
           count(*) filter (where in_register and not in_ledger and not in_receipts), sum(reg_open)
    from k group by 1, 2, 3
    on conflict (location_id, family, inv_month) do update set inv_n = excluded.inv_n, basic = excluded.basic, open_basic = excluded.open_basic,
      settled_basic = excluded.settled_basic, collected = excluded.collected, in_ledger_n = excluded.in_ledger_n, receipt_only_n = excluded.receipt_only_n, run_id = v_run,
      gross_l = excluded.gross_l, tds_l = excluded.tds_l, net_l = excluded.net_l, traced_basic = excluded.traced_basic, reg_basic = excluded.reg_basic, reg_n = excluded.reg_n,
      untraced_basic = excluded.untraced_basic, untraced_n = excluded.untraced_n, reg_open_basic = excluded.reg_open_basic
    returning 1),
  -- unadjusted receipts (wave 119a): matched to the receipt files by bank family, amount and date ± 3 days; repeated credits counted
  u0 as materialized (select * from bi.fin_unadj_lines(v_ua) where v_ua is not null),
  rcm as materialized (select coalesce(bfam, '') bf, amt, d from m where d is not null and amt > 0),
  uhit as materialized (select u0.sheet, u0.r from u0 join rcm on rcm.bf = coalesce(u0.bfam, '') and rcm.amt = u0.amt and rcm.d between u0.d - 3 and u0.d + 3 group by 1, 2),
  udup as materialized (select coalesce(bfam, '') bf, d, amt, coalesce(h, '') hh, count(*) c from u0 where amt > 0 group by 1, 2, 3, 4 having count(*) > 1),
  um as materialized (
    select u0.*, case when uh.r is not null then 'in_receipts'
                      when u0.d is not null and v_rfrom is not null and u0.d < v_rfrom then 'before_receipts'
                      when u0.d is not null and v_rthru is not null and u0.d > v_rthru then 'after_receipts' else 'not_found' end status,
           ud.c dupc
      from u0 left join uhit uh on uh.sheet = u0.sheet and uh.r = u0.r
              left join udup ud on ud.bf = coalesce(u0.bfam, '') and ud.d = u0.d and ud.amt = u0.amt and ud.hh = coalesce(u0.h, '')),
  i_ut as (
    insert into bi.fin_unadj_txn as t (upload_id, location_id, family, bank, rcpt_month, status, n, amount, dup_n, dup_amount, run_id)
    select v_ua, location_id, family, coalesce(bfam, '(none)'), coalesce(rm, date_trunc('month', d)::date, date '1900-01-01'), status, count(*), sum(amt),
           count(*) filter (where dupc > 1), coalesce(sum(amt * (dupc - 1)::numeric / dupc) filter (where dupc > 1), 0), v_run
      from um group by 2, 3, 4, 5, 6
    on conflict (upload_id, location_id, family, bank, rcpt_month, status) do update set n = excluded.n, amount = excluded.amount, dup_n = excluded.dup_n, dup_amount = excluded.dup_amount, run_id = v_run
    returning 1),
  rv as (
    select 'map_location' kind, x.k key, null::bigint upload_id, 0 location_id, 'warn' severity, sum(x.amt) amount, count(*)::int n,
           'Location not identified: ' || x.k title, jsonb_build_object('source', min(x.src), 'examples', (array_agg(x.inv order by x.amt desc nulls last))[1:5]) detail
    from (select 'label "' || coalesce(bi.fin_label(l.loc), '(blank)') || '" / series ' || coalesce(l.prefix, '(none)') || ' / sheet "' || l.sheet || '"' k,
                 l.os amt, 'outstanding' src, l.inv from l where l.location_id = 0
          union all
          select 'label "' || coalesce(bi.fin_label(m.loc), '(blank)') || '" / series ' || coalesce(substring(m.inv_key from '^[A-Z]{2,5}'), '(none)'),
                 m.amt, 'receipts', m.inv from m where m.location_id = 0 and m.loc_src <> 'unallocated'
          union all
          select 'sales register / series ' || coalesce(substring(sk.inv_key from '^[A-Z]{2,5}'), '(none)'), sk.basic, 'sales register', sk.inv_key from sk where sk.loc = 0
          union all
          select 'unadjusted receipts / label "' || coalesce(u0.loc, '(blank)') || '"', u0.amt, 'unadjusted', null from u0 where u0.location_id = 0) x
    group by x.k
    union all
    select 'receipt_still_open', m.inv_key, min(m.upload_id), max(m.location_id), 'warn', sum(m.amt), count(*)::int,
           'Receipt recorded but invoice ' || m.inv_key || ' is still fully open in the ' || to_char(v_asof, 'DD-Mon-YYYY') || ' ledger',
           jsonb_build_object('receipts', jsonb_agg(jsonb_build_object('sheet', m.sheet, 'row', m.r, 'date', m.d, 'amount', m.amt) order by m.d), 'invoice', min(m.inv))
    from m where m.mstat = 'open' group by m.inv_key
    union all
    select 'duplicate_line', v_os || ':' || dk.inv_key || ':' || dk.os, v_os, dk.loc, 'warn', dk.os * (dk.c - 1), dk.c::int,
           'Invoice ' || dk.inv_key || ' appears ' || dk.c || ' times with identical amounts', jsonb_build_object('sheet_rows', dk.rows_, 'open_each', dk.os)
    from dk where dk.c > 1
    union all
    select 'register_repeated_line', v_sr || ':' || sdup.inv_key || ':' || coalesce(sdup.basic::text, '') || ':' || coalesce(sdup.os::text, '') || ':' || left(md5(sdup.lcl), 6), v_sr, sdup.loc, 'info', sdup.basic * (sdup.c - 1), sdup.c::int,
           'Sales register: invoice ' || sdup.inv_key || ' appears ' || sdup.c || ' times with identical amounts (billed once)', jsonb_build_object('first_row', sdup.r1)
    from sdup where sdup.c > 1
    union all
    select 'negative_balance', v_os || ':' || l.sheet || ':' || l.r, v_os, l.location_id, 'info', l.os, 1,
           'Negative open balance on ' || coalesce(l.inv_key, '(no invoice no.)'), jsonb_build_object('sheet', l.sheet, 'row', l.r, 'remark', l.rk)
    from l where l.os < 0
    union all
    select 'receipt_duplicate', x.upload_id || ':' || x.sheet || ':' || x.d || ':' || x.amt || ':' || x.h || ':' || coalesce(x.inv_key, ''), x.upload_id, max(x.location_id), 'warn',
           x.amt * (count(*) - 1), count(*)::int, 'Possible double entry on ' || x.sheet || ': ' || count(*) || ' identical credits of ' || x.amt || ' on ' || to_char(x.d, 'DD-Mon-YYYY'),
           jsonb_build_object('rows', jsonb_agg(x.r), 'invoice', min(x.inv))
    from m x where x.amt > 0 and x.d is not null group by x.upload_id, x.sheet, x.d, x.amt, x.h, x.inv_key having count(*) > 1
    union all
    select 'unadj_repeated', v_ua || ':' || um.location_id, v_ua, um.location_id, 'warn', sum(um.amt * (um.dupc - 1)::numeric / um.dupc), count(*)::int,
           'Unadjusted receipts: ' || count(*) || ' lines repeat another credit (same bank, date, amount and narration)', jsonb_build_object('rows', (array_agg(um.r order by um.r))[1:20])
    from um where um.dupc > 1 group by um.location_id
    union all
    select 'unadj_not_found', v_ua || ':' || um.location_id, v_ua, um.location_id, 'info', sum(um.amt), count(*)::int,
           'Unadjusted receipts not found in the receipt files (same bank, amount, date ± 3 days): ' || count(*) || ' lines',
           jsonb_build_object('months', (select jsonb_object_agg(mo, a) from (select to_char(coalesce(z.rm, z.d), 'YYYY-MM') mo, round(sum(z.amt)) a from um z where z.status = 'not_found' and z.location_id = um.location_id group by 1) q))
    from um where um.status = 'not_found' group by um.location_id
    union all
    select case when x.inv_key !~ '^[A-Z]{2,5}-[0-9]{4}-' then 'odd_invoice_ref' else 'multi_invoice_ref' end, x.upload_id || ':' || x.sheet || ':' || x.r, x.upload_id, x.location_id, 'info', x.amt, 1,
           case when x.inv_key !~ '^[A-Z]{2,5}-[0-9]{4}-' then 'Unreadable invoice reference "' || x.inv || '"' else 'One receipt quotes several invoices: "' || x.inv || '"' end,
           jsonb_build_object('sheet', x.sheet, 'row', x.r, 'date', x.d)
    from m x where x.inv is not null and (x.inv_key !~ '^[A-Z]{2,5}-[0-9]{4}-' or upper(x.inv) ~ '[,&]|\mAND\M|\s/\s')
    union all
    select 'control', fu.id || ':' || coalesce(i->>'rule', '') || ':' || coalesce(i->>'sheet', ''), fu.id, null, coalesce(i->>'severity', 'info'), null, null,
           fu.file_name || ': ' || coalesce(i->>'rule', 'check'), i
    from bi.fin_upload fu cross join lateral jsonb_array_elements(coalesce(fu.controls->'issues', '[]'::jsonb)) i
    where fu.id = v_os or fu.id = any (v_co) or fu.id = v_sr or fu.id = v_ua),
  i_rv as (
    insert into bi.fin_review as t (kind, key, upload_id, location_id, severity, amount, n, title, detail, run_id)
    select kind, key, upload_id, location_id, severity, amount, n, title, detail, v_run from rv
    on conflict (kind, key) do update set upload_id = excluded.upload_id, location_id = excluded.location_id, severity = excluded.severity, amount = excluded.amount,
      n = excluded.n, title = excluded.title, detail = excluded.detail, last_seen = now(), run_id = v_run,
      status = case when t.status = 'cleared' then 'open' else t.status end
    returning 1)
  select jsonb_build_object('os_groups', (select count(*) from i_os), 'unadj_rows', (select count(*) from i_un), 'receipt_groups', (select count(*) from i_rc),
                            'invoice_groups', (select count(*) from i_inv), 'review_items', (select count(*) from i_rv),
                            'ledger_lines', (select count(*) from l), 'receipts', (select count(*) from rc),
                            'receipts_repeated_across_uploads', (select count(*) from rc0) - (select count(*) from rc),
                            'register_lines', (select count(*) from s0), 'register_invoices', (select count(*) from sk), 'register_basic', (select round(sum(basic)) from sk),
                            'unadjusted_lines', (select count(*) from u0), 'unadjusted_groups', (select count(*) from i_ut)) into c;

  update bi.fin_os_agg set n = 0, basic = 0, net = 0, partial = 0, os = 0, os_basic = 0, neg_n = 0, neg_os = 0, dup_n = 0, dup_os = 0, run_id = v_run, gross = 0, tds = 0
   where run_id is distinct from v_run and (n <> 0 or os <> 0);
  update bi.fin_unadj set amount = 0, run_id = v_run where run_id is distinct from v_run and amount <> 0;
  update bi.fin_unadj_txn set n = 0, amount = 0, dup_n = 0, dup_amount = 0, run_id = v_run where run_id is distinct from v_run and (n <> 0 or amount <> 0);
  update bi.fin_rcpt_agg set n = 0, amount = 0, inv_n = 0, inv_amount = 0, basic = 0, closed_n = 0, closed_amount = 0, partial_n = 0, partial_amount = 0,
         open_n = 0, open_amount = 0, lag_x_amount = 0, lag_amount = 0, run_id = v_run
   where run_id is distinct from v_run and (n <> 0 or amount <> 0);
  update bi.fin_inv_month set inv_n = 0, basic = 0, open_basic = 0, settled_basic = 0, collected = 0, in_ledger_n = 0, receipt_only_n = 0, run_id = v_run, gross_l = 0, tds_l = 0, net_l = 0,
         traced_basic = 0, reg_basic = 0, reg_n = 0, untraced_basic = 0, untraced_n = 0, reg_open_basic = 0
   where run_id is distinct from v_run and inv_n <> 0;
  update bi.fin_review set status = 'cleared', run_id = v_run where run_id is distinct from v_run and status = 'open';

  c := coalesce(c, '{}'::jsonb) || jsonb_build_object('attribution', bi.fin_attr_refresh(v_os, v_co));
  s := jsonb_build_object('run', v_run, 'outstanding_upload', v_os, 'as_of', v_asof, 'collection_uploads', to_jsonb(v_co), 'sales_upload', v_sr, 'unadjusted_upload', v_ua,
         'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int) || c;
  update bi.fin_run set finished_at = clock_timestamp(), summary = s where id = v_run;
  return s;
end $function$;

-- ---------- whole-line attribution: billed lines now include the sales register (same invoice universe as fin_inv_month) ----------
create or replace function bi.fin_attr_refresh(p_os bigint default null::bigint, p_co bigint[] default null::bigint[]) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '170s' as $function$
declare v_os bigint := p_os; v_co bigint[] := p_co; v_sr bigint; v_run bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint; v_n int; t0 timestamptz := clock_timestamp();
begin
  if v_os is null then select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1; end if;
  if v_co is null then select coalesce(array_agg(id order by id), '{}') into v_co from bi.fin_upload where kind = 'collection' and status = 'committed'; end if;
  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;
  with l as materialized (select * from bi.fin_os_lines(v_os)),
  rc0 as materialized (select u.id upload_id, x.*, row_number() over (partition by u.id, x.sheet, x.d, x.amt, coalesce(x.inv_key, ''), coalesce(x.h, '') order by x.r) dup_k
                       from unnest(v_co) u(id) cross join lateral bi.fin_receipts(u.id) x where x.role = 'bank'),
  rc as materialized (select distinct on (q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k) q.*
                      from rc0 q order by q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k, q.upload_id desc),
  osk as materialized (select inv_key, max(location_id) filter (where location_id > 0) loc from l where inv_key is not null group by 1),
  ou as (select inv_key, basic, net, os, min(im) im, max(location_id) loc, min(family) fam, min(cl) cl, min(loc_src) src from l where inv_key is not null group by 1, 2, 3, 4),
  ok as (select inv_key, min(im) im, coalesce(max(loc) filter (where loc > 0), 0) loc, min(fam) fam, min(cl) cl, min(src) src, sum(coalesce(basic, 0)) basic from ou group by 1),
  rk as (select rc.inv_key, min(rc.im) im, coalesce(max(coalesce(o.loc, nullif(rc.map_loc, 0))), 0) loc, min(rc.family) fam, min(rc.cl) cl, max(coalesce(rc.basic, 0)) basic,
                min(case when o.loc is not null then 'ledger' else rc.map_state end) src
           from rc left join osk o on o.inv_key = rc.inv_key where rc.inv_key is not null group by 1),
  -- sales register (wave 119a): repeated identical lines once; location as in fin_derive
  s0 as materialized (select * from bi.fin_sales_lines(v_sr) where v_sr is not null),
  sl as (select s0.inv_key, min(s0.im) im, min(s0.family) fam, min(s0.cl) cl, max(s0.basic) basic, max(s0.location_id) loc, min(s0.loc_src) src
           from s0 where s0.inv_key is not null group by s0.inv_key, s0.basic, s0.net, s0.os, lower(coalesce(s0.cl, ''))),
  sl2 as (select sl.*, coalesce(z.is_rollup, false) rollup from sl left join bi.location z on z.id = sl.loc),
  sk as (select sl2.inv_key, min(sl2.im) im, min(sl2.fam) fam, min(sl2.cl) cl, sum(coalesce(sl2.basic, 0)) basic,
                coalesce(max(sl2.loc) filter (where sl2.loc > 0 and not sl2.rollup), max(sl2.loc) filter (where sl2.loc > 0), 0) loc,
                min(sl2.src) || ' (sales register)' src
           from sl2 group by sl2.inv_key),
  k as materialized (select coalesce(ok.inv_key, rk.inv_key, sk.inv_key) inv_key,
                            coalesce(nullif(ok.loc, 0), case when sk.loc > 0 and not exists (select 1 from bi.location z where z.id = sk.loc and z.is_rollup) then sk.loc end, nullif(rk.loc, 0), nullif(sk.loc, 0), 0) loc,
                            coalesce(ok.fam, sk.fam, rk.fam, '(none)') fam, coalesce(ok.cl, sk.cl, rk.cl) cl,
                            coalesce(ok.im, sk.im, rk.im) im, coalesce(sk.basic, ok.basic, rk.basic, 0) basic,
                            coalesce(case when nullif(ok.loc, 0) is not null then ok.src end, case when sk.loc > 0 then sk.src end, rk.src, ok.src, sk.src, 'none') src
                       from ok full join rk on rk.inv_key = ok.inv_key full join sk on sk.inv_key = coalesce(ok.inv_key, rk.inv_key)),
  lines as (
    select 'billed'::text kind, 0::bigint upload_id, coalesce(k.im, date '1900-01-01') m, k.loc, k.fam, k.cl, k.basic amt, k.src from k
    union all
    select 'collected', rc.upload_id, coalesce(rc.rm, date '1900-01-01'), coalesce(case when rc.inv_key is not null then o.loc end, nullif(rc.map_loc, 0), 0),
           coalesce(ki.fam, rc.family), coalesce(ki.cl, rc.cl), rc.amt, case when rc.inv_key is not null and o.loc is not null then 'ledger' else rc.map_state end
      from rc left join osk o on o.inv_key = rc.inv_key left join k ki on ki.inv_key = rc.inv_key
    union all
    select 'outstanding', v_os, coalesce(l.im, date '1900-01-01'), l.location_id, l.family, l.cl, l.os, l.loc_src from l),
  g as materialized (select kind, upload_id, m, loc, fam, bi.fin_client_word(cl) w, src, sum(amt) amt, count(*) n from lines group by 1, 2, 3, 4, 5, 6, 7),
  keys as materialized (select distinct loc, fam, w, m from g where loc > 0),
  cand as (select k.loc, k.fam, k.w, k.m, v.client_code, sum(coalesce(v.revenue, 0)) rev, sum(coalesce(v.cases, 0)) cs
             from keys k join bi.client c on c.family = k.fam
             join bi.v_month_business v on v.location_id = k.loc and v.client_code = c.code and v.month between (k.m - interval '2 months')::date and k.m
            group by 1, 2, 3, 4, 5 having sum(coalesce(v.revenue, 0)) > 0 or sum(coalesce(v.cases, 0)) > 0),
  pick as (select distinct on (c.loc, c.fam, c.w, c.m) c.loc, c.fam, c.w, c.m, c.client_code,
                  case when count(*) over (partition by c.loc, c.fam, c.w, c.m) = 1 then 'only client of the family here'
                       when c.w is not null and bi.fin_client_fits(c.client_code, c.w) then 'client named in the text'
                       else 'largest client of the family here' end basis
             from cand c order by c.loc, c.fam, c.w, c.m, bi.fin_client_fits(c.client_code, c.w) desc, c.rev desc, c.cs desc),
  ins as (
    insert into bi.fin_attr as t (kind, upload_id, m, location_id, client_code, family, basis, client_basis, amt, n, run_id)
    select kind, upload_id, m, loc, cc, fam, src, min(cb), sum(amt), sum(n), v_run
      from (select g.kind, g.upload_id, g.m, g.loc, g.fam, coalesce(g.src, 'none') src, g.amt, g.n,
                   coalesce(p.client_code, case when g.loc > 0 and exists (select 1 from bi.client c where c.code = g.fam) then g.fam end, '') cc,
                   coalesce(p.basis, case when g.loc > 0 and exists (select 1 from bi.client c where c.code = g.fam) then 'family code (no tracker business here)' end) cb
              from g left join pick p on p.loc = g.loc and p.fam = g.fam and p.w is not distinct from g.w and p.m = g.m) z
     group by 1, 2, 3, 4, 5, 6, 7
    on conflict (kind, upload_id, m, location_id, client_code, family, basis) do update set amt = excluded.amt, n = excluded.n, client_basis = excluded.client_basis, run_id = v_run
    returning 1)
  select count(*) into v_n from ins;
  update bi.fin_attr set amt = 0, n = 0 where run_id is distinct from v_run and (amt <> 0 or n <> 0);
  return jsonb_build_object('rows', v_n, 'outstanding_upload', v_os, 'collection_uploads', to_jsonb(v_co), 'sales_upload', v_sr, 'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int);
end $function$;

-- ---------- billing completeness: months covered by the latest sales register count as completely billed ----------
create or replace function bi.fin_billing_basis() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
  with os as (select id, as_of, file_name from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1),
       co as (select min(coalesce(period_from, as_of)) pfrom, max(as_of) thru, (array_agg(file_name order by as_of desc))[1] fname
              from bi.fin_upload where kind = 'collection' and status = 'committed'),
       sr as (select id, as_of, file_name, period_from, period_to from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1),
       cfg as (select coalesce((select (value #>> '{}')::int from bi.fin_config where key = 'billing_complete_days'), 30) d),
       b as (select os.id os_upload, os.as_of, os.file_name os_file, co.pfrom, co.thru, co.fname co_file, cfg.d,
                    (date_trunc('month', co.pfrom) - interval '1 month')::date first_complete,
                    (select max(g::date) from generate_series((date_trunc('month', co.pfrom) - interval '1 month')::date, date_trunc('month', os.as_of), interval '1 month') g
                      where (g + interval '1 month' - interval '1 day')::date + cfg.d <= os.as_of) last_by_snapshot
             from os, co, cfg)
  select jsonb_build_object('outstanding_upload', b.os_upload, 'as_of', b.as_of, 'outstanding_file', b.os_file,
           'receipts_from', b.pfrom, 'receipts_through', b.thru, 'collection_file', b.co_file, 'complete_days', b.d,
           'first_complete', least(b.first_complete, sr.period_from),
           'last_complete', greatest(b.last_by_snapshot, sr.period_to),
           'sales_upload', sr.id, 'sales_file', sr.file_name, 'sales_as_of', sr.as_of, 'sales_from', sr.period_from, 'sales_to', sr.period_to,
           'rule', 'An invoice month is completely billed from ' || to_char(b.first_complete, 'Mon-YYYY') ||
                   ' (receipts start ' || to_char(b.pfrom, 'DD-Mon-YYYY') || ', so earlier invoices that were already paid are missing) and once the outstanding snapshot is at least ' ||
                   b.d || ' days after the month end (snapshot ' || to_char(b.as_of, 'DD-Mon-YYYY') || ')' ||
                   coalesce('; the months in the sales register (' || to_char(sr.period_from, 'Mon-YYYY') || ' to ' || to_char(sr.period_to, 'Mon-YYYY') || ', file of ' || to_char(sr.as_of, 'DD-Mon-YYYY') || ') are complete', '') || '.')
  from b left join sr on true $function$;

-- ---------- Revenue & collections: realisation stays settled ÷ traced value; the flow shows billed (register), traced and status not traced ----------
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '119a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.api_collections(date,jsonb)'::regprocedure, array[
  $r$with iv as (select i.inv_month mo, sum(i.basic) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n, sum(i.collected) col, sum(i.gross_l) gl, sum(i.tds_l) tl$r$,
  $r$with iv as (select i.inv_month mo, sum(coalesce(i.traced_basic, i.basic)) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n, sum(i.collected) col, sum(i.gross_l) gl, sum(i.tds_l) tl,
                     sum(i.basic) billed, sum(coalesce(i.untraced_basic, 0)) untraced, sum(coalesce(i.reg_basic, 0)) reg$r$,
  $r$'invoices', iv.n, 'age_days',$r$,
  $r$'invoices', iv.n, 'billed', round(iv.billed), 'register', case when iv.reg > 0 then round(iv.reg) end, 'status_not_traced', round(iv.untraced), 'age_days',$r$], array[1, 1]);

-- ---------- what the three finance sources hold now (Upload Centre, Revenue & collections, Ask Crux) ----------
create or replace function bi.api_fin_sources(f jsonb default '{}'::jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with sr as (select * from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1),
       ua as (select * from bi.fin_upload where kind = 'unadjusted' and status = 'committed' order by as_of desc, id desc limit 1),
       os as (select * from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1),
       locs as (select l.id from bi.location l where bi.fin_loc_ok(l.id, coalesce(f, '{}'::jsonb)) union select 0 where coalesce(f, '{}'::jsonb) - 'month' = '{}'::jsonb),
       reg as (select i.inv_month mo, sum(i.reg_basic) reg, sum(i.reg_n) reg_n, sum(i.traced_basic) traced, sum(i.untraced_basic) untraced, sum(i.untraced_n) untraced_n,
                      sum(i.reg_open_basic) reg_open, sum(i.open_basic) ledger_open, sum(i.settled_basic) settled, sum(i.basic) billed
                 from bi.fin_inv_month i where i.inv_n > 0 and i.location_id in (select id from locs) and (f->>'client_family' is null or i.family = f->>'client_family')
                  and i.inv_month between coalesce((select period_from from sr), date '2100-01-01') and coalesce((select period_to from sr), date '1900-01-01') group by 1),
       ut as (select t.status, t.location_id, t.bank, t.rcpt_month, t.n, t.amount, t.dup_n, t.dup_amount from bi.fin_unadj_txn t
               where t.upload_id = (select id from ua) and t.n > 0 and t.location_id in (select id from locs))
  select jsonb_build_object(
    'sales_register', (select jsonb_build_object('upload', sr.id, 'file', sr.file_name, 'as_of', sr.as_of, 'from', sr.period_from, 'to', sr.period_to,
        'billed', (select round(sum(reg)) from reg), 'invoices', (select sum(reg_n) from reg), 'traced', (select round(sum(traced)) from reg),
        'status_not_traced', (select round(sum(untraced)) from reg), 'status_not_traced_n', (select sum(untraced_n) from reg),
        'open_per_register', (select round(sum(reg_open)) from reg), 'open_per_ledger', (select round(sum(ledger_open)) from reg),
        'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'billed', round(reg), 'invoices', reg_n, 'traced', round(traced), 'status_not_traced', round(untraced),
                     'settled', round(settled), 'open_per_ledger', round(ledger_open), 'open_per_register', round(reg_open),
                     'realisation_traced', case when traced > 0 then round(settled / traced, 3) end, 'register_settled_share', case when reg > 0 then round(1 - reg_open / reg, 3) end) order by mo) from reg),
        'outstanding_used', false,
        'note', 'Billed revenue for these months comes from the register (each invoice once). Its "Actual Outstanding" and paid / pending remarks are not maintained ' ||
                '(they equal Net on most lines, also on lines marked paid), so receivables come from the outstanding workbook of ' || coalesce(to_char((select as_of from os), 'DD-Mon-YYYY'), '—') || '.',
        'issues', sr.controls->'issues') from sr),
    'unadjusted', (select jsonb_build_object('upload', ua.id, 'file', ua.file_name, 'as_of', ua.as_of, 'from', ua.period_from, 'to', ua.period_to,
        'total', (select round(sum(amount)) from ut), 'lines', (select sum(n) from ut),
        'in_receipts', (select round(sum(amount)) from ut where status = 'in_receipts'), 'before_receipts', (select round(sum(amount)) from ut where status = 'before_receipts'),
        'after_receipts', (select round(sum(amount)) from ut where status = 'after_receipts'), 'not_found', (select round(sum(amount)) from ut where status = 'not_found'),
        'repeated', (select round(sum(dup_amount)) from ut), 'location_not_identified', (select round(sum(amount)) from ut where location_id = 0),
        'by_location', (select jsonb_agg(x order by (x->>'amount')::numeric desc) from (select jsonb_build_object('location_id', ut.location_id, 'location', coalesce(l.label, 'Location not identified'),
                          'amount', round(sum(ut.amount)), 'lines', sum(ut.n), 'in_receipts', round(coalesce(sum(ut.amount) filter (where ut.status = 'in_receipts'), 0)),
                          'older_than_90_days', round(coalesce(sum(ut.amount) filter (where ut.rcpt_month < (date_trunc('month', ua.as_of) - interval '2 months')::date), 0))) x
                          from ut left join bi.location l on l.id = ut.location_id group by ut.location_id, l.label) q),
        'by_month', (select jsonb_agg(jsonb_build_object('month', rcpt_month, 'amount', a, 'in_receipts', ir) order by rcpt_month) from (select rcpt_month, round(sum(amount)) a, round(coalesce(sum(amount) filter (where status = 'in_receipts'), 0)) ir from ut group by 1) q),
        'note', 'Money already in the bank that is not yet applied to an invoice. It is part of cash collected (never added to it); "in receipts" = found in the receipt files by bank, amount and date ± 3 days.',
        'issues', ua.controls->'issues') from ua),
    'uploads', (select jsonb_agg(jsonb_build_object('upload', u.id, 'kind', u.kind, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status, 'committed_at', u.committed_at, 'notes', u.notes) order by u.id desc)
                  from (select * from bi.fin_upload where status in ('committed', 'superseded') order by id desc limit 12) u)) $f$;
revoke all on function bi.api_fin_sources(jsonb) from public, anon, authenticated;

select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  $r$      when 'collections' then bi.api_collections(m, f)$r$,
  $r$      when 'collections' then bi.api_collections(m, f)
      when 'fin_sources' then bi.api_fin_sources(f)   -- wave 119a$r$], array[1]);
