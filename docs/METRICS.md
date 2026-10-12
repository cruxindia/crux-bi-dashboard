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
| Processing route (field) | verifier = assignee → in Force (inferred); verifier is back-office/mixed ≠ assignee → likely outside Force; no assignee → unknown | | Inferred; no explicit source flag |
| Forecast (run-rate) | MTD ÷ Mon–Sat working days elapsed × working days in month | | |
| Forecast (curve) | MTD ÷ average share of month-end reached by same working day in prior months with daily snapshots (range = min/max share) | needs ≥ 2 months | Not a guarantee |
