-- Applied to Supabase project via MCP on 20261028122750
-- bi_095b (28-Oct-2026): finance line identity. One invoice / receipt line belongs to one location; it is never shared out.
-- Ledger lines: invoice-number prefix, then the row label, then the sheet (as before); a zone-level or missing result is refined only by a place
-- named in the row label, the client text ("BOI-CHAKAN BRANCH") or the branch text, using the case-mapping reference, and only to a location
-- inside the same zone. Receipt lines additionally use an invoice number quoted in the narration (its prefix) and the payer bank branch
-- (branch code / IFSC -> client branch master -> location, else its district / city / name), and take the client family from the payer bank.
create or replace function bi.rollup_zone(p int) returns text language sql immutable as $f$
  select case p when 46 then 'BHOPAL_MP' when 47 then 'GUJARAT' when 48 then 'LUCKNOW' when 49 then 'MUMBAI_GOA' when 50 then 'REST_MAHA' when 51 then 'PATNA' end $f$;

-- first candidate that is a real location inside the zone of p_base (any real location when p_base is 0); null when none
create or replace function bi.loc_refine(p_base int, p_cands int[]) returns int language sql stable set search_path to 'bi', 'public' as $f$
  select l.id from unnest(p_cands) with ordinality u(c, o) join bi.location l on l.id = u.c and not coalesce(l.is_rollup, false)
   where coalesce(p_base, 0) = 0 or l.zone_group = bi.rollup_zone(p_base) order by u.o limit 1 $f$;

create or replace function bi.fin_os_lines(p_upload bigint)
 returns table(sheet text, r integer, loc text, im date, cl text, br text, inv text, inv_key text, prefix text, basic numeric, gross numeric, tds numeric, net numeric, partial numeric, os numeric, rk text, location_id integer, loc_src text, family text)
 language sql stable security definer set search_path to 'bi', 'public' as $function$
  with x0 as materialized (
    select p.sheet, (x->>0)::int r, x->>1 loc, to_date(x->>2, 'YYYY-MM') im, x->>4 cl, x->>5 br, x->>6 inv, bi.fin_inv_key(x->>6) k,
           (x->>7)::numeric basic, (x->>8)::numeric gross, (x->>9)::numeric tds, (x->>10)::numeric net,
           coalesce((x->>11)::numeric, 0) partial, coalesce((x->>12)::numeric, 0) os, x->>13 rk,
           bi.fin_label(x->>1) lloc, bi.fin_label(x->>4) lcl, bi.fin_label(p.sheet) lsh
    from bi.fin_part p cross join lateral jsonb_array_elements(p.rows) x
    where p.upload_id = p_upload and p.role = 'ledger'),
  e as materialized (select x0.*, substring(x0.k from '^[A-Z]{2,5}') pfx from x0),
  b as materialized (
    select e.*, coalesce(pm.location_id, lm.location_id, sm.location_id, 0) l0,
           case when pm.location_id is not null then 'prefix' when lm.location_id is not null then 'label' when sm.location_id is not null then 'sheet' else 'none' end s0,
           coalesce(cm.family, case when e.lcl is null then '(none)' when e.lcl ~ '^boi' then 'BOI' when e.lcl ~ '^bom' then 'BOM'
                                    when e.lcl ~ '^sbi' then 'SBI' when e.lcl ~ '^canara' then 'CANB' else 'OTHERS' end) fam
    from e
    left join bi.fin_loc_map pm on pm.key_type = 'prefix' and pm.key = e.pfx
    left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = e.lloc
    left join bi.fin_loc_map sm on sm.key_type = 'sheet' and sm.key = e.lsh
    left join bi.fin_client_map cm on cm.key = e.lcl),
  rf as materialized (
    select q.l0, q.loc, q.cl, q.br, q.sheet,
           bi.loc_refine(q.l0, array[bi.loc_of_place(bi.place_of_branch(q.loc), q.sheet), bi.loc_of_place(bi.place_of_branch(q.cl), q.sheet), bi.loc_of_place(bi.place_of_branch(q.br), q.sheet)]) l1
      from (select distinct b.l0, b.loc, b.cl, b.br, b.sheet from b left join bi.location z on z.id = b.l0 where b.l0 = 0 or z.is_rollup) q)
  select b.sheet, b.r, b.loc, b.im, b.cl, b.br, b.inv, b.k, b.pfx, b.basic, b.gross, b.tds, b.net, b.partial, b.os, b.rk,
         coalesce(rf.l1, b.l0), case when rf.l1 is not null then b.s0 || '+place' else b.s0 end, b.fam
  from b left join rf on rf.l0 = b.l0 and rf.loc is not distinct from b.loc and rf.cl is not distinct from b.cl and rf.br is not distinct from b.br and rf.sheet = b.sheet $function$;

create or replace function bi.fin_receipts(p_upload bigint)
 returns table(sheet text, role text, r integer, loc text, bank text, rm date, d date, amt numeric, cl text, br text, inv text, inv_key text, prefix text, basic numeric, im date, ims text, h text, map_loc integer, map_state text, family text)
 language sql stable security definer set search_path to 'bi', 'public' as $function$
  with x0 as materialized (
    select p.sheet, p.role, (x->>0)::int r, x->>1 loc, x->>2 bank, to_date(x->>3, 'YYYY-MM') rm, (x->>4)::date d, (x->>5)::numeric amt,
           x->>6 cl, x->>7 br, x->>8 inv, bi.fin_inv_key(x->>8) k, (x->>9)::numeric basic, to_date(x->>10, 'YYYY-MM') im, x->>11 ims, x->>12 h,
           bi.fin_label(x->>1) lloc, bi.fin_label(x->>6) lcl, nullif(x->>13, '') pbc, nullif(x->>14, '') pbn, bi.fin_inv_key(x->>15) irk
    from bi.fin_part p cross join lateral jsonb_array_elements(p.rows) x
    where p.upload_id = p_upload and p.role in ('bank', 'main')),
  e as materialized (
    select x0.*, substring(x0.k from '^[A-Z]{2,5}') pfx, substring(x0.irk from '^[A-Z]{2,5}') ipfx,
           case when x0.sheet ~* '^bom' then 'BOM' when x0.sheet ~* '^sbi' then 'SBI' when x0.sheet ~* '^canara' then 'CANB' end sfam
      from x0),
  py as materialized (select distinct e.sfam, e.pbc, e.pbn from e where e.k is null and (e.pbc is not null or e.pbn is not null)),
  pz as materialized (select py.sfam, py.pbc, py.pbn, z.location_id, z.family, z.basis from py cross join lateral bi.loc_of_payer(py.sfam, py.pbc, py.pbn) z),
  b as materialized (
    select e.*, pm.location_id pl, lm.location_id ll, lm.confidence lconf, im.location_id il, pz.location_id yl, pz.basis yb, pz.family yf, cm.family cfam
      from e
      left join bi.fin_loc_map pm on pm.key_type = 'prefix' and pm.key = e.pfx
      left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = e.lloc
      left join bi.fin_loc_map im on e.k is null and im.key_type = 'prefix' and im.key = e.ipfx
      left join pz on e.k is null and pz.sfam is not distinct from e.sfam and pz.pbc is not distinct from e.pbc and pz.pbn is not distinct from e.pbn
      left join bi.fin_client_map cm on cm.key = e.lcl)
  select b.sheet, b.role, b.r, b.loc, b.bank, b.rm, b.d, b.amt, b.cl, b.br, b.inv, b.k, b.pfx, b.basic, b.im, b.ims, b.h,
         coalesce(case when b.pl is not null and not exists (select 1 from bi.location z where z.id = b.pl and z.is_rollup) then b.pl end,
                  case when b.ll is not null and not exists (select 1 from bi.location z where z.id = b.ll and z.is_rollup) then b.ll end,
                  bi.loc_refine(coalesce(b.pl, b.ll, 0), array[b.il, b.yl]), b.pl, b.ll, b.il, b.yl, 0),
         case when b.pl is not null and not exists (select 1 from bi.location z where z.id = b.pl and z.is_rollup) then 'prefix'
              when b.ll is not null and not exists (select 1 from bi.location z where z.id = b.ll and z.is_rollup) then 'label'
              when bi.loc_refine(coalesce(b.pl, b.ll, 0), array[b.il, b.yl]) is not null then case when bi.loc_refine(coalesce(b.pl, b.ll, 0), array[b.il]) is not null then 'invoice_ref' else b.yb end
              when b.pl is not null then 'prefix' when b.ll is not null then 'label' when b.il is not null then 'invoice_ref' when b.yl is not null then b.yb
              when b.k is null and (b.lloc is null or b.lconf = 'unallocated') then 'unallocated' else 'none' end,
         coalesce(b.cfam, case when b.lcl is null then coalesce(b.yf, b.sfam, '(none)') when b.lcl ~ '^boi' then 'BOI' when b.lcl ~ '^bom' then 'BOM'
                                  when b.lcl ~ '^sbi' then 'SBI' when b.lcl ~ '^canara' then 'CANB' else 'OTHERS' end)
  from b $function$;
