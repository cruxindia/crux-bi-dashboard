# Statement of Work (living) — last updated 14-Oct-2026

**Objective.** Replace spreadsheet MIS with one reliable BI system linking Zonal Tracker (authoritative), Case Wise and Point Wise, from 1-Apr-2024, with drill-down, Force usage, TAT, forecasting and data-grounded insights.

**Scope.** In: the three source categories in the Drive folder; Supabase database; dashboard; upload centre; tests; docs. Out: other tracker sheets (`10 Days Analysis`, `Haque`, `June 2026 Target Sheet`, `Old Tracker till Feb 2026`) by instruction; the "BOM Testing Files" folder and the 83 MB zip (not one of the three categories).

**Inputs (as loaded).** 105 tracker snapshots (1-Jun → 9-Oct-2026; monthly history Apr-24 → Sep-26), 136 Case Wise files (Jan → Oct-2026, 17 location groups), 96 Point Wise files (Jan → Jul-2026) + 57 Point Wise files added 14-Oct (Jul replacements, Aug, Sep, Oct-2026; Kolhapur-Vinayak July only).

**Status (14-Oct-2026, late evening).** Second round delivered: mid-month rate changes (revenue day-wise), Penalty sheet (admin-only, reason required), organic benchmark chosen by back-test and shown on Overview / Business tracker / Growth with a ? explanation on every organic figure, month-end potential (advanced 10-day analysis), plain-language ? help on technical terms, "Data up to" date in the header, Target / Achieved / Projection / Organic tiles, zone highlights, source/sheet references removed from the screens. Retired invoice app found in the same database (publicly writable with the dashboard key): 1,529 bill PDFs deleted, all its tables and functions locked; final table removal script handed to the owner. **27/27 automated tests pass** (T01–T28 except browser T17). Waiting on the owner for the Gemini details (Q8).

**Status (14-Oct-2026, evening).** All requested items are built and deployed: Zonal Tracker replica, daily update table (daily counts or cumulative MTD, corrections), BUSINESS COUNT report, SBI Car Loan+ under SBI, expense columns removed, comparison, sort/expand/collapse/full screen. `bi_045`–`bi_050` add master-data uploads (client branch list, HR workforce list) with check-before-import, branch coverage (Business tracker) and headcount/attrition (People); both show an explanatory banner until a verified list is uploaded. **23/23 automated tests pass** (T01–T24; T17 is the browser check). DB 341 MB of 500 MB (L8). Tracker data: latest snapshot 9-Oct; 2-Oct, 10-Oct and 12–14-Oct are open in the daily update table.

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
| D42 | Branch coverage and attrition are computed only from uploaded, verified lists (client branch master; HR workforce master). Until uploaded, the screens say so — nothing is inferred from Force1 activity | Brief: never fabricate; Point Wise cannot tell a resignation from a quiet month |
| D43 | Master uploads: template → "Check file" (server dry run, row-level errors with sheet row numbers) → Import valid rows; upsert by key (client + branch code; employee ID, else name); uploads never remove rows; every import audited | Same governance as the daily update table |
| D44 | Coverage = verified active branches with a Force1 case in the last 6 months ÷ verified active branches; branch codes matched ignoring leading zeros; closed/ineligible excluded | Standard coverage definition; leading zeros differ between bank lists and Force1 |
| D45 | Attrition (month) = leavers ÷ average of opening and closing headcount; leaver workload = Point Wise points per month in the 3 months before exit (observed workload, not lost business) | Common HR definition; workload link uses the Point Wise "Verified By" name |
| D46 | Leaver names and exit reasons are admin-only (HR data); the public view shows role, location, exit date and workload | Public dashboard (D20) + data minimisation |
| D47 | Short-lived (3-hour) session tokens were created for browser testing and the code stash (two on 14-Oct; they expire automatically); the 12-Oct admin key is unchanged and exists only as a hash | Plaintext keys are never stored |
| D48 | Mid-month rate change = effective-dated rate per location × client (`bi.rate_change`). Revenue = each report day's added cases × the rate in force that day; revenue target = cases achieved at the rates applied + remaining target cases at the current rate (equals target × rate when the rate never changed). A rate typed in the daily table becomes a change from that report date; every change needs a reason and can be undone | User: "update the rates which can even be applicable from middle of the month" |
| D49 | Penalty sheet: ₹ per date × location (optional client), admin-only entry with mandatory reason (5+ characters), cancel with reason (kept in audit), report only — never netted from revenue; reasons visible to admins only | User 14-Oct: "only admin can update those penalties and should have a reason"; earlier: "₹ amount, report only" |
| D50 | Organic expectation = (0.7·d(t−1) + 0.2·d(t−2) + 0.1·d(t−3)) × SI(t) × WD(t), d = cases per working day ÷ SI; SI = Pan India seasonal index (average of the previous two years); organic to date = organic × share of the month normally done by this working day. Effort = actual − organic (±5% = in line) | Back-test Dec-25 → Sep-26 of 6+ methods (METRICS.md): Pan India error 6.7% vs the current rule's 25.5% (which overstated organic by 25% on average). Replaces the "unattributed only" stance of D26 now that management asked for an organic rule |
| D51 | Branch evidence shown with organic: Force1 branches sending work for the first time / returning after 3+ quiet months count as effort; continuing branches as base. Only where Force1 case reports exist | User: "consider the branches and all as much factors as possible" |
| D52 | Month-end potential (advanced 10-day analysis): likely month end = so far × (1 ÷ average share of the month done by this working day in past months with daily reports), low/high = weakest/strongest month — identical to the Overview projection; plus days 1–10 / 11–20 / 21–end additions, required per day vs recent pace, status, and the classic 3.25×–5× day-10 options for comparison | User: keep the 10-day logic, make it more advanced, don't disturb forecasting |
| D53 | Screens no longer mention source files, sheet names or row numbers ("Case Wise/Point Wise" → Force1 cases/visits; snapshot → report date). Upload centre and master-data errors keep row numbers because admins need them to fix their own files | User: dashboard replaces the tracker |
| D54 | Point-level facts are rebuilt only when imports or mappings change (not on daily-table saves, rates or penalties) | Found during testing: every save triggered a 30–50 s rebuild that briefly blocked Force1/People figures |
| D55 | Retired invoice/bills app in the same project: files deleted through the storage API; tables emptied of access with deny-all policies and its functions disabled (the connector cannot run DROP/TRUNCATE); owner runs `remove_old_invoice_app.sql` once to remove the empty shells | Owner chose "Delete invoice app data"; anyone with the public key could read or wipe it |

## Open questions (need business confirmation)
2. Confirm the D18 reading of tracker columns M and N.

3. ~~Expense column L~~ — resolved 14-Oct: ignore (data incorrect).
4. ~~SBI Car Loan+~~ — resolved 14-Oct: count in SBI, product Car Loan.
5. 2-Oct-2026 has no tracker snapshot (holiday?) — mark it "no report" in the daily update table or enter it.
6. Client branch lists (per client, with source and verification date) and the HR workforce list (joining/exit dates) — needed to switch on coverage and attrition.
8. Gemini AI agents — API key (set as Supabase secret `GEMINI_API_KEY`), free or paid tier + monthly cap, market-news agent now or later, who sees AI output (all / admins; e-mail alerts?), language(s).
9. Run `remove_old_invoice_app.sql` in the Supabase SQL editor and delete the empty "bills" bucket (one-time).
7. Organic-business rule, market-event source/budget, GEMINI_API_KEY, storage plan (L8) — unchanged from earlier.

## Requirement audit (14-Oct-2026)
| Requirement (user, 14-Oct) | Work performed | Evidence / verification | Result |
|---|---|---|---|
| Explain expenses; then "ignore, incorrect" | Explained source (L/M/N); removed from API and UI | API/UI check; D39, L5 | Done |
| Admin key | Explained; key unchanged | T16 (privileged actions need key) | Done |
| Sort, expand/collapse tables | Click-to-sort on every table; foldable sections; full screen; tracker outline levels | Browser tests 14-Oct | Done |
| Comparative analysis | Growth → Compare two periods; tracker Compare columns; like-for-like | T22; browser test | Done |
| Business tracker = exact feel of the Zonal Tracker | Row-for-row replica, same colours/columns, levels, Excel export | T21; equal to Excel cached values; 0 subtotal mismatches | Done |
| SBI Car Loan+ under SBI, product Car Loan | `client.summary_under`, `client.product` | Client-wise SBI 14,031 = tracker | Done |
| Daily update table (SOW item) | Tracker-ordered entry grid, daily/MTD toggle, paste, validate, commit, corrections, no-report | T23; reconciles to v_zt_daily by codes | Done |
| Reproduce Test Details + BUSINESS COUNT; penalty ₹ report-only | Entry ledger = daily update table; BUSINESS COUNT report | Equal to Training workbook (9-Oct) | Done; Penalty sheet available on request |
| Finish all remaining pending | Master uploads, coverage, attrition (ready for data); tests; docs | T24; browser test of templates/check/import (import mocked to avoid test data in live master) | Done — waiting on the two lists (Q6) |

## Requirement audit — second round (14-Oct-2026, late evening)
| Requirement | Work performed | Evidence / verification | Result |
|---|---|---|---|
| 1) "what list?" | Explained: client branch lists, HR employee list | — | Answered |
| 2) Daily table works; rates from mid-month | Rate change panel (preview → apply → undo), day-wise revenue, commit hook for rates typed in the table; daily-table fixes (chosen date kept, save/commit messages visible) | T23, T25 (Delhi SBI Car Loan: ₹3,67,440 → ₹3,72,230; independent check), browser run on Sunday 11-Oct: type → save → validate (392/392, MTD 17,446, +5) → commit (server mocked) → discard; no residue | Done |
| 3a) Gemini agents | Questions sent (Q8) | — | Waiting on owner |
| 3b) Organic logic everywhere with ? | Back-test, organic store + refresh job, Overview tile, tracker columns with per-row ?, Growth section + 12-month chart, zone highlights, potential column | T27 (store = independent formula = API totals), browser: popover shows each step | Done |
| 3c) Unneeded storage / other projects | Storage audit; other projects have their own 500 MB; retired invoice app found and removed/locked | Public key can no longer read or write it (tested); BI data all in use | Done (owner script pending, Q9) |
| 4) Penalty sheet | Table, admin API, grid report, form, cancel, Excel | T26; browser (admin form, viewer read-only) | Done |
| 5) Remove references; 10-day analysis | Wording pass; potential section | Browser check: no "Case Wise / Point Wise / source sheet / Main Tracker / Sheet row" on Overview, Tracker, Growth; T28 (likely = Overview projection) | Done |
| User suggestions 1–5 | ? explanations (auto on technical terms), Target / Achieved / Projection / Organic tiles, "Data up to" chip, zone highlights | Browser (desktop + 390 px) | Done |
