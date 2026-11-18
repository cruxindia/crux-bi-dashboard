-- wave 113a (18-Nov-2026, owner 19:30 IST): "Tezzract is a client and BRT is a product of BOM, just the way MSME is a product of BOM".
-- 1. BRT is filed under the Bank of Maharashtra family as product "BRT" (same as BOM MSME / BOM Retail).
update bi.client set family = 'BOM', product = 'BRT' where code = 'BRT' and family = 'BRT';
-- 2. The register entry for BRT (Pune, Crux Branch) becomes a product entry, so the BOM family entry at Pune (Business Associate) does not take it over.
update bi.operating_model set client_family = 'BOM', client_code = 'BRT', updated_by = 'wave 113a', updated_at = now()
 where client_family = 'BRT' and client_code is null;
-- 3. Finance: invoices and receipts named "BRT" count under BOM (re-derived by the 10-minute finance job).
update bi.fin_client_map set family = 'BOM', note = 'BOM product BRT (owner, 18-Nov-2026)', updated_by = 'wave 113a', updated_at = now() where key = 'brt';
-- 4. Structure reference: BRT shown as a BOM product; Tezzract described as an MSME lending platform (client, no branch network).
delete from bi.client_structure where client_family = 'BRT' and unit_code = 'UNKNOWN';
insert into bi.client_structure (client_family, unit_code, unit_name, kind, level_no, parent_code, role, products, crux_work, published_count, as_of, source_url, source_note, confidence, verified_on)
values ('BOM', 'PROD_BRT', 'BRT (product)', 'other', 7, null,
        'A Bank of Maharashtra product that Crux tracks under the code BRT, in the same way as MSME and Retail (owner, 18-Nov-2026).',
        'BRT', 'Verifications for this product; tracker line "BRT".', null, null, null, 'Owner confirmation, 18-Nov-2026', 'internal', date '2026-11-18')
on conflict (client_family, unit_code) do nothing;
update bi.client_structure
   set unit_code = 'PLATFORM', unit_name = 'Tezzract — MSME lending platform', kind = 'other', level_no = 1,
       role = 'A client of Crux (owner, 18-Nov-2026): an MSME lending platform that lends together with partner lenders (press: Clix Group partnership). No branch network, so its work is tracked by Crux location only.',
       products = 'MSME loans', crux_work = 'Verifications for Tezzract loans.', confidence = 'press',
       source_url = 'https://ibsintelligence.com/ibsi-news/clix-group-partners-with-msme-lending-platform-tezzract/',
       source_note = 'IBS Intelligence: "Clix Group partners with MSME lending platform Tezzract"; owner confirmation 18-Nov-2026', verified_on = date '2026-11-18'
 where client_family = 'TEZZ' and unit_code = 'UNKNOWN';
update bi.client_family_research set entity_type = 'not_branch_network', research_status = 'not_applicable', updated_at = now(),
       coverage_note = 'Resolved 18-Nov-2026 (owner): BRT is a Bank of Maharashtra product, filed under the BOM family (client code BRT, product BRT) like MSME and Retail. No separate branch network.'
 where family = 'BRT';
update bi.client_family_research set updated_at = now(),
       coverage_note = 'Client (owner, 18-Nov-2026). MSME lending platform; no physical branch network found.'
 where family = 'TEZZ';
insert into bi.audit_log (actor, action, entity, entity_key, detail)
values ('wave 113a', 'client_family_change', 'client', 'BRT',
        jsonb_build_object('from', 'BRT', 'to', 'BOM', 'product', 'BRT', 'register', 'Pune entry kept as product entry (Crux Branch)', 'tezzract', 'client; MSME lending platform', 'source', 'owner 18-Nov-2026 19:30 IST'));
