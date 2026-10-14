# Statement of Work (living) — last updated 14-Oct-2026

**Objective.** Replace spreadsheet MIS with one reliable BI system linking Zonal Tracker (authoritative), Case Wise and Point Wise, from 1-Apr-2024, with drill-down, Force usage, TAT, forecasting and data-grounded insights.

**Scope.** In: the three source categories in the Drive folder; Supabase database; dashboard; upload centre; tests; docs. Out: other tracker sheets (`10 Days Analysis`, `Haque`, `June 2026 Target Sheet`, `Old Tracker till Feb 2026`) by instruction; the "BOM Testing Files" folder and the 83 MB zip (not one of the three categories).

**Inputs (as loaded).** 105 tracker snapshots (1-Jun → 9-Oct-2026; monthly history Apr-24 → Sep-26), 136 Case Wise files (Jan → Oct-2026, 17 location groups), 96 Point Wise files (Jan → Jul-2026) + 57 Point Wise files added 14-Oct (Jul replacements, Aug, Sep, Oct-2026; Kolhapur-Vinayak July only).

**Status (14-Oct-2026).** Point Wise now Jan → Oct-2026 (Aug 104,710 · Sep 112,640 · Oct 43,257 points; Jul 107,100 after replacement files); 18/18 tests pass. **DB 388 MB of 500 MB — storage decision needed (L8).** Front end: daily matrix entry (Upload centre), branch lifecycle (Business tracker + Overview), like-for-like (Growth), Ask Crux floating panel, WEF group editor (Data quality). **14-Oct (afternoon):** `bi_036`–`bi_040` applied (WEF mapping, date-aware tracker reports, LFL, Ask Crux month parsing, Zonal Tracker replica API, period comparison API, tests T20–T22). 21/21 tests pass. Business tracker rebuilt as a row-for-row replica of the Main Tracker sheet; expense columns hidden by default and labelled "as entered".

**Status (12-Oct-2026, evening).** Public dashboard live on GitHub Pages; DB 195 MB after compaction; 17/17 tests pass; no newer source files in Drive (Point Wise ends Jul-2026).

**Earlier status.** Database built and loaded (213,472 cases; 470,552 points; 58,905 tracker rows; 8,082 monthly history rows). 17/17 automated acceptance tests pass (`select * from bi.run_acceptance_tests()`). Dashboard live (Claude artifact). Repo created.

## Decision log
| # | Decision | Rationale / evidence |
|---|---|---|
| D1 | Leaf rows are the only aggregation unit; totals/roll-ups stored as labelled raw rows | Leaf sums match source control in 103/105 snapshots; remaining 2 have corrupted source total rows |
| D2 | Month headers decoded as month=month, year=2000+day | Excel converted "Sep-24" to 24-Sep-2023; verified against row-3 text (1 header typo logged) |
| D3 | Historical "Target MTD" columns = achieved count | revenue column = count × rate in those blocks |
| D4 | Column O split: leaf = case delta, totals = revenue delta; database recomputes deltas from consecutive snapshots | Formula inspection |
| D5 | Case/Point timestamps are UTC; bucket in IST | Received-hour distribution peaks 05–12 UTC |
| D6 | PII (name, mobile, PAN, Aadhaar, account no., address) dropped at extraction; address → has_address | Not needed for any KPI; reduces breach exposure |
| D7 | Force usage at client-family grain per location group | Case Wise cannot split BOM MSME PRE/POST or SBI Car Loan+ |
| D8 | Locations without Case Wise files show "not received", not 0% | Avoids inventing manual volume |
| D9 | Delhi∩Lucknow duplicate cases → one record, more advanced status kept, UP branches to Lucknow group | 984 cases appeared in both extracts |
| D10 | Udyam classified Document (needs review) despite brief listing it as field | PIN 0%, assigned 3% |
| D11 | Field executive = verifies only field types (≥ min points); route "outside Force" only with evidence | Brief rule; tested a timestamp-precision signal and rejected it (field execs had more whole-minute stamps) |
| D12 | Only leaf rows may create/resolve locations | Total labels had created 8 junk locations (fixed in bi_010) |
| D13 | Role check via auth.users.email_confirmed_at, not JWT claims | Fixed a privilege-escalation path (bi_009) |
| D14 | Code-only export channel for GitHub | Make proxy is the only GitHub route; avoids moving code through manual API calls |

| D15 | Udyam = Document (confirmed) | Business decision 12-Oct |
| D16 | PUNJAB+Rajisthan (1-Oct) = Punjab row; Rajasthan moved to Delhi+Rajasthan from 3-Oct | Business decision 12-Oct |
| D17 | Field route: only-field submitters = field executive (Force); anyone who creates cases/points or verifies non-field points = back office, their field submissions manual | Business rule 12-Oct; result Jan–Jul: 14.8% field exec, 82.6% manual, 2.6% not verified |
| D18 | Expense block: L = projected monthly expense; M = revenue − expense; N = revenue − 2 × expense (labelled YTD in source). Rows overlap; all-India expense taken from the tracker total row | Formula inspection; derived sum ≠ source total because zone/location rows overlap |
| D19 | Storage compaction: text → integer dictionary codes, 64-bit hashes, unused fields dropped | Lossless check: 0 mismatches on all retained fields; 401 MB → 195 MB |
| D20 | Public, login-free dashboard; admin key for writes; API result cache keyed by data version; anon timeout 20 s | Business decision; browser test found anon 3 s timeout |

| D21 | Force1 utilisation reported at two levels (cases; field points) with formulas on screen; field vs back office comparison | Business request 12-Oct; rule D17 confirmed by Ops |
| D22 | Derived per-point facts materialised in `bi.point_derived`, rebuilt by pg_cron every 10 min when data changed (also re-runs classification) | api_force1 27.5 s → 2.6 s; anon limit 20 s |
| D23 | Navigation as hamburger drawer (all screen sizes) | Business request 12-Oct |
| D24 | Daily matrix replaces routine full-tracker upload; rows from latest snapshot; Mon–Sat expected; validate → acknowledge warnings → commit; full tracker upload kept | Master upgrade brief |
| D25 | Branch lifecycle from Force1 Case Wise only, last 3 vs prior 3 covered months; opportunity = peer median (≥5 peers) − branch average; labelled estimate | No verified client branch master supplied |
| D26 | Like-for-like = latest snapshot vs previous month's snapshot on/before the same day; growth "unattributed" (no organic rule approved) | Brief: never invent attribution |
| D27 | Group changes are effective-dated rows (never overwritten); tracker reports use the mapping in force on each snapshot/month; Force1/TAT/People use today's mapping | Brief §11; tracker is the authoritative grouping |
| D28 | Ask Crux: SQL-computed answer first; optional Gemini rewording server-side only, rejected if it adds numbers | Brief; secrets server-side |
| D29 | New Point Wise drop loaded by upsert on point_id; 884 July points present only in older files retained (not deleted) | Additive-only rule; no delete without evidence |

| D30 | Business tracker = replica of the Main Tracker sheet (same rows, order, columns, colours); every subtotal recomputed from leaf rows; source total shown as ⚠ where it differs | User request 14-Oct (minimise change management); source has broken SUM ranges (e.g. client-wise E/F/G only summed rows 4–27) |
| D31 | Expense columns L/M/N never used in KPIs; shown only in the tracker view, off by default, labelled "as entered — not verified" | Values not credible (Ahmedabad 225, Vadodara 412.5, Bengaluru 254% of revenue); user asked how they were derived |
| D32 | Daily column = case change at every level (source shows revenue change on total rows); revenue change available as an optional column | Consistency |
| D33 | Period comparison (snapshot or month, any two) with explicit like-for-like warnings | User request: comparative analysis |
| D34 | Migrations avoid top-level DROP/REVOKE/UPDATE/DELETE (the Supabase connector cancels them); use guarded DO blocks | Six cancelled attempts on 14-Oct |

| D35 | Daily update table replaces the routine tracker upload: rows in tracker order, one column per report date, entry as daily counts (like the "Test Details" sheet) or cumulative MTD (toggle); stored as cumulative MTD; Total till date, block/zone/Pan India previews | Business decision 14-Oct ("Both, with a toggle") |
| D36 | Committed dates can be corrected: reopen with reason → edit → validate → commit; previous leaf values archived in `bi.zt_snapshot_archive` | Brief §6 (admin-assisted corrections, previous/new value logged) |
| D37 | "BUSINESS COUNT" sheet reproduced (date × location daily revenue or cases, Total, Projected Target, Shortfall, Per Day Average); Penalty sheet not reproduced (penalty = ₹ amount, report only — available on request) | Business decision 14-Oct |
| D38 | SBI Car Loan+ reported under SBI (client), product = Car Loan; client-wise block now equals the tracker (SBI 14,031) | Business decision 14-Oct |
| D39 | Tracker expense columns L/M/N ignored everywhere (not displayed, not used) | Business: "that data and calculation is incorrect" |
| D40 | Entry-table values matched across snapshots by location/client codes (labels change, e.g. Rajasthan move on 3-Oct) | Found 27 relabelled rows on 3-Oct during testing |
| D41 | Drafts and corrections never deleted: `committed_batch` / `active` flags instead (also required because the connector cancels DELETE) | Audit trail + tooling constraint |

## Open questions (need business confirmation)
2. Confirm the D18 reading of tracker columns M and N.

3. ~~Expense column L~~ — resolved 14-Oct: ignore (data incorrect).
4. ~~SBI Car Loan+~~ — resolved 14-Oct: count in SBI, product Car Loan.
5. 2-Oct-2026 has no tracker snapshot (holiday?) — mark it "no report" in the daily update table or enter it.
