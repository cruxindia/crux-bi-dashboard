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
| Compare (Growth) | A − B and (A − B) ÷ B for cases and revenue; snapshot = MTD on/before date; month = month-end history | any grouping | warns when not like-for-like |
