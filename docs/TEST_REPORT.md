# Acceptance test report — 12-Oct-2026

Automated: `select * from bi.run_acceptance_tests();` (re-run after every upload). Result: **18 / 18 passed** (T17 is a browser check, listed separately) (after fixing one defect in test T07's case selection).

| # | Test | Result | Evidence |
|---|---|---|---|
| T01 | Daily change = MTD difference | Pass | 9-Oct 17,441 − 8-Oct 14,952 = 2,489 (= source "Yesterday's MTD counts") |
| T02 | Duplicate upload | Pass | identical file hash → `duplicate:true`, nothing inserted |
| T03 | Corrected file | Pass | Nashik Jul v1 288 new; v2 71 new / 15 changed / 271 unchanged; 359 unique cases |
| T04 | New month | Pass | snapshots retained Jun (25), Jul (26), Aug (25), Sep (22), Oct (7) |
| T05 | Location aliases | Pass | GWALIOR/JWALIOR → one location; three Bengaluru labels → one |
| T06 | Summary-row protection | Pass | leaf sums = source control in 103/105 snapshots; 2 source rows corrupted (logged) |
| T07 | Case vs point | Pass | case 8269: 1 case row, 4 point rows |
| T08 | Force usage | Pass | Jul-26: 32,575 Force ÷ 51,162 tracker = 63.7%; view = API |
| T09 | Case TAT / negatives | Pass | 2,425 negative durations flagged, none carry an SLA value |
| T10 | Manual TAT | Pass | 50/50 rows labelled estimate with basis |
| T11 | Field executives | Pass | none has non-field points (148 field, 297 mixed, 5 back office, 116 unclassified) |
| T12 | Field/doc TAT scope | Pass | 0 non-field rows with field TAT, 0 non-doc rows with doc TAT |
| T13 | Processing route | Pass | routes only on field points |
| T14 | Cut-off | Pass | earliest month 2024-04 |
| T15 | Card ↔ table reconciliation | Pass | stakeholder filter: overview 6,299 = table 6,299 (= source E590) |
| T16 | Security (public read model) | Pass | anon has no `bi` schema usage; public read returns role=viewer; exceptions, admin, ingest and repo-stash refuse without a valid admin key |
| T19 | Force1 field vs back office | Pass | Jul-26 API = independent counts: 7,507 field-exec / 29,585 manual / 141 execs / 268 back office (20.2%) |
| T18 | AI/forecast accuracy | Pass | insight text contains computed run-rate 58,863 |

Browser tests (headless Chromium against the live database, 12-Oct-2026, public mode, no login)
| Check | Result |
|---|---|
| All 8 sections render with live data, 0 JavaScript errors | Pass |
| Stakeholder filter → overview MTD 6,299 (= tracker E590) | Pass |
| Wrong admin key rejected; correct key unlocks admin features | Pass |
| Upload a real Case Wise file → parsed (48 rows, PII stripped) → detected as identical → nothing changed | Pass |
| Anonymous role: read allowed; exceptions/mapping/ingest/admin/raw tables refused | Pass (found and fixed a NULL-logic hole in admin check, bi_020) |
| Anonymous 3 s timeout | Found failing → fixed with cache + 20 s anon timeout (bi_021) |

Manual / partially verified
| # | Test | Status |
|---|---|---|
| T17 | Live dashboard | Automated browser pass done (above). A human click-through on GitHub Pages is still recommended. |

Reconciliation to source (9-Oct-2026): MTD 17,441 ✓, target 84,395 ✓, revenue ₹6,518,972 ✓, daily change 2,489 ✓, Sep-26 month total 58,065 ✓.

## 14-Oct-2026 update
| Check | Result |
|---|---|
| 57 new Point Wise files: file rows − 1 blank row per file = DB rows (Aug 104,710; Sep 112,640; Oct 43,257) | Pass |
| `bi.run_acceptance_tests()` after load | 18/18 pass (T19 Jul field utilisation now 17.7%) |
| Headless browser (desktop + 390 px): Overview top opportunities, Tracker branch lifecycle, Ask Crux answer + details + feedback buttons, Upload matrix loads 392 rows × 4 dates (1,568 cells), no horizontal overflow | Pass; only console errors = favicon 404 and the pending `groups` admin action (400) |
| Ask Crux live: "Why is Pune lower than last month?" → "Not lower: up 47…" | Pass |
| Ask Crux month in question ("in September") | Pass after bi_037 (answers Sep 2026: 65.3% case-level, 19.8% field) |
| T20 WEF change across WEF date, history kept, overlap blocked | Pass (rolled back; no residue: 111 seed rows, 0 changes) |
| Matrix commit end-to-end in UI | Not run on live data (would create a real snapshot); DB path tested 12-Oct in a rolled-back block |

## 14-Oct-2026 — tracker replica, compare, WEF (after bi_036–bi_040)
| Check | Result |
|---|---|
| Regression: md5 of api_zonal/daily/monthly/overview/lfl/forecast/insights before vs after date-aware filters | Identical (7/7) |
| `bi.run_acceptance_tests()` | 21/21 pass (new T20 WEF, T21 tracker totals, T22 compare) |
| Tracker view vs Excel cached values, 9-Oct (rows 15, 28, 40, 158, 306, 331, 485, 528–535, 590): Target, MTD, Revenue Tgt, Revenue, % Achmt, Sep-26 history | All equal; Pan India 84,395 / 17,441 / 3,36,62,000 / 65,18,972 / 19%; daily 2,489 |
| Non-leaf totals that differ from source | Only client-wise SBI (source includes SBI Car Loan+) — flagged ⚠ |
| Filter Stakeholder = Shantanu Suravase → Pan India 6,299 (= tracker E590) | Pass |
| Browser: 587 rows render; levels Summary 60 / Zones 88 / Locations 195 rows; zone collapse; sort within blocks; search "pune"; compare same day last month (+1,412, +8.8%); Excel export downloads; full screen; 390 px no overflow | Pass; only console error = favicon 404 |
| Growth → Compare two periods (preset): totals, warning "9 vs 8 day", diverging bar chart, sortable table | Pass |
| Data quality → WEF preview (stakeholder change, WEF 1-Nov) validates; Save enabled; not applied | Pass |
| Collapsible section headings (fold/unfold, remembered) | Pass |

## 14-Oct-2026 — daily update table, business count, SBI Car Loan, expense removal (bi_041–bi_044)
| Check | Result |
|---|---|
| T23 enter → validate → commit → reopen → correct → archive (rolled back, no residue) | Pass (17,446 → 17,448; 1 changed value; 1 archived version) |
| Entry table: 392 rows, Oct dates 01–14 (7 committed, 5 open, Sundays hidden); committed daily counts reconcile to `v_zt_daily` by codes (1-Oct 2,071; 7-Oct 3,445) | Pass (found and fixed label-based matching that showed 1,807) |
| Daily/MTD toggle, typing updates Total till date and previews, zone filter | Pass (browser) |
| BUSINESS COUNT vs Training workbook (9-Oct): Odisha 11,750 / 0 / 4,500 / 6,250 / 12,000 / 11,750 / 9,750; daily totals 7,71,152 … 9,61,829; Total 65,18,972; Odisha target 2,58,750; per-day avg 8,000 | All equal |
| Client-wise SBI = 14,031 and SBI Car Loan+ = 0 (as the tracker) | Pass; tracker view now has 0 subtotal mismatches vs source |
| Expense columns absent from API and UI | Pass |
| `run_acceptance_tests()` | 22/22 pass |
| Storage after VACUUM FULL | 388 → 338 MB |

## 14-Oct-2026 (evening) — master data, coverage, attrition (bi_045–bi_050)
| Check | Result |
|---|---|
| T24 (rolled back, no residue): branch import 4 rows (leading-zero match, DD-Mon-YYYY and Excel-serial dates), re-import updates 1; coverage deltas +3 verified / +1 active / +1 never; dormant branch listed; workforce 4 rows → opening 2, joined 1, left 1, closing 2, attrition 50%; leaver workload = independent count (5,546.3 points/month) | Pass |
| Dry run row errors: unknown client, bad status, missing date, repeated key (both rows, with sheet row numbers), exit before joining, invalid classification | Pass (browser + SQL) |
| Public `bi_call('attrition')` hides leaver names; admin view unchanged; headcount identical | Pass |
| `bi_admin('master_import')` without key → "admin key required"; anon has no access to schema `bi` | Pass |
| Browser (admin): templates download with 4 / 3 sheets (42 clients, 37 locations); check file shows 7 rows → 2 valid / 5 problems and 5 rows → 1 valid / 4 problems; Import sends 7 rows + editor (server response mocked so no test rows enter the live master) | Pass |
| Browser (viewer, 390 px): master upload hidden behind admin gate; People and Business tracker show the "upload the list" banners; no horizontal overflow | Pass; only console error = favicon 404 |
| `run_acceptance_tests()` | 23/23 pass |

## 14-Oct-2026 (late evening) — rates, penalties, organic, potential, wording (bi_051–bi_064)
| Check | Result |
|---|---|
| T25 rate change (rolled back): Delhi + Rajasthan SBI Car Loan+ ₹240 → ₹250 from 8-Oct: revenue ₹3,67,440 → ₹3,72,230 (= 1,052×240 + 251×250 + 228×250), revenue target ₹12,39,480 (= 3,72,230 + 3,469×250); undo restores ₹3,67,440; rate typed in the daily table for 10-Oct recorded as a change from 10-Oct (+3 cases × ₹260) | Pass |
| T26 penalties (rolled back): reason required; ₹1,250.50 + ₹749.50 = ₹2,000; cancel → ₹1,250.50; public view hides reasons | Pass |
| T27 organic: stored Pan India Oct-26 56,697 = independent recomputation 56,703 (seasonal-index rounding) = API total; zone rows add up | Pass |
| T28 potential: Pan India likely 60,466 = Overview projection; range 58,390–62,198 = forecast range; needed per day formula | Pass |
| Browser (viewer, desktop): Target / Achieved / Projection / Organic tiles; "Data up to 09.10.2026"; organic ? popover shows each step; 7 automatic ? hints; zone highlights (4 above / 4 below); tracker organic columns with ? on Pan India; no source markers; potential tiles; penalties grid; Growth organic tiles + 14 zone rows; no banned wording on Overview / Tracker / Growth | Pass; no console errors |
| Browser (admin): rate change preview (no apply), penalty form shown; daily table on Sunday 11-Oct: type → save → validate (392/392, +5) → commit (mocked) → discard (no residue) | Pass (found and fixed: client list in the rate form, chosen date reset after "Fill blanks", save/commit messages not shown) |
| Browser (390 px) | No horizontal overflow; date chip visible |
| Public key vs retired invoice app after lock-down: reads empty, inserts/uploads refused, reset function disabled; dashboard unaffected | Pass |
| `run_acceptance_tests()` | 27/27 pass |
