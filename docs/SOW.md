# Statement of Work (living) — last updated 12-Oct-2026

**Objective.** Replace spreadsheet MIS with one reliable BI system linking Zonal Tracker (authoritative), Case Wise and Point Wise, from 1-Apr-2024, with drill-down, Force usage, TAT, forecasting and data-grounded insights.

**Scope.** In: the three source categories in the Drive folder; Supabase database; dashboard; upload centre; tests; docs. Out: other tracker sheets (`10 Days Analysis`, `Haque`, `June 2026 Target Sheet`, `Old Tracker till Feb 2026`) by instruction; the "BOM Testing Files" folder and the 83 MB zip (not one of the three categories).

**Inputs (as loaded).** 105 tracker snapshots (1-Jun → 9-Oct-2026; monthly history Apr-24 → Sep-26), 136 Case Wise files (Jan → Oct-2026, 17 location groups), 96 Point Wise files (Jan → Jul-2026).

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

## Open questions (need business confirmation)
2. Confirm the D18 reading of tracker columns M and N.
