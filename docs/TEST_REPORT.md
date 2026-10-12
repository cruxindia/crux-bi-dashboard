# Acceptance test report — 12-Oct-2026

Automated: `select * from bi.run_acceptance_tests();` (re-run after every upload). Result: **17 / 17 passed** (after fixing one defect in test T07's case selection).

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
