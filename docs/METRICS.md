# Metric dictionary (all computed in SQL: `bi.v_*`, `bi.api_*`)

| Metric | Formula | Grain / period | Notes |
|---|---|---|---|
| MTD cases | Σ leaf `E` for the snapshot | location × client × snapshot | Authoritative business count |
| Target | Σ leaf `D` | current month | Historical targets not available in source |
| Achievement | MTD ÷ Target | | |
| Daily change | MTD(snapshot) − MTD(previous available snapshot, same month) | location × client | `change_basis`: one_working_day / multi_day_gap / from_month_start; negatives kept & flagged |
| Revenue | Σ leaf `G` (= MTD × rate) | | Billing (actual invoiced) shown separately from tracker history |
| Monthly actuals | tracker history columns, newest snapshot wins | month ≥ Apr-2024 | |
| Force cases | count of Case Wise cases received in month (IST) | location group × client family × month | |
| Force usage % | Force cases ÷ tracker cases (same group, family, month) | only where Case Wise data exists | |
| Estimated manual | tracker − Force when ≥ 0 | | Negative → "Force above tracker" reconciliation exception |
| Case TAT | Completed − Received (hours) | completed cases with non-negative duration | median, mean, P90; low-sample flag n < 30 |
| SLA met % | Completed ≤ Estimated TAT (due) | | Source-defined SLA |
| Estimated manual-case TAT | observed Force TAT: same group & client (n ≥ 30) → same client elsewhere → overall | | Always labelled estimate + basis |
| Field TAT | Field Reviewed − Assigned | field point types only | invalid dates (outside plausible range / negative) excluded and counted |
| Document TAT | Completed − Created | document point types only | |
| Case-level Force1 utilisation | Force1 cases received in month ÷ Zonal Tracker cases (same location group, client family, month) | only groups with Case Wise data | Jul-26: 32,575 ÷ 51,162 = 63.7% |
| Field-level Force1 utilisation | field points submitted by field executives ÷ (field-executive + back-office submissions) | month × location group | unverified points excluded and shown separately; Jul-26 (full data, 14-Oct): 8,573 ÷ 48,358 = 17.7%; Aug 18.7%, Sep 19.8%, Oct 19.8% |
| Field executive | verifies only field points, never creates cases/points, never handles document/tele points | per person | business rule confirmed 12-Oct-2026 |
| Back office | creates cases/points or handles any document/tele point; their field submissions are manual | per person | |
| Points per person | submissions ÷ distinct active people in the month | per group | |
| Processing route (field) | verifier = assignee → in Force (inferred); verifier is back-office/mixed ≠ assignee → likely outside Force; no assignee → unknown | | Inferred; no explicit source flag |
| Forecast (run-rate) | MTD ÷ Mon–Sat working days elapsed × working days in month | | |
| Forecast (curve) | MTD ÷ average share of month-end reached by same working day in prior months with daily snapshots (range = min/max share) | needs ≥ 2 months | Not a guarantee |
| Like-for-like change | MTD (latest snapshot of month) − MTD (previous month's latest snapshot on/before same day) | location / client / stakeholder / zone | cumulative values, never summed |
| Branch status | insufficient_data (<6 covered months or <3 cases); new; dormant; reactivated; growing (L3 ≥ 1.2×P3 and +3); losing traction (L3 ≤ 0.7×P3 and −3); else stable | branch (Force1) | covered months only |
| Branch opportunity (estimate) | peer median monthly cases (same client + location group, ≥5 active peers) − branch L3 average | branch | not confirmed leakage |
| Matrix daily change | entered MTD total − previous snapshot MTD total (same month) | date | warnings: MTD decreased, large jump |
| Tracker view subtotals | sum of leaf rows in the block (location block = rows between totals; zone = same zone label; zone client row = same zone + client name; Zone A/B = location tier; N/S/E/W = region; ROI = all except Mumbai; client-wise = client name; stakeholder = location owner on the snapshot date) | snapshot | mirrors the Excel SUM/SUMIF intent |
| % Achmt (tracker view) | Actual revenue ÷ revenue target (Excel H = G/F), 0% when no target | row | |
| ACHIEVED bar | █ × round(achievement × 20), capped at 150% | row | same as Excel REPT |
| Daily count (tracker view) | MTD − previous snapshot's MTD in the same month; first snapshot of the month = MTD | row | |
| Branch coverage | verified active branches with ≥ 1 Force1 case in the last 6 months ÷ verified active branches | client (filters: location/zone/stakeholder via branch location; client family) | needs the uploaded client branch list; codes matched ignoring leading zeros; closed/ineligible excluded |
| Never-activated branch | verified active branch with no Force1 case since 1-Apr-2024 | branch | |
| Gone-quiet verified branch | verified active branch whose last Force1 case is older than 6 months | branch | |
| Opening / closing headcount | joined before month start and not exited before it / joined by month end and not exited by month end | month (workforce list) | needs the uploaded workforce list |
| Attrition (month) | leavers in month ÷ ((opening + closing) ÷ 2) | month; by role; by location | not annualised |
| Leaver workload | Point Wise points verified per month in the 3 months before the exit month | person | observed workload to reassign, not lost business; points after the exit month are flagged |
| Revenue (with rate changes) | Σ over report days (cases added that day × rate in force that day) | location × client | equals MTD × rate when the rate never changed |
| Revenue target (with rate changes) | if MTD < target: revenue so far + (target − MTD) × current rate; else target × revenue ÷ MTD | location × client | equals target × rate when the rate never changed |
| Organic expectation (month) | (0.7·d₁ + 0.2·d₂ + 0.1·d₃) × SI(month) × working days; dₖ = cases k months back ÷ its working days ÷ SI(that month) | location × client, summed for any group | SI = Pan India seasonal index: month's cases per working day ÷ centred 12-month average, averaged over the previous two years |
| Organic to date | organic month × share of a month normally done by this working day (average over past months with daily reports) | | same share as the Overview projection |
| Effort | actual − organic (to date, or projected month end − organic month) | any group | > +5% "Effort growth", < −5% "Below organic" |
| Back-test (organic choice) | Dec-2025 → Sep-2026, predicting each month from earlier months only: chosen method Pan India mean error 6.7%, location × client WAPE 21.5%, bias −5.6%; last month only 11.3% / 20.9%; seasonal 3-month average 9.1% / 24.4%; YoY momentum 15.8% / 45.5%; **previous rule (higher of last-year growth × 3-month avg and 3-month growth × last month) 25.5% / 38.3%, bias +25.2%** | | trend-extrapolating variants were unstable (Jan errors > 50%) |
| Month-end potential (likely) | so far × 1 ÷ average share done by this working day (own history if ≥ 2 months and enough volume, else Pan India) | location / zone / client / stakeholder | low/high = strongest/weakest past month; Pan India = Overview projection |
| Needed per day | (target − so far) ÷ working days left (Mon–Sat minus declared holidays) | | status: On track (likely ≥ target), Stretch (needed ≤ 1.25 × recent pace), At risk |
| Penalty | Σ active penalties (₹) by date × location | | report only |
| Compare (Growth) | A − B and (A − B) ÷ B for cases and revenue; snapshot = MTD on/before date; month = month-end history | any grouping | warns when not like-for-like |

## Branch master, coverage and research (addendum, 14-Oct-2026)
| Metric | Definition |
|---|---|
| Verified active branches | Active branches (offices excluded) in `bi.client_branch_master` with verification `source_verified` (RBI IFSC directory or official locator) or a client-list upload |
| Matchable by code | Verified active branches whose client list carries branch codes (banks); website-listed lenders are excluded |
| Active with Crux (6 m) | Matchable branch with ≥1 Force1 case in the last 6 calendar months, matched by client family + branch code ignoring leading zeros (`bi.branch_activity`) |
| Coverage | Active with Crux ÷ matchable by code |
| Never activated | Matchable branch with no Force1 case since Jan-2026 (start of Force1 history) |
| Gone quiet | Branch with Force1 history but no case in the last 6 months |
| Indicative activation ceiling | Σ over never-activated branches of the median monthly cases (last 3 months) of active branches of the same client in the same Crux location, where ≥5 such branches exist. Upper bound, not a forecast |
| Research combinations | Client families in scope × live Crux locations (business in the last 100 days) |
| Research status per combination | verified (≥1 source-verified branch in territory) · researched, none in territory · not applicable (no branch network) · partial source · territory not established · not researched |
| Researched % | (verified + researched-none + not applicable) ÷ combinations |
| Monitor overdue | No succeeded `branch_monitor` run in 35 days |

## Drill-down (15-Oct-2026)
| Metric | Definition |
|---|---|
| Selected value | Month-to-date cases for the drawer's filters from the latest tracker snapshot of the month (= Overview / tracker) |
| Parent total and share | Same figure with the most specific filter removed (client → location → zone → region → stakeholder → Pan India); share = selected ÷ parent |
| Breakdown check | Σ child month-to-date = selected value (shown with ✓; T39) |
| Likely month end | Overview projection for the selection (`api_potential`); range = weakest–strongest past month |
| Organic in the drawer | Organic for the month, organic expected to date, actual − organic to date (= Overview tile and zone highlights) |
| vs same point last month | Like-for-like: last month's report on or before the same day (`api_lfl`) |
| Branch rows | Force1 cases by client branch code for the month and the last 3 months; Force1 counts differ from tracker counts |
| Branch peer median | Median monthly cases (last 3 months) of active branches of the same client in the same location, shown when ≥ 5 peers |

## Drawer operations, branch status and compare (15-Oct-2026)
| Metric | Definition |
|---|---|
| Case TAT / SLA met | Median and P90 hours from case received to completed (Force1 Case Wise, cases received in the month); SLA met = share completed by the due time. ⚠ when < 30 completed |
| Document / field / tele TAT | Point Wise: document completed − created; field reviewed − assigned; tele completed − created (points created in the month) |
| Force1 utilisation | Cases: Force1 cases ÷ tracker cases for location groups with Case Wise data (per location group; a single location shows it only if it is its group's only location). Field visits: by field executives ÷ (field executives + back office) |
| Verified / active (6 m) / coverage | Source-verified active client branches in the territory; active = Force1 case in last 6 months; coverage = active ÷ code-matchable |
| Never activated / gone quiet (6 m) | No Force1 case since Jan-2026 / had cases but none in the last 6 months |
| Lifecycle (new, reactivated, growing, stable, losing traction, dormant) | Branch priority rules on complete covered months: last 3 vs prior 3 months of the branch's location group; dormant = no case in the last 2 covered months |
| Status (RAG) | On track = likely month end ≥ target; Stretch = required daily pace within 25% of the recent pace; At risk = more than that |
| Compare Δ | Value minus the first column (percentage points for percentages, hours for TAT) |
