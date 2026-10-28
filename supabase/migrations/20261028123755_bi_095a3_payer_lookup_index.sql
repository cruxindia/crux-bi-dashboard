-- Applied to Supabase project via MCP on 20261028123755
-- bi_095a3: payer look-up uses the (family, code) index; an IFSC is turned into family + branch code; place words computed once
create or replace function bi.loc_of_payer(p_family text, p_code text, p_name text) returns table(location_id int, family text, basis text) language sql stable set search_path to 'bi', 'public' as $f$
  with k as (select case when p_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$' then case left(p_code, 4) when 'SBIN' then 'SBI' when 'MAHB' then 'BOM' when 'BKID' then 'BOI' when 'CNRB' then 'CANB'
                                                                      when 'IBKL' then 'IDBI' when 'UBIN' then 'UNION' when 'BARB' then 'BOB' when 'PUNB' then 'PNB' end
                         else p_family end fam,
                    ltrim(case when p_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$' then right(p_code, 6) else p_code end, '0') code),
       b as (select m.location_id, m.client_family, m.district, m.city, m.state, m.branch_name
               from k join bi.client_branch_master m on m.client_family = k.fam and m.code_norm = k.code
              where k.code ~ '^\d{1,6}$' order by (m.location_id is null) limit 1),
       pn as (select bi.place_of_branch(p_name) pl)
  select coalesce(b.location_id, bi.loc_of_place(b.district), bi.loc_of_place(b.city), bi.loc_of_place(bi.place_of_branch(b.branch_name)), bi.loc_of_place(pn.pl),
                  (select s.location_id from bi.ref_state_default s where upper(s.state) = upper(b.state))),
         coalesce(b.client_family, (select fam from k), p_family),
         case when b.location_id is not null then 'payer_branch' when b.client_family is not null then 'payer_branch_place' when pn.pl is not null then 'payer_branch_name' end
    from pn left join b on true
   where b.client_family is not null or pn.pl is not null $f$;
