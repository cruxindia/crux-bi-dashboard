-- Applied to Supabase project via MCP on 20261012051223

alter table bi.location add column is_unit_default boolean not null default false;
alter table bi.zt_row add column region_label text;

insert into bi.zone_group(code,label) values
 ('ODISHA','Bhuvaneshvar ODISHA Zone'),('BHOPAL_MP','Bhopal MP Zone'),('BENGALURU','Bengaluru (Rest Of Karnataka) Zone'),
 ('TAMILNADU','Tamilnadu Zone'),('DELHI','Delhi + Rajasthan'),('PUNJAB','Punjab'),('GUJARAT','Gujarat Zone'),('GUWAHATI','Guwahati Assam Zone'),
 ('HYDERABAD','Hyderabad Zone'),('KOLKATA','Kolkata Zone'),('LUCKNOW','Lucknow / ROUP Zone'),('MUMBAI_GOA','Mumbai + Goa Zone'),
 ('REST_MAHA','Rest Of Maharashtra Zone'),('PATNA','Patna Zone');

-- canonical locations (label = latest label in tracker); tier from tracker "Zone A" formula; stakeholder from tracker stakeholder formulas (9-Oct-2026)
insert into bi.location(code,label,zone_group,tier,stakeholder,recon_unit,is_unit_default) values
 ('ODISHA','Bhuvaneshvar ODISHA Zone','ODISHA','Zone B','Shiladitya Pradhan','Odisha',true),
 ('INDORE','Indore','BHOPAL_MP','Zone B','Manish Shukla','Bhopal',false),
 ('BHOPAL','Bhopal','BHOPAL_MP','Zone B','Manish Shukla','Bhopal',false),
 ('BILASPUR','Bilaspur','BHOPAL_MP','Zone B','Nitish Bhope','Bhopal',false),
 ('RAIPUR','Raipur','BHOPAL_MP','Zone B','Nitish Bhope','Bhopal',false),
 ('GWALIOR','GWALIOR','BHOPAL_MP','Zone B','Manish Shukla','Bhopal',false),
 ('RAMAVTAR','Ramavtar','BHOPAL_MP','Zone B',null,'Bhopal',false),
 ('BENGALURU','Bengaluru + Rest Of Karnataka + Kerela','BENGALURU','Zone A','ShivaKumar','Bangalore',true),
 ('TAMILNADU','Tamilnadu + Chennai','TAMILNADU','Zone B','ShivaKumar','Bangalore',false),
 ('DELHI','Delhi+Rajisthan','DELHI','Zone A','Manish Shukla','Delhi',true),
 ('PUNJAB','PUNJAB','PUNJAB','Zone B','Manish Shukla','Delhi',false),
 ('AHMEDABAD','AHMEDABAD','GUJARAT','Zone A','Shantanu Suravase','Gujarat',false),
 ('VADODARA','VADODARA','GUJARAT','Zone A','Shantanu Suravase','Gujarat',false),
 ('GANDHINAGAR','GANDHINAGAR','GUJARAT','Zone A','Shantanu Suravase','Gujarat',false),
 ('BHAVNAGAR','BHAVNAGAR','GUJARAT','Zone A','Shantanu Suravase','Gujarat',false),
 ('RAJKOT','RAJKOT','GUJARAT','Zone A','Shantanu Suravase','Gujarat',false),
 ('SURAT','Surat','GUJARAT','Zone A','Shantanu Suravase','Gujarat',false),
 ('GUWAHATI','Guwahati Assam Zone','GUWAHATI','Zone B','Shiladitya Pradhan','Guwahati',true),
 ('HYDERABAD','Hyderabad Zone','HYDERABAD','Zone A','ShivaKumar','Hyderabad',true),
 ('KOLKATA','Kolkata Zone','KOLKATA','Zone A','Shiladitya Pradhan','Kolkata',true),
 ('LUCKNOW_BRANCH','Lucknow/ROUP - Branch','LUCKNOW','Zone B','Manish Shukla','Lucknow',false),
 ('LUCKNOW_MUKESH','Lucknow/ROUP - (Mukesh Yadav)','LUCKNOW','Zone B','Manish Shukla','Lucknow',false),
 ('MUMBAI','Mumbai','MUMBAI_GOA','Zone A','Shantanu Suravase','Mumbai',true),
 ('GOA','GOA','MUMBAI_GOA','Zone B','Nitish Bhope','Mumbai',false),
 ('AMARAVATI','Amaravati','REST_MAHA','Zone B','Nitish Bhope',null,false),
 ('AURANGABAD','Chhatrapati Sambhajinagar (AURANGABAD)','REST_MAHA','Zone B','Nitish Bhope','Marathwada',false),
 ('JALGAON','JALGAON','REST_MAHA','Zone B','Nitish Bhope',null,false),
 ('KOLHAPUR','KOLHAPUR','REST_MAHA','Zone B','Nitish Bhope','Kolhapur-Vinayak',true),
 ('LATUR','Latur (MM)','REST_MAHA','Zone B','Nitish Bhope','Marathwada',false),
 ('NAGPUR_YASH','NAGPUR (YASH)','REST_MAHA','Zone B','Nitish Bhope','Nagpur-Yash',true),
 ('NAGPUR_SUDHIR','NAGPUR (Sudhir)','REST_MAHA','Zone B','Nitish Bhope','Nagpur-Sudhir',true),
 ('NASHIK','NASHIK','REST_MAHA','Zone B','Nitish Bhope','Nashik',true),
 ('NANDED','Nanded','REST_MAHA','Zone B','Nitish Bhope','Marathwada',false),
 ('PUNE','Pune','REST_MAHA','Zone A','Shantanu Suravase','Pune',true),
 ('SOLAPUR','Solapur','REST_MAHA','Zone B','Nitish Bhope',null,false),
 ('BIHAR_PATNA','BIHAR/PATNA','PATNA','Zone B','Manish Shukla',null,false),
 ('JHARKHAND','JHARKHAND (Firoz+ Crux)','PATNA','Zone B','Manish Shukla','Jharkhand',true);

-- every tracker label observed Jun-Oct 2026, with how it was matched
insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
select 'zonal_label', bi.norm(a.alias), l.id, a.method, a.conf, jsonb_build_object('first_seen',a.seen,'note',a.note), a.rs
from (values
 ('Bhuvaneshvar ODISHA Zone','ODISHA','exact',1.0,'2026-06-01',null,'confirmed'),
 ('Indore','INDORE','exact',1,'2026-06-01',null,'confirmed'),('Bhopal','BHOPAL','exact',1,'2026-06-01',null,'confirmed'),
 ('Bilaspur','BILASPUR','exact',1,'2026-06-01',null,'confirmed'),('Raipur','RAIPUR','exact',1,'2026-06-01',null,'confirmed'),
 ('GWALIOR','GWALIOR','exact',1,'2026-06-05',null,'confirmed'),('JWALIOR','GWALIOR','g_j_typo_normalisation',0.95,'2026-07-06','find/replace G->J corruption in 6-Jul file','auto'),
 ('Ramavtar','RAMAVTAR','exact',1,'2026-06-01','present in 4 June snapshots only','needs_review'),
 ('Bengaluru + Rest Of Karnataka + Kerela','BENGALURU','exact',1,'2026-08-01',null,'confirmed'),
 ('Bengaluru (Rest Of Karnataka)','BENGALURU','rename_continuity',0.9,'2026-06-01','renamed 1-Aug; same zone, same row position and client list','auto'),
 ('BenJaluru (Rest Of Karnataka)','BENGALURU','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('Tamilnadu + Chennai','TAMILNADU','exact',1,'2026-08-01',null,'confirmed'),
 ('Tamilnadu','TAMILNADU','rename_continuity',0.9,'2026-06-01','renamed 1-Aug','auto'),
 ('Delhi+Rajisthan','DELHI','exact',1,'2026-10-03',null,'confirmed'),
 ('Delhi','DELHI','rename_continuity',0.9,'2026-06-01','renamed 3-Oct when Rajasthan moved to this row','auto'),
 ('PUNJAB','PUNJAB','exact',1,'2026-06-01',null,'confirmed'),
 ('PUNJAB+Rajisthan','PUNJAB','rename_continuity',0.7,'2026-10-01','label on 1-Oct only; Rajasthan scope moved to Delhi row on 3-Oct','needs_review'),
 ('AHMEDABAD','AHMEDABAD','exact',1,'2026-06-01',null,'confirmed'),('VADODARA','VADODARA','exact',1,'2026-06-01',null,'confirmed'),
 ('GANDHINAGAR','GANDHINAGAR','exact',1,'2026-06-01',null,'confirmed'),('JANDHINAJAR','GANDHINAGAR','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('BHAVNAGAR','BHAVNAGAR','exact',1,'2026-06-01',null,'confirmed'),('BHAVNAJAR','BHAVNAGAR','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('RAJKOT','RAJKOT','exact',1,'2026-06-01',null,'confirmed'),('Surat','SURAT','exact',1,'2026-06-01',null,'confirmed'),
 ('Guwahati Assam Zone','GUWAHATI','exact',1,'2026-06-01',null,'confirmed'),('Juwahati Assam Zone','GUWAHATI','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('Hyderabad Zone','HYDERABAD','exact',1,'2026-06-01',null,'confirmed'),('Kolkata Zone','KOLKATA','exact',1,'2026-06-01',null,'confirmed'),
 ('Lucknow/ROUP - Branch','LUCKNOW_BRANCH','exact',1,'2026-10-07',null,'confirmed'),
 ('Lucknow/ROUP - (Ajay Pathak)','LUCKNOW_BRANCH','rename_continuity',0.85,'2026-06-01','renamed 7-Oct; same row position and client list','needs_review'),
 ('Lucknow/ROUP - (Mukesh Yadav)','LUCKNOW_MUKESH','exact',1,'2026-06-01',null,'confirmed'),
 ('Mumbai','MUMBAI','exact',1,'2026-06-01',null,'confirmed'),('GOA','GOA','exact',1,'2026-06-01',null,'confirmed'),
 ('JOA','GOA','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('Amaravati','AMARAVATI','exact',1,'2026-06-01',null,'confirmed'),
 ('Chhatrapati Sambhajinagar (AURANGABAD)','AURANGABAD','exact',1,'2026-06-01',null,'confirmed'),
 ('Chhatrapati SambhajinaJar (AURANGABAD)','AURANGABAD','g_j_typo_normalisation',0.95,'2026-07-07','residual G->J corruption persisted after 6-Jul','auto'),
 ('Chhatrapati SambhajinaJar (AURANJABAD)','AURANGABAD','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('JALGAON','JALGAON','exact',1,'2026-06-01',null,'confirmed'),('KOLHAPUR','KOLHAPUR','exact',1,'2026-06-01',null,'confirmed'),
 ('Latur (MM)','LATUR','exact',1,'2026-06-01',null,'confirmed'),
 ('NAGPUR (YASH)','NAGPUR_YASH','exact',1,'2026-06-01',null,'confirmed'),('NAJPUR (YASH)','NAGPUR_YASH','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('NAGPUR (Sudhir)','NAGPUR_SUDHIR','exact',1,'2026-06-01',null,'confirmed'),('NAJPUR (Sudhir)','NAGPUR_SUDHIR','g_j_typo_normalisation',0.95,'2026-07-06','G->J corruption','auto'),
 ('NASHIK','NASHIK','exact',1,'2026-06-01',null,'confirmed'),('Nanded','NANDED','exact',1,'2026-06-01',null,'confirmed'),
 ('Pune','PUNE','exact',1,'2026-06-01',null,'confirmed'),('Solapur','SOLAPUR','exact',1,'2026-06-01',null,'confirmed'),
 ('BIHAR/PATNA','BIHAR_PATNA','exact',1,'2026-06-01',null,'confirmed'),('JHARKHAND (Firoz+ Crux)','JHARKHAND','exact',1,'2026-06-01',null,'confirmed')
) a(alias,code,method,conf,seen,note,rs) join bi.location l on l.code=a.code;

-- Case/Point file groups = reconciliation units (file name is a clue, refined per case below)
insert into bi.location_alias(source,alias,recon_unit,method,confidence,evidence,review_status)
select 'case_file', bi.norm(g), g, 'file_name_group', 1, jsonb_build_object('note',n), rs from (values
 ('Delhi','Delhi file also carries UP (Faizabad/Ayodhya/Prayagraj) and Punjab branches','auto'),('Nashik',null,'auto'),('Nagpur-Sudhir',null,'auto'),
 ('Nagpur-Yash',null,'auto'),('Kolkata','only Apr-2026 file exists','auto'),('Odisha',null,'auto'),('Pune',null,'auto'),('Jharkhand',null,'auto'),
 ('Gujarat','split to 6 locations by Area Office','auto'),('Hyderabad',null,'auto'),('Bangalore','Chennai/Coimbatore branches -> Tamilnadu','auto'),
 ('Kolhapur-Vinayak','franchise file; tracker row KOLHAPUR','needs_review'),('Lucknow','two tracker rows; not separable from case data','auto'),
 ('Marathwada','Aurangabad/Latur/Nanded by branch token; Parbhani/Beed unresolved','needs_review'),('Guwahati',null,'auto'),
 ('Bhopal','Indore/Bhopal/Gwalior by Area Office/branch token','auto'),('Mumbai','file also contains Aurangabad/Latur/Indore/Ernakulam/Punjab branches','needs_review')
) x(g,n,rs);

-- within-unit refinement rules
insert into bi.location_alias(source,alias,location_id,recon_unit,method,confidence,evidence,review_status)
select src, bi.norm(a), l.id, u, m, c, jsonb_build_object('basis',e), 'auto' from (values
 ('area_office','RAJKOT AO','RAJKOT','Gujarat','area_office_exact',0.98,'Area Office column'),('area_office','VADODARA AO','VADODARA','Gujarat','area_office_exact',0.98,'Area Office column'),
 ('area_office','SURAT AO','SURAT','Gujarat','area_office_exact',0.98,'Area Office column'),('area_office','SURAT ZONE','SURAT','Gujarat','area_office_exact',0.95,'Area Office column'),
 ('area_office','BHAVNAGAR AO','BHAVNAGAR','Gujarat','area_office_exact',0.98,'Area Office column'),('area_office','AHMEDABAD AO','AHMEDABAD','Gujarat','area_office_exact',0.98,'Area Office column'),
 ('area_office','AHMEDABAD ZONE','AHMEDABAD','Gujarat','area_office_exact',0.95,'Area Office column'),('area_office','GANDHINAGAR AO','GANDHINAGAR','Gujarat','area_office_exact',0.98,'Area Office column'),
 ('area_office','BHOPAL ZONE','BHOPAL','Bhopal','area_office_exact',0.95,'Area Office column'),('area_office','INDORE ZONE','INDORE','Bhopal','area_office_exact',0.95,'Area Office column'),
 ('area_office','CHENNAI ZONE','TAMILNADU','Bangalore','area_office_exact',0.95,'Area Office column'),('area_office','CHANDIGARH ZONE','PUNJAB','Delhi','area_office_exact',0.9,'Area Office column'),
 ('branch_token','INDORE','INDORE','Bhopal','branch_name_token',0.9,'city in branch name'),('branch_token','GWALIOR','GWALIOR','Bhopal','branch_name_token',0.9,'city in branch name'),
 ('branch_token','BHOPAL','BHOPAL','Bhopal','branch_name_token',0.9,'city in branch name'),('branch_token','RAIPUR','RAIPUR','Bhopal','branch_name_token',0.9,'city in branch name'),
 ('branch_token','BILASPUR','BILASPUR','Bhopal','branch_name_token',0.85,'city in branch name'),
 ('branch_token','CHENNAI','TAMILNADU','Bangalore','branch_name_token',0.9,'city in branch name'),('branch_token','COIMBATORE','TAMILNADU','Bangalore','branch_name_token',0.9,'city in branch name'),
 ('branch_token','LUDHIANA','PUNJAB','Delhi','branch_name_token',0.9,'city in branch name'),('branch_token','AMRITSAR','PUNJAB','Delhi','branch_name_token',0.9,'city in branch name'),
 ('branch_token','GOA','GOA','Mumbai','branch_name_token',0.9,'state in branch name'),('branch_token','PANAJI','GOA','Mumbai','branch_name_token',0.9,'city in branch name'),
 ('branch_token','MARGAO','GOA','Mumbai','branch_name_token',0.9,'city in branch name'),('branch_token','MAPUSA','GOA','Mumbai','branch_name_token',0.9,'city in branch name'),
 ('branch_token','VASCO','GOA','Mumbai','branch_name_token',0.9,'city in branch name'),('branch_token','PONDA','GOA','Mumbai','branch_name_token',0.85,'city in branch name'),
 ('branch_token','LATUR','LATUR','Marathwada','branch_name_token',0.9,'city in branch name'),('branch_token','NANDED','NANDED','Marathwada','branch_name_token',0.9,'city in branch name'),
 ('branch_token','AURANGABAD','AURANGABAD','Marathwada','branch_name_token',0.9,'city in branch name'),('branch_token','SAMBHAJI','AURANGABAD','Marathwada','branch_name_token',0.9,'city in branch name')
) x(src,a,code,u,m,c,e) join bi.location l on l.code=x.code;

insert into bi.group_precedence values ('Delhi','Lucknow','Lucknow','UP branches (Faizabad/Ayodhya/Prayagraj) appear in both extracts; UP belongs to Lucknow/ROUP');

-- clients: tracker client codes; family = level at which Case Wise can be compared
insert into bi.client(code,label,family) values
 ('SBI','SBI','SBI'),('SBI_CAR','SBI Car Loan+','SBI'),('BOM','BOM','BOM'),('BOM_MSME_PRE','BOM MSME PRE','BOM'),('BOM_MSME_POST','BOM MSME POST','BOM'),
 ('BOM_RETAIL_POST','BOM Retail POST','BOM'),('BOM_INOP','BOM INOP','BOM'),('BOM_TSR','BOM TSR','BOM'),('IDBI','IDBI Bank','IDBI'),('LICHFL','LIC HFL','LICHFL'),
 ('SVC','SVC','SVC'),('AXIS','AXIS BANK','AXIS'),('AXISF','Axis Finance','AXISF'),('CANB','CANARA','CANB'),('CANFH','CAN FIN HOMES','CANFH'),
 ('TEZZ','Tezzract','TEZZ'),('BOI','BOI','BOI'),('DNSB','DNSB','DNSB'),('KBL','KARNATAKA BANK','KBL'),('UNION','UNION','UNION'),
 ('BOB','BOB','BOB'),('BOB_FSL','BOB FSL','BOB'),('BOB_HL','BOB HL','BOB'),('BOB_CAR','BOB Car Loan +','BOB'),('BOB_ITR','BOB ITR','BOB'),
 ('PSB','PUNJAB & SIND BANK','PSB'),('TOYOTA','TOYOTA','TOYOTA'),('NIDO','NIDO','NIDO'),('BRT','BRT','BRT'),('GIC_HFL','GIC HFL','GIC_HFL'),
 ('POOL_PURCHASE','POOL PURCHASE','POOL_PURCHASE'),('CRED','CRED','CRED'),('RBL','RBL','RBL'),('ICICI','ICICI','ICICI'),('BCCB','BCCB','BCCB'),
 ('COSMOS','COSMOS','COSMOS'),('IDEA','Idea','IDEA'),('LEGAL_TSR','Legal T&SR','LEGAL_TSR'),('OTHERS','Others','OTHERS'),('PNB_HFL','PNB HFL','PNB_HFL'),
 ('TATA_CAP','Tata Capital','TATA_CAP'),('TJSB','TJSB','TJSB');
insert into bi.client_alias(source,alias,client_code,method,confidence,review_status)
select s, bi.norm(a), c, m, cf, rs from (values
 ('zonal','SBI','SBI','exact',1,'confirmed'),('zonal','SBI HL','SBI','history_label',0.95,'auto'),('zonal','SBI Car Loan+','SBI_CAR','exact',1,'confirmed'),
 ('zonal','BOM','BOM','exact',1,'confirmed'),('zonal','BOM MSME PRE','BOM_MSME_PRE','exact',1,'confirmed'),('zonal','BOM MSME POST','BOM_MSME_POST','exact',1,'confirmed'),
 ('zonal','BOM Retail POST','BOM_RETAIL_POST','exact',1,'confirmed'),('zonal','BOM INOP','BOM_INOP','exact',1,'confirmed'),('zonal','BOM TSR','BOM_TSR','exact',1,'confirmed'),
 ('zonal','IDBI Bank','IDBI','exact',1,'confirmed'),('zonal','LIC HFL','LICHFL','exact',1,'confirmed'),('zonal','SVC','SVC','exact',1,'confirmed'),
 ('zonal','AXIS BANK','AXIS','exact',1,'confirmed'),('zonal','Axis Finace','AXISF','exact_misspelt',1,'confirmed'),('zonal','CANARA','CANB','exact',1,'confirmed'),
 ('zonal','CAN FIN HOMES','CANFH','exact',1,'confirmed'),('zonal','Tezzract','TEZZ','exact',1,'confirmed'),('zonal','BOI','BOI','exact',1,'confirmed'),
 ('zonal','DNSB','DNSB','exact',1,'confirmed'),('zonal','KARNATAKA BANK','KBL','exact',1,'confirmed'),('zonal','UNION','UNION','exact',1,'confirmed'),
 ('zonal','BOB','BOB','exact',1,'confirmed'),('zonal','BOB FSL','BOB_FSL','exact',1,'confirmed'),('zonal','BOB HL','BOB_HL','exact',1,'confirmed'),
 ('zonal','BOB Car Loan +','BOB_CAR','exact',1,'confirmed'),('zonal','BOB ITR','BOB_ITR','exact',1,'confirmed'),('zonal','PUNJAB & SIND BANK','PSB','exact',1,'confirmed'),
 ('zonal','TOYOTA','TOYOTA','exact',1,'confirmed'),('zonal','NIDO','NIDO','exact',1,'confirmed'),('zonal','BRT','BRT','exact',1,'confirmed'),
 ('zonal','GIC HFL','GIC_HFL','exact',1,'confirmed'),('zonal','JIC HFL','GIC_HFL','g_j_typo_normalisation',0.95,'auto'),
 ('zonal','POOL PURCHASE','POOL_PURCHASE','exact',1,'confirmed'),('zonal','CRED','CRED','exact',1,'confirmed'),('zonal','RBL','RBL','exact',1,'confirmed'),
 ('zonal','ICICI','ICICI','exact',1,'confirmed'),('zonal','BCCB','BCCB','exact',1,'confirmed'),('zonal','COSMOS','COSMOS','exact',1,'confirmed'),
 ('zonal','Idea','IDEA','exact',1,'confirmed'),('zonal','Legal T&SR','LEGAL_TSR','exact',1,'confirmed'),('zonal','Others','OTHERS','exact',1,'confirmed'),
 ('zonal','PNB HFL','PNB_HFL','exact',1,'confirmed'),('zonal','Tata Capital','TATA_CAP','exact',1,'confirmed'),('zonal','TJSB','TJSB','exact',1,'confirmed'),
 ('case','STATE BANK OF INDIA','SBI','name_to_code',1,'confirmed'),('case','BANK OF MAHARASHTRA','BOM','name_to_code',1,'confirmed'),
 ('case','IDBI BANK','IDBI','name_to_code',1,'confirmed'),('case','LIC HOUSING FINANCE','LICHFL','name_to_code',1,'confirmed'),
 ('case','SVC COOPERATIVE BANK LTD','SVC','name_to_code',1,'confirmed'),('case','AXIS BANK','AXIS','name_to_code',1,'confirmed'),
 ('case','CANARA BANK','CANB','name_to_code',1,'confirmed'),('case','BANK OF INDIA','BOI','name_to_code',1,'confirmed'),('case','AXIS FINANCE','AXISF','name_to_code',1,'confirmed'),
 ('case','CAN FIN HOMES','CANFH','name_to_code',1,'confirmed'),('case','TEZZRACT FINTECH PVT LTD','TEZZ','name_to_code',1,'confirmed'),
 ('case','DNS BANK LTD','DNSB','name_to_code',1,'confirmed'),('case','KARNATAKA BANK','KBL','name_to_code',1,'confirmed')
) x(s,a,c,m,cf,rs);

-- point-type dictionary with the evidence measured on 472,590 points (Jan-Jul 2026)
insert into bi.point_type(name,category,rule,evidence,review_status) select n,c,r,jsonb_build_object('pin_present',p,'assigned',a,'points',k),rs from (values
 ('Residence Verification','field','PIN>=95% & assigned',1.00,0.89,126140,'auto'),('Employment Verification','field','PIN>=95% & assigned',1.00,0.88,63681,'auto'),
 ('Surya Ghar Verification','field','PIN>=95% & assigned',1.00,0.82,17213,'auto'),('Business Verification','field','PIN>=95% & assigned',1.00,0.72,7277,'auto'),
 ('Property Verification','field','PIN>=95% & assigned',1.00,0.88,2182,'auto'),('Quotation verification','field','PIN>=95% & assigned',1.00,0.63,1854,'auto'),
 ('Dealer verification','field','PIN>=95% & assigned',1.00,0.87,1771,'auto'),('Permanent Residence Verification','field','PIN>=95% & assigned',1.00,0.72,765,'auto'),
 ('Seller Verification','field','PIN>=95% & assigned',1.00,0.79,242,'auto'),('Current Account Verification','field','PIN>=95% & assigned',1.00,0.61,195,'auto'),
 ('College Verification','field','PIN>=95% & assigned',1.00,0.66,147,'auto'),('Builder Verification','field','PIN>=95% & assigned',1.00,0.92,114,'auto'),
 ('Residence Tele Verification Report','tele','assigned, no address/PIN',0.00,0.99,58148,'auto'),('Business Tele Verification Report','tele','assigned, no address/PIN',0.00,0.98,22978,'auto'),
 ('Office Tele Verification Report','tele','assigned, no address/PIN',0.00,1.00,6255,'auto'),
 ('IT Returns Verification','document','assigned<=34%',0.00,0.07,48104,'auto'),('Identity verification AADHAR','document','assigned<=34%',0.13,0.11,27564,'auto'),
 ('Form 16','document','assigned<=34%',0.02,0.02,26476,'auto'),('Identity verification PAN','document','assigned<=34%',0.04,0.03,25593,'auto'),
 ('Bank Statement Verification','document','assigned<=34%',0.02,0.02,16696,'auto'),('Payslip Verification','document','assigned<=34%',0.07,0.05,16289,'auto'),
 ('Udyam Registration Certificate','document','CONFLICT: brief lists as field; data PIN 0%, assigned 3%',0.00,0.03,1189,'needs_review'),
 ('GSTN Certificate','document','assigned<=34%',0.00,0.01,879,'auto'),('Form 26','document','assigned<=34%',0.00,0.00,322,'auto'),
 ('Electricity Bill Verification','document','assigned<=34%',0.36,0.24,147,'auto'),('Shop Act License Verification','document','assigned<=34%',0.51,0.34,134,'auto'),
 ('Employee ID Verification','document','assigned<=34%',0.35,0.27,112,'auto'),('8A Extract Verification','document','land record document',0.60,0.33,15,'needs_review'),
 ('7/12 Extract Verification','document','land record document',0.58,0.33,12,'needs_review')
) x(n,c,r,p,a,k,rs);

-- authoritative case location assignment (runs after every case commit)
create or replace function bi.relocate_cases(p_batch bigint) returns int language plpgsql security definer set search_path = bi, public as $$
declare n int;
begin
  update bi.fact_case c set recon_unit = u.recon_unit,
    location_id = coalesce(
      (select la.location_id from bi.location_alias la where la.source='area_office' and la.recon_unit=u.recon_unit and la.alias=bi.norm(c.area_office) and la.review_status<>'rejected'),
      (select la.location_id from bi.location_alias la where la.source='branch_token' and la.recon_unit=u.recon_unit and la.review_status<>'rejected'
         and bi.norm(c.branch) ~ ('(^|[^A-Z])'||la.alias||'([^A-Z]|$)') order by length(la.alias) desc limit 1),
      (select l.id from bi.location l where l.recon_unit=u.recon_unit and l.is_unit_default))
  from bi.location_alias u where u.source='case_file' and u.alias=bi.norm(c.file_group) and c.last_batch=p_batch;
  get diagnostics n = row_count;
  -- branches whose name points to another unit's city: flag, do not move
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
  select p_batch,'case',c.branch,'branch_outside_file_unit','info',jsonb_build_object('file_unit',c.recon_unit,'token',la.alias,'token_unit',la.recon_unit,'cases',count(*))
  from bi.fact_case c join bi.location_alias la on la.source='branch_token' and la.recon_unit<>c.recon_unit
   and bi.norm(c.branch) ~ ('(^|[^A-Z])'||la.alias||'([^A-Z]|$)')
  where c.last_batch=p_batch group by c.branch,c.recon_unit,la.alias,la.recon_unit;
  return n;
end $$;
create or replace function bi.trg_batch_committed() returns trigger language plpgsql security definer set search_path = bi, public as $$
begin
  if new.status='committed' and old.status='staged' and new.source_category='case' then perform bi.relocate_cases(new.id); end if;
  return new;
end $$;
create trigger batch_committed after update of status on bi.import_batch for each row execute function bi.trg_batch_committed();

