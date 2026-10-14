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
