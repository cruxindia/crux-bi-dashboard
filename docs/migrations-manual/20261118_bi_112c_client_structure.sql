-- wave 112c (18-Nov-2026): how each client bank is organised — levels (head office → circle / zone → region → branch) and the processing
-- centres beside them, with what each handles (products) and what work Crux can expect from it; researched from public sources (URL per row).
-- bi.client_unit_rule tags every unit in the client branch master with its level / centre (name rules per bank, then general rules);
-- bi.api_client_structure (bi_call 'client_structure') gives the chart with master counts, active units and Force1 cases per level.
create table if not exists bi.client_structure (
  client_family text not null, unit_code text not null, unit_name text not null, kind text not null check (kind in ('admin', 'branch', 'processing', 'other')),
  level_no int not null, parent_code text, role text, products text, crux_work text, published_count text, as_of text,
  source_url text, source_note text, confidence text check (confidence in ('official', 'press', 'encyclopedia', 'internal')),
  verified_on date not null default current_date, primary key (client_family, unit_code));
comment on table bi.client_structure is 'wave 112c: administrative structure of each client (levels and processing centres, products, sources). Edit rows when a bank changes its structure.';
create table if not exists bi.client_unit_rule (
  id bigserial primary key, client_family text not null, priority int not null, name_regex text not null, branch_type text, unit_code text not null);
comment on table bi.client_unit_rule is 'wave 112c: name rules (upper-case unit name ~ name_regex) that tag client branch master units with a client_structure unit_code; family rules first, then client_family = ''*''.';
create table if not exists bi.branch_unit_tag (
  branch_uid text primary key, client_family text not null, unit_code text not null, tagged_at timestamptz not null default now());
create index if not exists branch_unit_tag_fam_unit on bi.branch_unit_tag (client_family, unit_code);
revoke all on bi.client_structure, bi.client_unit_rule, bi.branch_unit_tag from anon, authenticated;
delete from bi.client_structure; delete from bi.client_unit_rule;
insert into bi.client_structure (client_family, unit_code, unit_name, kind, level_no, parent_code, role, products, crux_work, published_count, as_of, source_url, source_note, confidence) values
('SBI', 'CC', 'Corporate Centre', 'admin', 1, null, 'Head office in Mumbai: policy, products and limits for the whole bank.', 'All products', 'No cases expected.', '1', null, 'https://wiki.riteme.site/wiki/State_Bank_of_India', 'Wikipedia: headquarters State Bank Bhavan, Mumbai', 'encyclopedia'),
('SBI', 'LHO', 'Local Head Office (circle)', 'admin', 2, 'CC', 'Regional hub over a circle (one or more states).', 'All products', 'No cases expected; circle-level office.', '17', null, 'https://wiki.riteme.site/wiki/State_Bank_of_India', '"SBI has 17 regional hubs known as local head offices (LHOs)"', 'encyclopedia'),
('SBI', 'AO', 'Administrative Office (zone)', 'admin', 3, 'LHO', 'Zonal office under an LHO; oversees its Regional Business Offices.', 'All products', 'No cases expected.', '57', null, 'https://wiki.riteme.site/wiki/State_Bank_of_India', '"under whom are 57 administrative offices (AOs)"', 'encyclopedia'),
('SBI', 'RBO', 'Regional Business Office', 'admin', 4, 'AO', 'Administrative sub-office that directly controls about 40–50 branches.', 'All products', 'No cases expected.', null, null, 'https://wiki.riteme.site/wiki/State_Bank_of_India', '"each RBO has some 40 to 50 branches"', 'encyclopedia'),
('SBI', 'BRANCH', 'Branch', 'branch', 5, 'RBO', 'Sources deposits and loans; sends retail loan applications to the nearby processing centre (RACPC) for appraisal and sanction.', 'Deposits; loans sourced', 'Cases from branches are loans they handle themselves; most retail loans are appraised at the RACPC.', '22,405–22,542', null, 'https://wiki.riteme.site/wiki/State_Bank_of_India ; https://www.business-standard.com/article/finance/sbi-setting-up-cells-for-quick-retail-loan-sanctions-104092501055_1.html', 'Branch counts from Wikipedia; retail applications go from branches to the processing cell (Business Standard, 25-Sep-2004)', 'encyclopedia'),
('SBI', 'SME_BRANCH', 'SME branch', 'branch', 5, 'RBO', 'SME-intensive or dedicated branch.', 'SME / MSME loans', 'SME loan verifications.', '829', '31-Mar-2022', 'https://sbi.bank.in/corporate/AR2122/assets/PDF/English/11-3.4-Small & Medium Enterprises.pdf', '"829 SME intensive & dedicated branches across India" (Annual Report 2021-22)', 'official'),
('SBI', 'RACPC', 'RACPC — Retail Assets Central Processing Centre', 'processing', 6, 'AO', 'Receives the retail loan applications of nearby branches and appraises and sanctions them.', 'Home, car, education and personal loans', 'Retail loan verifications (property, residence, income, documents).', null, null, 'https://www.business-standard.com/article/finance/sbi-setting-up-cells-for-quick-retail-loan-sanctions-104092501055_1.html ; https://www.deccanherald.com/business/sbis-credit-processing-centres-2338378', 'Business Standard 25-Sep-2004: cells "receive all the retail loan applications from the nearby branches"; Deccan Herald: housing, education and vehicle loans', 'press'),
('SBI', 'MINI_RACPC', 'Mini RACPC', 'processing', 6, 'AO', 'A smaller retail processing centre for a town or district.', 'Home, car, education and personal loans', 'Retail loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Named "Mini RACPC" in the bank''s IFSC list; no public definition found', 'internal'),
('SBI', 'RASMECCC', 'RASMECCC — Retail Assets & SME City Credit Centre', 'processing', 6, 'AO', 'Processes the personal (retail) and SME loans of the branches of a city.', 'Personal / retail and SME loans', 'Retail and SME loan verifications.', null, null, 'https://www.business-standard.com/article/pti-stories/sbi-opens-rasmecc-in-shillong-114051501322_1.html', 'Business Standard 15-May-2014: "deals with the Personal and SME loans of 21 city based branches"', 'press'),
('SBI', 'SMECCC', 'SMECCC — SME City Credit Centre', 'processing', 6, 'AO', 'Processes the SME loans of the branches of a city.', 'SME / MSME loans', 'SME loan verifications.', null, null, 'https://www.deccanherald.com/business/sbis-credit-processing-centres-2338378', 'Deccan Herald: "Small & Medium Enterprises City Credit Centre"', 'press'),
('SBI', 'RACC', 'RACC — Retail Asset Credit Centre (Rural & Development Banking)', 'processing', 6, 'AO', 'Retail loan processing for rural and semi-urban branches under the Rural & Development Banking (R&DB / FIMM) vertical.', 'Retail loans (rural / semi-urban)', 'Retail loan verifications in smaller towns.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "R AND DB RETAIL ASSET CREDIT CENTRE TUMKUR" and "FIMM RACC JALGAON" in the IFSC list; expansion read from those names', 'internal'),
('SBI', 'CAPC', 'Centralised Agri Processing Cell', 'processing', 6, 'AO', 'Agriculture loan processing.', 'Agriculture loans', 'Agri loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "CENTRALIZED AGRI PROCESSING CELL CAPC, AO THANE"', 'internal'),
('SBI', 'SARC', 'SARC — Stressed Assets Resolution Centre', 'other', 7, 'AO', 'Resolution and recovery of stressed loans.', 'Stressed loans', 'Recovery-related checks only.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "STRESSED ASSETS RESOLUTION CELL, SARC, COIMBATORE"', 'internal'),
('SBI', 'RECOVERY', 'Stressed asset branches (SAMB / SARB)', 'other', 7, 'LHO', 'Stressed asset management and recovery.', 'Stressed loans', 'Recovery-related checks only.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('SBI', 'NONLENDING', 'Back-office units (liability / trade / pension CPCs, clearing, currency, treasury)', 'other', 8, null, 'Account opening, trade finance, pensions, clearing, cash and treasury.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as LCPC, TFCPC, CENTRAL PENSION PROCESSING CENTRE, CURRENCY ADMINISTRATION CELL', 'internal'),
('BOM', 'HO', 'Head Office (Pune)', 'admin', 1, null, 'Policy, products and central credit.', 'All products', 'No cases expected.', '1', null, 'https://bankofmaharashtra.bank.in/writereaddata/documentlibrary/6dcd7431-ca5c-4e48-9f59-a27a2059f8c2.pdf', 'Investor meet, May 2025', 'official'),
('BOM', 'ZO', 'Zonal Office', 'admin', 2, 'HO', 'Runs the branches of a zone.', 'All products', 'No cases expected.', '50', 'Mar-2025', 'https://bankofmaharashtra.bank.in/writereaddata/documentlibrary/6dcd7431-ca5c-4e48-9f59-a27a2059f8c2.pdf', '"2,591 branches (including 50 zonal offices)"', 'official'),
('BOM', 'BRANCH', 'Branch', 'branch', 3, 'ZO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', '2,606', 'Mar-2025', 'https://bankofmaharashtra.bank.in/writereaddata/documentlibrary/6dcd7431-ca5c-4e48-9f59-a27a2059f8c2.pdf', '"Total Branches 2,606"', 'official'),
('BOM', 'CPC', 'Centralised Processing Centre (CPC)', 'processing', 4, 'ZO', 'Loan sanction is being centralised at CPCs.', 'Loans (products not listed in the source)', 'Loan verifications where sanction is centralised.', null, 'Mar-2025', 'https://bankofmaharashtra.bank.in/writereaddata/documentlibrary/6dcd7431-ca5c-4e48-9f59-a27a2059f8c2.pdf', '"Centralization of sanction at CPC"', 'official'),
('BOM', 'RAB', 'Retail Asset Branch', 'processing', 4, 'ZO', 'Specialised branch for retail loans.', 'Retail loans (home, vehicle, personal)', 'Retail loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "RETAIL ASSET BRANCH NAGPUR"; products inferred from the name', 'internal'),
('BOM', 'HFB', 'Housing Finance Branch', 'branch', 4, 'ZO', 'Specialised branch for housing loans.', 'Home loans', 'Home loan verifications.', null, 'Mar-2025', 'https://bankofmaharashtra.bank.in/writereaddata/documentlibrary/6dcd7431-ca5c-4e48-9f59-a27a2059f8c2.pdf ; RBI IFSC list (unit names in the client branch master)', 'Investor meet: "specialised branches like HFB"; name "HOUSING FINANCE BRANCH BHUBANESWAR" in the IFSC list', 'official'),
('BOM', 'MSME', 'MSME branch / MSME credit', 'branch', 4, 'ZO', 'MSME lending.', 'MSME loans', 'MSME loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "MSME SATARA", "CREDIT - MSME"', 'internal'),
('BOM', 'RECOVERY', 'Asset recovery / stressed asset branches', 'other', 5, 'ZO', 'Recovery of stressed loans.', 'Stressed loans', 'Recovery-related checks only.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "ASSET RECOVERY BRANCH PUNE", "STRESSED ASSET MANAGEMENT BRANCH"', 'internal'),
('BOM', 'NONLENDING', 'Back-office units', 'other', 6, null, 'Digital, treasury, government business, service branches.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('IDBI', 'HO', 'Corporate Centre / Head Office (Mumbai)', 'admin', 1, null, 'Policy and central functions.', 'All products', 'No cases expected.', '1', null, 'RBI IFSC list (unit names in the client branch master)', 'Names "CORPORATE CENTRE MUMBAI", "HEAD OFFICE SANTACRUZ"', 'internal'),
('IDBI', 'ZO', 'Zonal Office', 'admin', 2, 'HO', 'Runs the branches of a zone.', 'All products', 'No cases expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Count not found in the public sources checked', 'internal'),
('IDBI', 'BRANCH', 'Branch', 'branch', 3, 'ZO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', '1,890+', null, 'https://www.idbi.bank.in/about-us.aspx', '"1890+ Branches Across India"', 'official'),
('IDBI', 'RAC', 'RAC — Retail Asset Centre', 'processing', 4, 'ZO', 'Processes housing and mortgage loans for an area.', 'Home loans, loan against property', 'Home loan / mortgage verifications.', null, 'Mar-2024', 'https://telanganatoday.com/idbi-inaugurates-rac-center-in-lb-nagar', 'Telangana Today 6-Mar-2024: "Retail Asset Centre (Housing and Mortgage Loans)"', 'press'),
('IDBI', 'MSME_BRANCH', 'Specialised MSME branch', 'branch', 4, 'ZO', 'MSME lending.', 'MSME loans', 'MSME loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Name "SPECIALISED MSME BRANCH"', 'internal'),
('IDBI', 'SUBMEMBER', 'Other banks listed under IDBI codes', 'other', 9, null, 'Co-operative and other banks that use IDBI IFSC codes (sub-members).', 'Not IDBI business', 'Not IDBI work.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "... CO OP BANK LTD HEAD OFFICE"', 'internal'),
('IDBI', 'NONLENDING', 'Back-office units (currency chests, cash, RTGS)', 'other', 8, null, 'Cash and payment operations.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('BOI', 'HO', 'Head Office (Mumbai)', 'admin', 1, null, 'Policy and central functions.', 'All products', 'No cases expected.', '1', null, 'RBI IFSC list (unit names in the client branch master)', 'Name "HEAD OFFICE"', 'internal'),
('BOI', 'NBG', 'National Banking Group office', 'admin', 2, 'HO', 'Oversees several zones.', 'All products', 'No cases expected.', '12', 'Apr-2022', 'https://www.indiainfoline.com/news/markets/bank-of-india-inaugurates-nine-new-zones-and-two-new-national-banking-group-offices', '"Bank of India will have 12 National Banking Group offices and 68 Zonal Offices"', 'press'),
('BOI', 'ZO', 'Zonal Office', 'admin', 3, 'NBG', 'Runs the branches of a zone.', 'All products', 'No cases expected.', '68', 'Apr-2022', 'https://www.indiainfoline.com/news/markets/bank-of-india-inaugurates-nine-new-zones-and-two-new-national-banking-group-offices', 'Same article', 'press'),
('BOI', 'BRANCH', 'Branch', 'branch', 4, 'ZO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', '5,105', 'Mar-2022', 'https://www.indiainfoline.com/news/markets/bank-of-india-inaugurates-nine-new-zones-and-two-new-national-banking-group-offices', '"vast network of 5105 branches"', 'press'),
('BOI', 'RETAIL_HUB', 'Retail hub', 'processing', 5, 'ZO', 'Retail loan centre for an area.', 'Home loans, loan against property, education, auto loans', 'Retail loan verifications.', null, 'Dec-2006', 'https://www.business-standard.com/article/finance/boi-eyeing-top-spot-via-retail-106121901074_1.html ; RBI IFSC list (unit names in the client branch master)', 'Business Standard 19-Dec-2006: retail hubs for housing loan, LAP, education loan, auto finance; names such as "PUNE RETAIL HUB" today', 'press'),
('BOI', 'SME_BRANCH', 'SME branch', 'branch', 5, 'ZO', 'SME lending.', 'SME / MSME loans', 'SME loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "BANGALORE SME"', 'internal'),
('BOI', 'RECOVERY', 'Asset recovery branches', 'other', 6, 'ZO', 'Recovery of stressed loans.', 'Stressed loans', 'Recovery-related checks only.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "ASSET RECOVERY BRANCH SURAT"', 'internal'),
('BOI', 'CPC', 'Central processing cells', 'processing', 7, 'ZO', 'Back-office processing.', 'Operations (not loan appraisal)', 'Usually no loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "CPC TELANGANA", "ZONAL CENTRALISED OPERATIONS DEPARTMENT"', 'internal'),
('BOI', 'SUBMEMBER', 'Sponsored regional rural bank units', 'other', 9, null, 'Units of a sponsored rural bank listed under BOI codes.', 'Not BOI business', 'Not BOI work.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names with "MPGB"', 'internal'),
('BOI', 'NONLENDING', 'Back-office units', 'other', 8, null, 'Service branches, currency chests, cards, digital.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('UNION', 'CO', 'Central Office (Mumbai)', 'admin', 1, null, 'Policy and central functions.', 'All products', 'No cases expected.', '1', null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('UNION', 'ZO', 'Zonal Office', 'admin', 2, 'CO', 'Oversees the regional offices of a zone.', 'All products', 'No cases expected.', 'about 22 on the MLP list', null, 'https://www.unionbankofindia.bank.in/en/details/mlps-centralized-msme-loan-processing-centre-at-regional-offices', 'The bank''s MLP page groups its centres under about 22 zones', 'official'),
('UNION', 'RO', 'Regional Office', 'admin', 3, 'ZO', 'Runs the branches of a region; hosts the MSME Loan Point.', 'All products', 'No cases expected.', '138 with an MLP', null, 'https://www.unionbankofindia.bank.in/en/details/mlps-centralized-msme-loan-processing-centre-at-regional-offices', '138 MLPs listed, one per regional office', 'official'),
('UNION', 'BRANCH', 'Branch', 'branch', 4, 'RO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('UNION', 'ULP', 'Union / Retail Loan Point (ULP / RLP)', 'processing', 5, 'RO', 'Specialised hub that processes and sanctions retail loans.', 'Retail loans (home, vehicle, personal, education)', 'Retail loan verifications.', null, 'May-2024', 'https://hellobanker.in/union-bank-orders-to-open-retail-loan-points-on-holidays/ ; RBI IFSC list (unit names in the client branch master)', '"Retail Loan Points are specialized processing hubs established for processing and sanctioning of Retail Loans"; products from the bank''s retail range', 'press'),
('UNION', 'MLP', 'MSME Loan Point (MSME Saral centre)', 'processing', 5, 'RO', 'Centralised MSME loan processing centre at each regional office.', 'MSME loans', 'MSME loan verifications.', '138', null, 'https://www.unionbankofindia.bank.in/en/details/mlps-centralized-msme-loan-processing-centre-at-regional-offices', '"Centralized MSME Loan processing Centre at Regional Offices"', 'official'),
('UNION', 'ALP', 'Agriculture Loan Point', 'processing', 5, 'RO', 'Agriculture loan processing.', 'Agriculture loans', 'Agri loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "AGRICULTURE LOAN POINT MAHABUBNAGAR"', 'internal'),
('UNION', 'SME_BRANCH', 'SME / MSME branch', 'branch', 5, 'RO', 'SME lending.', 'SME / MSME loans', 'SME loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "AMBATTUR MSME"', 'internal'),
('UNION', 'RECOVERY', 'Asset recovery branches (ARB)', 'other', 6, 'RO', 'Recovery of stressed loans.', 'Stressed loans', 'Recovery-related checks only.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "ASSET RECOVERY BRANCH PUNE"', 'internal'),
('UNION', 'SUBMEMBER', 'Sponsored regional rural bank units', 'other', 9, null, 'Units of a sponsored rural bank listed under Union Bank codes.', 'Not Union Bank business', 'Not Union Bank work.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names with "APGB"', 'internal'),
('UNION', 'NONLENDING', 'Back-office units', 'other', 8, null, 'Currency chests, service branches, cards, MICR, pensions.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('CANB', 'HO', 'Head Office (Bengaluru) and wings', 'admin', 1, null, 'Wings for retail credit, MSME, operations (central processing), recovery and others.', 'All products', 'No cases expected.', '1', 'Jul-2026', 'https://www.canarabank.bank.in/documents/d/guest/organization-structure_xl-02-07-2026', 'Organisation structure 02-07-2026', 'official'),
('CANB', 'CIRCLE', 'Circle Office', 'admin', 2, 'HO', 'Oversees the regional offices of a circle.', 'All products', 'No cases expected.', 'about 28 listed', 'Jul-2026', 'https://www.canarabank.bank.in/documents/d/guest/organization-structure_xl-02-07-2026', '28 city names under "CIRCLE OFFICES"', 'official'),
('CANB', 'RO', 'Regional Office', 'admin', 3, 'CIRCLE', 'Runs the branches of a region; Retail Asset Hubs often sit in its premises.', 'All products', 'No cases expected.', null, null, 'https://starofmysore.com/?p=50576', 'Star of Mysore 26-Sep-2017', 'press'),
('CANB', 'BRANCH', 'Branch', 'branch', 4, 'RO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('CANB', 'RAH', 'Retail Asset Hub', 'processing', 5, 'RO', 'Exclusive loan processing centre for retail loans of an area.', 'Home, vehicle and personal loans', 'Retail loan verifications.', null, 'Sep-2017', 'https://starofmysore.com/?p=50576', '"exclusive loan processing centre"; "Housing and Vehicle Loans were being processed and sanctioned"', 'press'),
('CANB', 'MSME_SULABH', 'MSME Sulabh', 'processing', 5, 'RO', 'Centralised centre that receives, processes and sanctions MSME credit proposals.', 'MSME loans', 'MSME loan verifications.', null, 'Aug-2009', 'https://www.business-standard.com/article/finance/canbank-expands-sme-loan-processing-centres-109080500037_1.html', '"directly receive process and sanction the credit proposals"', 'press'),
('CANB', 'ACC', 'Agricultural Credit Centre', 'processing', 5, 'RO', 'Agriculture loan processing.', 'Agriculture loans', 'Agri loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "AGRICULTURAL CREDIT CENTRE SALEM"', 'internal'),
('CANB', 'CPC', 'Central processing centres', 'processing', 6, 'HO', 'Back-office processing (Central Processing Vertical).', 'Operations (not loan appraisal)', 'Usually no loan verifications.', null, 'Jul-2026', 'https://www.canarabank.bank.in/documents/d/guest/organization-structure_xl-02-07-2026 ; RBI IFSC list (unit names in the client branch master)', '"Central Processing Vertical" in the Operations Wing', 'official'),
('CANB', 'SME_BRANCH', 'SME branch', 'branch', 5, 'RO', 'SME lending.', 'SME / MSME loans', 'SME loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "BHILWARA SME"', 'internal'),
('CANB', 'RECOVERY', 'Asset Recovery Management (ARM) branches', 'other', 6, 'RO', 'Recovery of stressed loans.', 'Stressed loans', 'Recovery-related checks only.', null, 'Jul-2026', 'https://www.canarabank.bank.in/documents/d/guest/organization-structure_xl-02-07-2026 ; RBI IFSC list (unit names in the client branch master)', '"Recovery, Legal & Stressed Assets Wing"; names "ARM BRANCH ..."', 'official'),
('CANB', 'NONLENDING', 'Back-office units', 'other', 8, null, 'Currency chests, clearing, HO sections.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('PSB', 'HO', 'Head Office (New Delhi)', 'admin', 1, null, 'Policy and central functions.', 'All products', 'No cases expected.', '1', null, 'https://www.gktoday.in/punjab-sind-bank-cen-marg-hub-for-retail-and-msme-loans', 'GKToday', 'press'),
('PSB', 'ZO', 'Zonal Office', 'admin', 2, 'HO', 'Runs the branches of a zone.', 'All products', 'No cases expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "ZONAL OFFICE DELHI"', 'internal'),
('PSB', 'BRANCH', 'Branch', 'branch', 3, 'ZO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('PSB', 'CENMARG', 'Cen-MARG hub / specialised retail asset branches', 'processing', 4, 'HO', 'Centralised hub that processes retail and MSME loans from application to disbursement.', 'Home, vehicle, personal, education loans; MSME loans', 'Retail and MSME loan verifications.', null, '2021', 'https://www.gktoday.in/punjab-sind-bank-cen-marg-hub-for-retail-and-msme-loans ; RBI IFSC list (unit names in the client branch master)', 'GKToday: centralised hub for retail and MSME loans; names "SPECIALISED RETAIL ASSET BRANCH"', 'press'),
('PSB', 'RECOVERY', 'Asset recovery / stressed asset units', 'other', 6, 'ZO', 'Recovery of stressed loans.', 'Stressed loans', 'Recovery-related checks only.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "SPECIALIZED ASSET RECOVERY BRANCH"', 'internal'),
('PSB', 'NONLENDING', 'Back-office units', 'other', 8, null, 'HO departments and service branches.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('KBL', 'HO', 'Head Office (Mangaluru)', 'admin', 1, null, 'Policy and central functions.', 'All products', 'No cases expected.', '1', null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('KBL', 'RO', 'Regional Office', 'admin', 2, 'HO', 'Runs the branches of a region.', 'All products', 'No cases expected.', '14', 'Feb-2024', 'https://karnatakabank.com/sites/default/files/2024-02/regional-offices.pdf', 'Regional offices list (14)', 'official'),
('KBL', 'BRANCH', 'Branch', 'branch', 3, 'RO', 'Sources and services loans and deposits.', 'Deposits; loans sourced', 'Loan verifications from branches.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('KBL', 'RAC', 'Retail Assets Centre', 'processing', 4, 'HO', 'Centralised hub for retail loans: underwriting, sanction, operations and disbursement.', 'Retail loans (home, mortgage); MSME planned', 'Retail loan verifications.', '1 (J P Nagar, Bengaluru)', 'Dec-2024', 'https://ffnews.com/newsarticle/fintech/karnataka-bank-launches-retail-assets-centre-to-grow-the-retail-assets-business-deliver-best-in-class-customer-experience/', 'FF News 11-Dec-2024', 'press'),
('KBL', 'NONLENDING', 'Back-office units', 'other', 8, null, 'Currency chests, service branches.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('AXIS', 'HO', 'Corporate Office (Mumbai)', 'admin', 1, null, 'Policy and central functions.', 'All products', 'No cases expected.', '1', null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('AXIS', 'ZO', 'Zonal Office', 'admin', 2, 'HO', 'Regional administration.', 'All products', 'No cases expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "NORTH ZONAL OFFICE - NZO"', 'internal'),
('AXIS', 'BRANCH', 'Branch', 'branch', 3, 'ZO', 'Sources and services loans and deposits.', 'Home loans, LAP, personal, auto and other retail loans; deposits', 'Loan verifications from branches.', '6,275', 'Mar-2026', 'https://www.axis.bank.in/annual-reports/2025-2026/pdf/Retail Banking.pdf', '"taking our total footprint to 6,275 branches"', 'official'),
('AXIS', 'CPU', 'Central processing units and hubs', 'processing', 4, 'HO', 'Centralised back-office and credit operations hubs.', 'Operations', 'Usually no loan verifications.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "CENTRAL PROCESSING UNIT", "RETAIL ASSET MANAGEMENT GROUP"', 'internal'),
('AXIS', 'SUBMEMBER', 'Other banks listed under Axis codes', 'other', 9, null, 'Co-operative banks that use Axis IFSC codes.', 'Not Axis business', 'Not Axis work.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "THE HUBLI URBAN COOP BANK LTD"', 'internal'),
('AXIS', 'NONLENDING', 'Back-office units', 'other', 8, null, 'Service branches, currency chests, treasury.', 'No loan processing', 'No loan verifications expected.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('LICHFL', 'HO', 'Corporate & Registered Office (Mumbai)', 'admin', 1, null, 'Policy and central functions.', 'Home loans, loan against property', 'No cases expected.', '1', null, 'https://en.wikipedia.org/wiki/LIC_Housing_Finance', 'Wikipedia', 'encyclopedia'),
('LICHFL', 'RO', 'Regional Office', 'admin', 2, 'HO', 'Runs the area offices of a region.', 'Home loans, LAP', 'No cases expected.', '9 (FY2019); 10 on the current website list', 'FY2019', 'https://en.wikipedia.org/wiki/LIC_Housing_Finance', '"9 regional offices, 24 back offices, and 282 marketing Offices"', 'encyclopedia'),
('LICHFL', 'BACK_OFFICE', 'Back office', 'processing', 3, 'RO', 'Back offices behind the marketing / area offices.', 'Home loans, LAP', 'Possible processing point for verifications (role not stated in the source).', '24', 'FY2019', 'https://en.wikipedia.org/wiki/LIC_Housing_Finance', 'Same sentence', 'encyclopedia'),
('LICHFL', 'BRANCH', 'Area / marketing office', 'branch', 4, 'RO', 'Sources home loans and loans against property.', 'Home loans, LAP', 'Home loan verifications.', '282 (FY2019); 311 area offices on the website list', 'FY2019', 'https://en.wikipedia.org/wiki/LIC_Housing_Finance', 'Same sentence', 'encyclopedia'),
('CANFH', 'HO', 'Head Office (Bengaluru)', 'admin', 1, null, 'Policy; central credit processing and disbursement.', 'Home loans', 'No cases expected.', '1', null, 'https://www.canfinhomes.com/overview', '"Headquartered in Bengaluru with 6 Zones"', 'official'),
('CANFH', 'ZONE', 'Zone', 'admin', 2, 'HO', 'Groups the branches of a region.', 'Home loans', 'No cases expected.', '6', null, 'https://www.canfinhomes.com/overview', 'Same', 'official'),
('CANFH', 'BRANCH', 'Branch', 'branch', 3, 'ZONE', 'Sources and services home loans.', 'Home loans (incl. affordable housing)', 'Home loan verifications.', '270', null, 'https://www.canfinhomes.com/overview', '"270 branches"', 'official'),
('CANFH', 'CCPC', 'Central Credit Processing Centre (Bengaluru)', 'processing', 4, 'HO', 'Central credit processing and central disbursement.', 'Home loans', 'Possible processing point for verifications.', '1', null, 'https://www.canfinhomes.com/overview', '"We have a Central Credit Processing Centre and Central Disbursement System at Bengaluru"', 'official'),
('AXISF', 'HO', 'Corporate Office (Mumbai)', 'admin', 1, null, 'Policy and central functions.', 'Loans (NBFC)', 'No cases expected.', '1', null, 'Company website branch list', 'Office named on the website list', 'internal'),
('AXISF', 'BRANCH', 'Branch', 'branch', 2, 'HO', 'Sources loans.', 'Loans (NBFC)', 'Loan verifications.', '85 on the website list', null, 'Company website branch list', 'Website list in the client branch master', 'internal'),
('SVC', 'HO', 'Head Office (Mumbai)', 'admin', 1, null, 'Policy and central functions (co-operative bank).', 'All products', 'No cases expected.', '1', null, 'https://www.svc.bank.in/contact-us', 'SVC Co-operative Bank contact page', 'official'),
('SVC', 'BRANCH', 'Branch', 'branch', 2, 'HO', 'Sources and services loans and deposits.', 'Deposits; loans', 'Loan verifications from branches.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Unit names in the IFSC list', 'internal'),
('SVC', 'SUBMEMBER', 'Other banks listed under SVC codes', 'other', 9, null, 'Co-operative banks that use SVC IFSC codes.', 'Not SVC business', 'Not SVC work.', null, null, 'RBI IFSC list (unit names in the client branch master)', 'Names such as "THE HUBLI URBAN COOP BANK"', 'internal'),
('DNSB', 'HO', 'Central Office (Dombivli)', 'admin', 1, null, 'Policy and central functions (co-operative bank).', 'All products', 'No cases expected.', '1', null, 'https://dns.bank.in/about-us', 'About DNSB', 'official'),
('DNSB', 'BRANCH', 'Branch', 'branch', 2, 'HO', 'Sources and services loans and deposits.', 'Deposits; loans', 'Loan verifications from branches.', '70–71 in 15 districts of Maharashtra', null, 'https://dns.bank.in/about-us', '"71 branches spread across 15 districts of Maharashtra" (statistics panel shows 70)', 'official'),
('TOYOTA', 'HO', 'Corporate Office', 'admin', 1, null, 'Vehicle finance company; one office in the master.', 'Vehicle loans', 'No branch network in the master.', '1', null, 'Company website', 'Office named on the website list', 'internal'),
('TEZZ', 'UNKNOWN', 'Structure not researched', 'other', 1, null, 'Tezzract is not a bank in the master and no branch list exists; the owner should confirm what this client is.', null, null, null, null, null, 'No public structure found under this name', 'internal'),
('BRT', 'UNKNOWN', 'Structure not researched', 'other', 1, null, 'BRT is not a bank in the master and no branch list exists; the owner should confirm what this client is.', null, null, null, null, null, 'No public structure found under this name', 'internal');
insert into bi.client_unit_rule (client_family, priority, name_regex, branch_type, unit_code) values
('*', 50, '(CURRENCY|IMPS|NEFT|RTGS|CLEARING|MICR|TREASURY|SERVICE BRANCH|PENSION|FOREX|CARD|DIGITAL BANKING|CASH MANAGEMENT|\mCMS\M|ACCOUNTS SECTION|DEPARTMENT|SECTION|RECON|AUDIT|GOVERNMENT BUSINESS|TRADE FINANCE|\mATM\M)', null, 'NONLENDING'),
('*', 40, '(CO-?OP|COOPERATIVE|CO OP |SAHAKARI|URBAN BANK|GRAMIN|GRAMEENA|\mAPGB\M|\mMPGB\M|\mDCC\M|\mYDCC\M|CENTRAL BANK LTD|BANK LTD)', null, 'SUBMEMBER'),
('*', 30, '(ASSET REC|RECOVERY|STRESSED ASSET|\mARB\M|\mARM\M|\mSAMB?\M|\mSARB\M|SAMVERT)', null, 'RECOVERY'),
('*', 20, '(HEAD OFFICE|\mHO\M|CORPORATE CENTRE|CORPORATE OFFICE|REGISTERED OFFICE|CENTRAL OFFICE)', null, 'HO'),
('*', 19, '(ZONAL OFFICE|\mZO\M|\mZ\.O\M)', null, 'ZO'),
('*', 18, '(REGIONAL OFFICE|\mR ?O\M)', null, 'RO'),
('*', 10, '(\mM?SME\M|MSME)', 'branch', 'SME_BRANCH'),
('SBI', 120, 'MINI\s*-?\s*RAC\s*PA?C', null, 'MINI_RACPC'),
('SBI', 119, 'RAC\s*PA?C|RETAIL ASSETS? CENTRAL PROCESSING', null, 'RACPC'),
('SBI', 118, 'RASME\s*C|RASMEC|RA\s*SME\s*CC|RETAIL ASSETS? AND SMALL', null, 'RASMECCC'),
('SBI', 117, 'SMECC|\mSME\s+CCC?\M|SME CITY CREDIT', null, 'SMECCC'),
('SBI', 116, '\mSARC\M|STRESSED ASSETS? RESOLUTION', null, 'SARC'),
('SBI', 115, '\mRACC\M|RETAIL ASSETS? CREDIT CENTRE', null, 'RACC'),
('SBI', 114, 'AGRI PROCESSING|\mCAPC\M', null, 'CAPC'),
('SBI', 113, '\mLHO\M|LOCAL HEAD OFFICE', null, 'LHO'),
('SBI', 112, 'ADMINISTRATIVE OFFICE|ADMINISTRATION OFFICE|ZONAL OFFICE|\mAO\M', null, 'AO'),
('SBI', 111, '\mRBO\M|REGIONAL (BUSINESS )?OFFICE|\mREGION\M', null, 'RBO'),
('SBI', 110, 'CORPORATE CENTRE', null, 'CC'),
('SBI', 105, '(CPC|PROCESSING CENTRE|CURRENCY|ADMINISTRATION CELL|TREASURY)', null, 'NONLENDING'),
('SBI', 100, '(\mM?SME\M|MSME)', 'branch', 'SME_BRANCH'),
('BOM', 120, 'RETAIL ASSET', null, 'RAB'),
('BOM', 119, '\mCPC\M|CENTRALI[SZ]ED PROCESSING', null, 'CPC'),
('BOM', 118, 'HOUSING FINANCE BRANCH|\mHFB\M', null, 'HFB'),
('BOM', 117, 'MSME|\mSME\M', null, 'MSME'),
('BOM', 116, 'ASSET REC|RECOVERY|STRESSED', null, 'RECOVERY'),
('IDBI', 120, '\mRAC\M|RETAILS? ASSETS? CENT', null, 'RAC'),
('IDBI', 119, 'MSME|\mSME\M', 'branch', 'MSME_BRANCH'),
('IDBI', 118, '^(CORPORATE CENTRE|HEAD OFFICE SANTACRUZ)', null, 'HO'),
('IDBI', 110, '(CURRENCY|RTGS|IMPS|CASH PROCESSING|ACCOUNTING CELL|SERVICE BRANCH)', null, 'NONLENDING'),
('BOI', 121, '\mCMS\M', null, 'NONLENDING'),
('BOI', 120, 'RETAIL HUB|\mHUB\M', null, 'RETAIL_HUB'),
('BOI', 119, 'NATIONAL BANKING GROUP|\mNBG\M', null, 'NBG'),
('BOI', 118, '\mCPC\M|CENTRAL PROCESSING|CENTRALISED OPERATIONS', null, 'CPC'),
('BOI', 117, '\mMPGB\M', null, 'SUBMEMBER'),
('UNION', 121, 'MSME LOAN POINT|\mMLP\M', null, 'MLP'),
('UNION', 120, 'AGRICULTURE LOAN POINT', null, 'ALP'),
('UNION', 119, '\mULP\M|LOAN POINT|RETAIL LOAN (HUB|CENTRE|POINT)|RETAIL ASSET (HUB|BRANCH)|\mRAB\M|RETAIL HUB', null, 'ULP'),
('UNION', 118, '\mAPGB\M', null, 'SUBMEMBER'),
('CANB', 121, 'SULABH', null, 'MSME_SULABH'),
('CANB', 120, 'RETAIL ASSETS? H|ASSETS HUB', null, 'RAH'),
('CANB', 119, 'AGRICULTUR\w* CREDIT CENTRE', null, 'ACC'),
('CANB', 118, 'CIRCLE OFFICE', null, 'CIRCLE'),
('CANB', 117, '\mCPC\M|CENTRAL PROCESSING|CENTRALI[SZ]ED', null, 'CPC'),
('CANB', 116, '\mWING\M|,HO,|\mHO\M', null, 'HO'),
('PSB', 120, 'RETAIL (ASSET|LENDING)|CEN-?MARG', null, 'CENMARG'),
('PSB', 119, 'CENTRAL PROCESSING', null, 'NONLENDING'),
('KBL', 120, 'RETAIL ASSETS? CENT', null, 'RAC'),
('KBL', 119, 'HO COMPLEX|HEAD OFFICE', null, 'HO'),
('AXIS', 120, 'CENTRAL PROCESSING|\mHUB\M|RETAIL ASSET MANAGEMENT|CREDIT OPERATIONS', 'processing_centre', 'CPU'),
('LICHFL', 120, 'CORPORATE AND REGISTERED OFFICE', null, 'HO'),
('LICHFL', 119, 'REGIONAL OFFICE', null, 'RO'),
('LICHFL', 118, 'BACK OFFICE', null, 'BACK_OFFICE'),
('CANFH', 120, 'CENTRAL CREDIT|\mCCPC\M', null, 'CCPC'),
('DNSB', 120, '^CENTRAL OFFICE', null, 'HO'),
('SVC', 120, '^(SVC|SHAMRAO).*(HEAD OFFICE)', null, 'HO');
create or replace function bi.branch_unit_tag_refresh() returns jsonb language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '280s' as $f$
declare n int; t0 timestamptz := clock_timestamp();
begin
  delete from bi.branch_unit_tag;
  insert into bi.branch_unit_tag (branch_uid, client_family, unit_code)
  select b.branch_uid, b.client_family,
         coalesce((select r.unit_code from bi.client_unit_rule r
                    where r.client_family in (b.client_family, '*') and (r.branch_type is null or r.branch_type = coalesce(b.branch_type, 'branch'))
                      and upper(coalesce(b.branch_name, '')) ~ r.name_regex
                    order by (r.client_family = '*'), r.priority desc limit 1),
                  case coalesce(b.branch_type, 'branch') when 'office' then 'OTHER_OFFICE' when 'processing_centre' then 'OTHER_PC' else 'BRANCH' end)
    from bi.client_branch_master b
   where b.client_family in (select distinct client_family from bi.client_structure);
  get diagnostics n = row_count;
  delete from bi.api_cache where fn = 'client_structure';
  return jsonb_build_object('tagged', n, 'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
end $f$;
comment on function bi.branch_unit_tag_refresh() is 'wave 112c: re-tag client branch master units with their level / processing centre (nightly and after rule changes).';

create or replace function bi.api_client_structure(f jsonb, p jsonb) returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' set statement_timeout to '40s' as $f$
declare v_m date; v_locs int[]; v_fam text; res jsonb; v_filt boolean;
begin
  f := coalesce(f, '{}'::jsonb); p := coalesce(p, '{}'::jsonb);
  v_fam := nullif(coalesce(p->>'client_family', f->>'client_family'), '');
  v_filt := (f - 'client_family') <> '{}'::jsonb;
  v_locs := array(select l.id from bi.location l where bi.loc_ok(l.id, null, f));
  select x.month into v_m from bi.potential_run x order by x.run_id desc limit 1;
  with gen(code, name, kind, lvl) as (values ('HO', 'Head office', 'admin', 1), ('ZO', 'Zonal office', 'admin', 2), ('RO', 'Regional office', 'admin', 3),
         ('BRANCH', 'Branch', 'branch', 5), ('SME_BRANCH', 'SME branch', 'branch', 5), ('OTHER_PC', 'Other processing centres', 'processing', 7),
         ('RECOVERY', 'Recovery / stressed asset units', 'other', 8), ('OTHER_OFFICE', 'Other offices', 'other', 8),
         ('NONLENDING', 'Back-office units (no loan processing)', 'other', 9), ('SUBMEMBER', 'Other banks listed under this bank''s codes', 'other', 9)),
  fams as (select distinct s.client_family fam from bi.client_structure s where v_fam is null or s.client_family = v_fam),
  biz as (select c.family fam, sum(mb.cases) cases, round(sum(mb.revenue)) revenue from bi.v_month_business mb join bi.client c on c.code = mb.client_code
           where mb.month > (select max(month) from bi.v_month_business) - interval '3 months' group by 1),
  mst as materialized (
    select t.client_family fam, t.unit_code, b.code_norm, b.status
      from bi.branch_unit_tag t join bi.client_branch_master b on b.branch_uid = t.branch_uid
     where t.client_family in (select fam from fams)
       and (not v_filt or b.location_id = any (v_locs) or (b.location_id is null and f->>'zone_group' is not null and f->>'location_id' is null and b.zone_group = f->>'zone_group'))),
  uq as (select distinct on (m.fam, m.unit_code, m.code_norm) m.fam, m.unit_code, m.code_norm, a.last_m, coalesce(a.n3, 0) n3
           from mst m left join bi.branch_activity a on a.fam = m.fam and a.code_norm = m.code_norm
          where m.code_norm is not null and m.status = 'active'),
  cnt as (select m.fam, m.unit_code, count(*) in_master, count(*) filter (where m.status = 'active') open_units from mst m group by 1, 2),
  act as (select fam, unit_code, count(*) filter (where last_m >= (v_m - interval '2 months')::date) active,
                 count(*) filter (where last_m is not null and last_m < (v_m - interval '2 months')::date) dormant,
                 count(*) filter (where last_m is null) never_active, sum(n3) cases_3m
            from uq group by 1, 2),
  units as (
    select coalesce(s.client_family, c.fam) fam, coalesce(s.unit_code, c.unit_code) code,
           coalesce(s.unit_name, g.name, c.unit_code) name, coalesce(s.kind, g.kind, 'other') kind, coalesce(s.level_no, g.lvl, 9) lvl,
           s.parent_code, s.role, s.products, s.crux_work, s.published_count, s.as_of, s.source_url, s.source_note, s.confidence,
           coalesce(c.in_master, 0) in_master, coalesce(c.open_units, 0) open_units, coalesce(a.active, 0) active, coalesce(a.dormant, 0) dormant,
           coalesce(a.never_active, 0) never_active, coalesce(a.cases_3m, 0) cases_3m
      from (select * from bi.client_structure where client_family in (select fam from fams)) s
      full join cnt c on c.fam = s.client_family and c.unit_code = s.unit_code
      left join act a on a.fam = coalesce(s.client_family, c.fam) and a.unit_code = coalesce(s.unit_code, c.unit_code)
      left join gen g on g.code = coalesce(s.unit_code, c.unit_code))
  select jsonb_build_object('status_month', v_m, 'filters', f,
    'method', 'Levels and centres come from public sources (one link per row; confidence: official = the bank''s own site or report, press = news report, encyclopedia = Wikipedia, internal = read from unit names in the RBI IFSC list). Each unit in the client branch master is tagged by name rules; counts are open units in the master, active = a Crux case in the last 3 months (to the status month), cases_3m = Force1 cases from those units in the last 3 months.',
    'clients', (select coalesce(jsonb_agg(jsonb_build_object('client_family', fm.fam, 'cases_3m', bz.cases, 'revenue_3m', bz.revenue,
         'units', (select coalesce(jsonb_agg(jsonb_build_object('code', u.code, 'name', u.name, 'kind', u.kind, 'level', u.lvl, 'parent', u.parent_code, 'role', u.role,
                      'products', u.products, 'crux_work', u.crux_work, 'published_count', u.published_count, 'as_of', u.as_of, 'confidence', u.confidence,
                      'source_url', u.source_url, 'source_note', u.source_note, 'in_master', u.in_master, 'open_units', u.open_units, 'active', u.active,
                      'dormant', u.dormant, 'never_active', u.never_active, 'cases_3m', u.cases_3m)
                    order by u.lvl, case u.kind when 'admin' then 1 when 'branch' then 2 when 'processing' then 3 else 4 end, u.name), '[]')
                   from units u where u.fam = fm.fam))
       order by bz.cases desc nulls last, fm.fam), '[]') from fams fm left join biz bz on bz.fam = fm.fam)) into res;
  return res;
end $f$;
comment on function bi.api_client_structure(jsonb, jsonb) is 'wave 112c: how each client bank is organised (levels, processing centres, products, sources) with master counts, active units and Force1 cases per level.';

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '112c');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  $r$      when 'assoc' then bi.api_assoc(m, f)   -- wave 112: Business Associates vs Crux Branches$r$,
  $r$      when 'assoc' then bi.api_assoc(m, f)   -- wave 112: Business Associates vs Crux Branches
      when 'client_structure' then bi.api_client_structure(f, coalesce(p_args->'p', '{}'::jsonb))   -- wave 112c$r$], array[1]);
select bi.branch_unit_tag_refresh();
select cron.schedule('bi-unit-tag-refresh', '40 21 * * *', $c$select bi.branch_unit_tag_refresh()$c$);
-- follow-up applied the same day (execute_sql, 18-Nov-2026): fewer false "other bank" tags (a bank word must follow the co-op word),
-- SVC wording, and three SBI rules (ZO → AO, HEAD OFFICE → Corporate Centre, RO → RBO); then a re-tag.
update bi.client_unit_rule set name_regex = '((CO-?OP|COOPERATIVE|CO OP |SAHAKARI|URBAN|GRAMIN|GRAMEENA).*BANK|BANK LTD|BANK LIMITED|\mAPGB\M|\mMPGB\M|\mDCC\M|\mYDCC\M)' where client_family = '*' and unit_code = 'SUBMEMBER';
update bi.client_structure set unit_name = 'Units named after other co-operative banks', role = 'Units listed under SVC codes that carry another co-operative bank''s name: sub-members using SVC codes, or banks merged into SVC that kept their names (confirm with SVC).' where client_family = 'SVC' and unit_code = 'SUBMEMBER';
insert into bi.client_unit_rule (client_family, priority, name_regex, branch_type, unit_code) values
('SBI', 109, '\mZO\M|\mZ\.O\M', null, 'AO'), ('SBI', 108, 'HEAD OFFICE|\mHO\M', null, 'CC'), ('SBI', 107, '\mR ?O\M', null, 'RBO');
select bi.branch_unit_tag_refresh();
