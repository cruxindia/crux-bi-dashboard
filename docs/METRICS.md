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
| Organic expectation (month) — from 22-Oct-2026 (bi_093a) | **0.5 × MoM basis + 0.4 × QoQ basis + 0.1 × YoY basis**; where the location × client has no usable month last year: (0.5 × MoM + 0.4 × QoQ) ÷ 0.9. MoM basis = v₁ ÷ wd₁ ÷ SI₁ × SI(month) × wd(month). QoQ basis = (v₁+v₂+v₃) ÷ (wd₁·SI₁ + wd₂·SI₂ + wd₃·SI₃) × SI(month) × wd(month) × QoQ trend, where QoQ trend = (last quarter ÷ the quarter before, both per seasonal working day, limited to 0.5–2×)^(1/3), used only when the quarter before had ≥ 30 cases (else 1). YoY basis = (v₁+v₂+v₃) ÷ (wd₁+wd₂+wd₃) × wd(month) × own shape, own shape = (cases per working day in the same month last year) ÷ (cases per working day in the 5 months centred on it), limited to 0.67–1.5×; usable only when that month had ≥ 30 cases, the 5-month window ≥ 100 cases and lies after Apr-2024. vₖ, wdₖ, SIₖ = cases, Monday–Saturday working days and seasonal index k months back | location × client, summed for any group | SI = Pan India seasonal index: month's cases per working day ÷ centred 12-month average, averaged over the previous two years. MoM, QoQ and YoY here are the *inputs* of the expectation (the same three views used for the seasonal index), not the period comparisons below |
| Organic to date | organic month × share of a month normally done by this working day (average over past months with daily reports) | | same share as the Overview projection |
| Effort | actual − organic (to date, or projected month end − organic month) | any group | > +5% "Effort growth", < −5% "Below organic" |
| Back-test (organic blend, 22-Oct-2026) | Dec-2025 → Sep-2026, each month predicted from earlier months only. **Chosen 50/40/10 MoM/QoQ/YoY blend: Pan India mean error 5.8%, location × client WAPE 21.3%, bias −4.3%; 76% of business has a usable month last year.** Alternatives: YoY 20% → 5.8% / 21.5%; YoY 30% → 6.1% / 21.9%; previous 70/20/10 three-month method 6.7% / 21.5%. Largest single-month miss: Aug-2026, actual 13.4% above organic (so Aug effort looks high and Sep MoM growth beyond organic looks low). | | reproduced from the stored figures (`bi.organic_store`) and checked by `bi.test_organic()` (three largest pairs recomputed one by one) |
| Back-test (first organic choice, 15-Oct-2026) | Dec-2025 → Sep-2026, predicting each month from earlier months only: 70/20/10 three-month method Pan India mean error 6.7%, location × client WAPE 21.5%, bias −5.6%; last month only 11.3% / 20.9%; seasonal 3-month average 9.1% / 24.4%; YoY momentum 15.8% / 45.5%; **previous rule (higher of last-year growth × 3-month avg and 3-month growth × last month) 25.5% / 38.3%, bias +25.2%** | | trend-extrapolating variants were unstable (Jan errors > 50%) |
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

## Revenue & collections (21-Oct-2026)
| Measure | Definition |
|---|---|
| Outstanding | Sum of "Actual Outstanding" on every invoice line of the latest outstanding workbook (gross of GST, after TDS and part-receipts), as at its snapshot date. Snapshots are never added together |
| Unadjusted receipts | Receipts listed at the foot of each location sheet that are not yet matched to invoices |
| Net receivable | Outstanding − unadjusted receipts (not shown under a client filter: unadjusted receipts are recorded per location) |
| Age / ageing bucket | Days from the last day of the invoice month (month in the invoice number) to the snapshot date; 0–30, 31–60, 61–90, 91–180, over 180 (setting `ageing_buckets`). "Overdue" only when `credit_days` is set |
| Collected | Bank-account credits in the receipt month (incl. GST, after TDS); "Main" sheet excluded (cross-check only) |
| Cash cover (3 months) | Collected ÷ reported revenue over the last three months complete in both sources |
| Realisation | For invoices raised in a month: settled invoice value ÷ identified invoice value (both ex-GST basic). Settled = basic × (1 − open ÷ net) for invoices still in the ledger; full basic for invoices only seen in receipts. Headline = invoices at least a month old at the snapshot |
| Identified invoice value | Distinct invoices (canonical number) from the ledger snapshot and receipts quoting an invoice; identical repeated ledger lines counted once here |
| Not traced | Reported revenue for the month − identified invoice value (if positive) |
| Months of revenue outstanding | Open invoice value restated ex-GST ÷ average monthly reported revenue (same three months as cash cover) |
| Average days to collect | Amount-weighted days from the end of the invoice month to the receipt date (receipts quoting an invoice) |
| Receipts not in the ledger | Receipts dated at least `recon_grace_days` (7) before the snapshot against invoices the snapshot still shows with no part-receipt |
| Revenue / invoiced / collected per case | Reported revenue, identified invoice value and settled value (ex-GST) ÷ tracker cases of the month; tracker rate = case-weighted leaf rate on the month's last snapshot; billing gap = invoiced per case ÷ rate − 1 |
| Smart alerts | Rules in setting `alert_rules`: >30 % of a location's balance over 180 days (≥ ₹1 L); unadjusted > 20 % of balance; cash cover < 60 %; collections down > 25 % month on month; receipts not in ledger; possible duplicates; billing gap > 10 %; stale snapshot (> 35 days) or receipts (> 20 days); balance on invoices before Apr-2024 |

## Period comparisons and client × location growth (22-Oct-2026, `bi.api_growth`)
| Measure | Definition |
|---|---|
| Completed month | The selected month once it has ended; while it is still running, the month before |
| Completed quarter | Indian financial-year quarter (Q1 Apr–Jun, Q2 Jul–Sep, Q3 Oct–Dec, Q4 Jan–Mar) whose three months have all ended |
| MoM | Completed month vs the month before (full months only) |
| MTD | Latest report of the running month vs the previous month's latest report on or before the same working day (Monday–Saturday); labelled partial |
| QoQ | Sum of the three months of the completed quarter vs the sum of the previous quarter's three months — never an average of monthly rates |
| QTD | Completed months of the running quarter + MTD vs the same months of the previous quarter + its report on the same working day; labelled partial |
| YoY | Completed month vs the same month a year earlier; quarter vs the same quarter a year earlier. MTD vs last year only where a daily report exists for that month (none before Jun-2026) |
| Change / change % | Change = current − earlier, always shown. Change % = change ÷ earlier, hidden when the earlier figure is below 30 cases (90 per quarter) or ₹25,000 (₹75,000 per quarter), zero or missing |
| Per working day | Cases ÷ Monday–Saturday days in each period; shown when the two periods have a different number of working days |
| Like for like | Only location × client pairs with business in both periods. Reported = like for like + new pairs − lost pairs |
| Target attainment | Cases ÷ target cases (and revenue ÷ revenue target) where every month of the period has a target (from Jun-2026) |
| Organic expectation (pair) | Sum of the stored organic model (`bi.organic_store`) over the client family's codes in the location, rounded; to date = month organic × share of a month normally done by this working day |
| Effort | Actual − organic expectation. An estimate of business above or below business as usual, not proof of cause |
| Organic accuracy | Last 10 completed months: Pan India mean absolute % error and location × client WAPE (sum of absolute errors ÷ actual), recomputed on every request for the current filters |
| Share of net change | Pair change ÷ |net change of the selection| (shares add up to ±100 %) |
| Branch coverage / never activated / gone quiet / recently activated | Verified, code-matchable branches of the client family in the location with a Force1 case in the last 6 months / none since Force1 history began / last case more than 6 months ago / first case in the last 3 months |
| Indicative cases per month | Never-activated branches × median monthly Force1 cases of ≥ 5 active peer branches of the same client in the same location. A sizing aid, not a forecast |
| Force1 utilisation (pair) | Location-group × client value for the completed month (shared by locations in the same group) |
| TAT (pair) | Median raw case TAT (valid completed cases) and SLA met %, completed month vs the month before; "worse" when the median rose more than 10 % on at least 20 cases |
| Owner = Stakeholder (mapped) | Stakeholder mapped to the location at the end of the completed month (effective-dated); flagged when it changed during the month. Shown as "Stakeholder (mapped)" from 22-Oct-2026 |
| Branch manager (mapped) | Manager assigned to the location — or to this client family at the location, which wins — on the last day of the period (`bi.branch_manager_at`, effective-dated, Admin → Master data & mapping). Earlier side: the day before the period starts; "changed" when both are known and differ. Billing units that combine locations list every member's manager ("A, B") and count members without one. Mapped responsibility, not proof of cause |
| Priority | Indicative cases × (1 + effort %, capped ±50 %) × 0.5 when TAT is worse or SLA met < 80 %; only pairs with ≥ 30 cases and a peer benchmark |
| Confidence notes | Small base, new this month, no business last year, location attributes changed in 12 months, owner changed, branch manager changed (previous → current), no organic estimate |

## Revenue-first metric dictionary (22-Oct-2026, wave 092 — one definition per metric, computed in SQL only)
The UI, exports, drills and Ask Crux read these from `bi.api_growth_rev`, `bi.api_growth`, `bi.api_collections` and the finance aggregates. No comparison is computed in the browser.

| Code | Metric | Exact definition | Never |
|---|---|---|---|
| A | **Expected minimum revenue** (tracker revenue) | Σ Zonal Tracker leaf revenue (`G` = cases × rate, rate changes applied by report day) for the period, non-roll-up locations (`bi.v_month_business.revenue`). Shown as "Expected minimum revenue" with the tooltip "an expectation from tracker cases × agreed rate, not money billed" | Labelled or summed as actual revenue; used in place of a missing actual |
| B | **Actual billed (invoiced) revenue** — the default measure | Σ invoice basic value **ex-GST** of distinct invoices (canonical number `bi.fin_inv_key`) by **invoice month** (the month in the invoice number), from the latest outstanding snapshot ∪ receipts that quote an invoice; each invoice once (`bi.fin_inv_month.basic`). GST, gross, TDS and net are held separately (`gross_l`, `tds_l`, `net_l`, from ledger lines). It is invoiced value, not recognised revenue (no recognition rules are available). The invoice month is used as an approximation of the service month only because invoices are raised at month end and invoice-month billing tracks the same month's cases best (location × client correlation 0.92 vs 0.84 next month and 0.90 previous month, Apr–Aug 2026); per-case figures are therefore labelled approximate | Taken from "Actual Outstanding"; mixed with GST; substituted by A when missing |
| — | Billing completeness | A month is **complete** when the outstanding snapshot date ≥ month end + 30 days (`fin_config.billing_complete_days`) and the month is on or after the month before the first receipt period (`first_complete` = Mar-2026). Sep-26 and Oct-26 are **partial** (snapshot 15-Oct); months before Mar-26 are **incomplete**. Only complete months are compared | Comparing a partial month |
| — | Billing unit | A location, or a whole zone when ≥ 10 % (`zone_billing_share`) of the zone's complete-month invoice value cannot be placed below zone level (Gujarat, Bhopal-MP, Lucknow). A location filter inside a zone-billed unit leaves that unit out of the totals and lists it under "not in totals" | Splitting zone invoices across cities by guesswork |
| C | **Cash received** | Bank-account credits by **receipt month** (incl. GST, after TDS), `bi.fin_rcpt_agg.amount`; split into invoice-matched (`inv_amount`, receipt quotes an invoice) and **unallocated** (no invoice). Matched receipts are further classed closed / partial / open against the ledger. A receipt repeated in two current uploads is counted once (latest upload); identical credits inside one file are kept and sent to review. TDS is not cash | Counted as revenue of the receipt month |
| D | **Outstanding** | Σ "Actual Outstanding" of the latest outstanding snapshot, always shown with its as-of date (15-Oct-2026). A corrected file for the same date replaces the earlier one; different dates sit side by side | Summed across snapshots |
| E | **Settlement / realisation** | For invoices of an invoice month: settled ÷ invoiced, **both ex-GST** — settled = basic × (1 − open ÷ net) for ledger invoices, full basic for invoices seen only in receipts. Cash allocated to the cohort (receipts quoting those invoices, incl. GST) is reported next to it, never divided by ex-GST revenue. "Cash cover" (cash ÷ expected minimum revenue) is labelled a cash-flow indicator because the bases differ | Dividing GST-inclusive cash by ex-GST revenue without saying so |
| F | **Revenue per case** | Expected per case = A ÷ tracker cases; billed per case = B ÷ tracker cases; settled per case (Revenue & collections) = settled ex-GST ÷ tracker cases — numerator and denominator always the **same months and the same pairs**. Billing gap = B − A (and ÷ A). Labelled approximate (invoice month ≈ service month, see B) | Per-case on mismatched months |

### Revenue period comparisons (`bi.api_growth_rev`)
| Period | Revenue definition |
|---|---|
| MoM | Latest complete billing month vs the month before (Aug-26 vs Jul-26 on 22-Oct) |
| QTD (billing) | Complete billing months of the running FY quarter vs the same months of the previous quarter (Jul+Aug-26 vs Apr+May-26) — sums, never averages |
| QoQ / quarter vs last year / YoY / YTD | Available only when every month on both sides is complete. Today unavailable (Jan/Feb-26 and all of FY25 are not completely billed in the finance workbooks): the card says why and shows the expected-minimum benchmark instead. YoY on invoices becomes possible with Mar-2027 data |
| MTD | Not available for invoices (raised at month end); shown as "in progress" with billed so far and coverage |

| Field (every card, pair and group) | Definition |
|---|---|
| actual current / previous, change, change % | B for each side; change % hidden below ₹25,000 a month on the earlier side |
| organic current / previous, organic growth | Σ revenue organic expectation for each side (below), covered pairs only |
| growth beyond organic | (actual current − actual previous) − (organic current − organic previous) = effort current − effort previous |
| effort | actual − organic for one period; effort % = effort ÷ organic |
| covered share | share of actual billed value in pairs that have an organic estimate in every month of both sides; reported on each card |
| like for like / structure | pairs billed in both periods; new / lost / expected-but-not-billed pairs with their values, so totals reconcile to pairs |
| confidence notes (pair) | zone-combined invoices; no invoices although the tracker shows expected revenue; invoiced < 50 % or > 200 % of expected; small base (< ₹25,000 last month); new this month; organic from the family ratio; no organic estimate; owners differ across combined locations; owner changed this month; branch manager changed this month (previous → current); branch managers differ across the combined locations |

### Revenue organic expectation (`bi.fin_org_rev`)
`organic billed (unit × client, month t) = organic cases(t) × billed per case(ref) × rate(t) ÷ rate(ref)` where organic cases come from the case organic model (`bi.organic_store` — the 50/40/10 MoM/QoQ/YoY blend from 22-Oct-2026), billed per case(ref) = Σ billed ÷ Σ cases over up to the last 3 complete months before t in which the pair had billed > 0, expected > 0 and ≥ 10 cases, excluding months whose billed ÷ expected ratio is outside 0.5–2× the pair's median; at least 2 such months needed. Otherwise **family basis**: family uplift (Σ billed ÷ Σ expected over the same months) × the pair's tracker rate. Otherwise **unavailable** (never zero). Organic expected-minimum = organic cases × rate(t).
**In a comparison both sides use one basis** — the reference months before the first month of the *current* side (`bi.fin_org_basis`) — so expected organic growth comes only from organic case growth and tracker-rate changes, never from a change of estimate between the two sides. (Before bi_092m each month used its own window, so a pair could switch from the family ratio in one month to its own rate in the next and show a large "beyond organic" figure that was only a change of estimate.) The monthly estimate and the back-test keep each month's own window.
Back-test (May–Aug 2026, each month predicted from earlier months only): Pan India mean error 6.1 %, unit × client WAPE 29.2 %, coverage 98.9 %; naive "last month's billing" 12.7 % / 26.1 %. Effort is an estimate of business above or below business as usual — not proof of cause, and a mapped owner is not the cause.

## Branch-manager performance, current month and revenue first (28-Oct-2026, wave 094 — `bi.api_bm`, `bi.api_growth` measure "expected")
Business and finance are two departments with their own dates (SOW D137). Every figure below is computed in SQL; the page only formats it.

| Metric | Definition |
|---|---|
| Expected revenue (business) | Zonal Tracker cases × agreed rate, month to date to the latest daily report (current month). The default measure for growth, organic, rankings and the Overview comparison (`measure: "expected"`); never shown as billed revenue |
| Same working day last month | the previous month's report on the same working day (`previous_month_snapshot`); change and change % against it |
| Target, attainment, pace | target = tracker revenue target; attainment = so far ÷ target; pace target = target × working days done ÷ working days in the month; gap to pace = so far − pace target |
| Projection ("On course for") | so far ÷ the share of a month normally done by this working day (organic shape); projected attainment = projection ÷ target |
| Organic to date, effort | organic expectation of the month (50 % MoM, 40 % QoQ, 10 % YoY) × share of the month done, valued at each row's tracker rate; effort = actual − organic; effort % = effort ÷ organic (₹ based) |
| Branch manager of a row | `bi.branch_manager_code_at(location, client code, report date)`: client-code row > client-family row > location row, inside its effective dates. `bi.branch_manager_at` returns "A, B" when a family has several client-level managers |
| Billed (finance) | invoices (ex-GST) of the last completely billed month (`last_complete_billing_month`) and of the month still being billed (`billing_in_progress_month`); billing ratio = billed ÷ expected revenue of the same month |
| Collected (finance) | receipts (incl. GST) of the receipt month to the last receipt date (`receipts_through`) and of the previous month; pace = per working day vs the previous month |
| Outstanding (finance) | latest outstanding workbook |
| Finance per manager (allocated) | pooled per billing unit × client family × month, shared to location × client by tracker expected revenue, then summed by the manager of each location × client; receipts with no client family at a known location are shared across that location's clients; rows with no location stay "not attributable" (`finance.unallocated`). Manager rows + not attributable = source totals |
| Hand-over shift | for each change of manager: the same location × client keys, expected revenue (and cases) per working day in up to 3 completed months before vs up to 3 completed months from the change; rest-of-business shift over the same months; relative shift = (1 + own shift) ÷ (1 + rest-of-business shift) − 1; effort before / after; fewer than 3 months after = "early read". It shows what changed after the hand-over, not who caused it |

Checks (`bi.test_bm`, 11): M1 managers add up to the total = tracker revenue to date; M2 comparison = previous month's report on the same working day; M3–M5 billed / collected / outstanding by manager + not attributable = source; M6 precedence; M7 no overlapping assignments; M8 location filter; M9–M10 expected-revenue growth = tracker and pairs add up, beyond-organic identity; M11 hand-over arithmetic and windows.

**Rate recomputation (bi_094j).** When a snapshot row has no stored rate, a rate change or undo values that day's cases at the last stored rate earlier in the month (else the next one in the month), not at ₹0.

## Finance identity and whole-line attribution (28-Oct-2026, wave 095 — replaces the allocation in wave 094)
| Item | Rule |
|---|---|
| One line, one owner | Every invoice, receipt and outstanding line counts whole for one location × client (`bi.fin_attr`); nothing is shared by expected revenue |
| Invoice location | invoice series → row label → sheet; a zone-level / missing result is refined only by a place named in the label, client or branch text (case-mapping reference: branch words, places, merges) and only inside the same zone |
| Receipt location | cited invoice (its ledger location) → series → label (only inside the series' zone) → invoice number quoted in the narration → paying bank branch (branch code / IFSC → client branch master → location, else district / city / branch name / state through the place rules) → not identified |
| Client | family's only client at the location → client named in the text (MSME, INOP, TSR, Car Loan, HL, FSL, ITR, Retail) → family's largest client there over the last three months |
| Manager | branch manager of the line's location × client on the line's date (billed: month end; collected: receipt month end or the last receipt date; outstanding: snapshot date). Zone-level lines: the zone's single manager for that client family, else "not attributable" |
| Checks | `bi.test_fin_attr()` F1–F3 totals = invoices / receipts / outstanding; F4 known client codes; F5 share of the latest receipt month tied to a location. `bi.test_bm()` M3–M5 manager rows + not attributable = source |

Overview hero (wave 095): Revenue view = expected revenue so far, target revenue, working-day pace (target × working days elapsed ÷ working days in month), projection = revenue so far ÷ the share of a month normally done by this working day (same share as the case projection; range scaled the same way), organic expectation so far and effort, billed (month being billed and last complete month) and collected (receipt month to the last receipt date). Cases view unchanged.

## Operations, outstanding and case location (28-Oct-2026, wave 096)
| Item | Rule |
|---|---|
| Case location | Rule book order: area office → office learned for the branch (60 %+) → place in the branch name → branch customers' area (2+ cases, 60 %+) → residence pincode (longest prefix) → the file's usual location; Nagpur places follow the file's team |
| Force1 case attribution (utilisation) | Bank branch in the master first; otherwise the case location above; cases outside their unit flagged |
| Opening backlog (day d) | Force1 cases received before d and not completed before d (IST) |
| Closing backlog | opening + received − completed; must equal an independent count of cases open at the end of the day |
| Ageing bucket | calendar days from the received time to the end of the last reported day, open cases only: 0–1, >1–3, >3–7, >7–15, >15–30, >30 days (non-overlapping) |
| Gross outstanding | location sheets' outstanding (collection + reconciliation target) |
| Received, not linked to an invoice | the sheets' "Less Unadj" lines (money in the bank not yet applied to an invoice) |
| Net invoice balance | gross − received not linked; workbook adjustments listed, never deducted |
| Workbook check | summary-sheet rows matched to location sheets by total (within ₹1); a missing sheet or a difference ≥ ₹1 = "not reconciled" |
| Receipts not tied to a location | receipt-month receipts with no location ÷ all receipts of that month |

## Identity, reconciliation and operations views (29-Oct-2026, wave 097)
| Item | Rule |
|---|---|
| Point location | the case's location only when the case exists and the point's branch equals the case's branch; otherwise place in the point's branch name → point pincode → the point file's usual location → not identified. A point's unit is its own file's unit |
| Tracker label with a team suffix | "Label (team)" resolves to the location whose label (without the suffix) is already known; logged for review |
| Daily case sequence (Business Tracker) | per day: opening backlog, Zonal Tracker dated count (that report's MTD − the previous report's MTD; unchanged, never added), received, completed, closing = opening + received − completed, median TAT of the day's completions, open > 7 days at day end; check = the identity holds and each day opens where the previous closed |
| Outstanding status | "Reconciled" when summary = sheets row by row; "Not reconciled — difference explained" when every difference is traced (e.g. sheets left out of the summary); "Unreconciled" when a material difference is unexplained |
| Invoice numbers in two sheets | "look like the same line" = same client, invoice month, basic and outstanding (branch is not stored) — an upper bound for lines counted twice |
| Collection cut-off | the last receipt date in the bank sheets, not the file label |
| Receipts not credited to one manager | no location, or a zone with more than one manager, or no client — reported separately from "no location" |
| Coverage codes | Force1 branch codes of the last 6 months for clients with an RBI branch list; "not in the list" = code not in the branch master for that client |

## Potential, targets and the quarter plan (7-Nov-2026, wave 101b — owner wording: BAU = trend, Potential = all client branches)
- **Potential** (all client branches) = current + back to own best + dormant + never-active (served / clients Crux has / areas without a team / new banks). Oct-2026 basis ₹10.00 cr a month; current ₹2.54 cr = 25.4% captured.
- **Current pace** (month k) = P0 ÷ (wd0 × si0) × wd(k) × si(k) per team × client; P0 = the latest tracker month's revenue projected to month end (÷ the usual share of a month reached by that working day); wd = working days; si = seasonal index (`bi.organic_si`).
- **Opportunity** = potential × factor − pace (per team × client, never below 0).
- **Target** (month k) = (pace0 + c_k × opportunity) × factor_k; c_k = C × k ÷ H; growth from month to month kept between gmin and gmax after seasonality (default) or in rupees. Each team × client gets its pace plus its share of the captured opportunity. Defaults H 12, C 30%, gmin 2%, gmax 12%.
- **Quarter plan**: plan(month) = saved plan → tracker target → suggested target; outlook = actual (completed) · actual so far ÷ share of month (current) · pace (later); delta = outlook − plan; shortfall = max(plan − outlook, 0); needed per working day = (quarter plan − actual so far) ÷ working days left in the quarter, against pace per working day. Quarters: Indian financial year (Q1 Apr–Jun … Q4 Jan–Mar).
- **Zone tile split**: each team against its own target to date (on track ≥ 90%, behind 60–90%, far behind < 60%); amber when the total looks fine but ≥ 3 teams with a target are mostly behind, or the zone is carried (half from one team or ≤ 20% of teams).
- Each metric's math, sources and API names are stored in `bi.metric_doc` and shown behind every "?".

## Wave 102 rules (7-Nov-2026 night)
- **Clients inactive PAN India** = no tracker cases in any team in the last three months incl. the latest month → out of potential, targets and branch lists.
- **Target floor** (owner 8-Nov, D254) = last month's actual business × 1.02 per team × client (complete month: actual; running: expected closure; not started: forecast); in the suggested path each later month ≥ the month before × 1.02; old tracker targets are not a floor; dormant pairs keep their old target; **strong signal** = a month that fell ≥ 5% vs the month before in every year on record → may fall by the smallest fall on record (April today: 26.2%).
- **Target sheet**: last month = actual | actual so far ÷ s(k) | pace forecast; capacity C = max(last month, last 3 months average, BAU), ceiling U = 1.5 × C; base = max(min(plan, U), last month × 1.02 [signal month × (1 − allowed fall)], BAU × 1.02); catch-up = quarter shortfall so far × plan_M ÷ Σ plan of the remaining quarter months, added up to min(potential, U); viewers get zone / team roll-ups and one team at a time, admins the full sheet (D255); cases = ⌈revenue ÷ rate⌉.
- **Situational target (D259)**: situation per location × client — dormant (old target), new (last month × 1.15 × season), growing (last month × (1 + min(½ × excess, 10%)) × season), stable (last month × season), declining (3-month average), collapsed (last month + ½ × gap to the average); new / growing / stable + activation 2.5% × (potential − value) and plan share if higher; base = max(min(value, 1.5 × capacity), last month × 1.02, BAU × 1.02); catch-up = team quarter shortfall over new / growing / stable rows by room to grow.
- **Share of the month s(k) (D265)**: the usual share of a month's final cases reached with the same number of working days left (kk − k), averaged over up to 12 earlier months; fallback = same working day k. 30-Oct-2026 (one working day left) = 0.958. Projection = so far ÷ s(k); BAU to date = BAU month × s(k).
- **Root cause (D262)**: gap = target − (so far ÷ usual share of the month); business slowdown = so far > 5% below BAU; target stretch = at or above BAU but likely < 95% of target.
- **Variance** = outlook − plan; variance % = variance ÷ plan; levels add up (zone = Σ teams = Σ team × client).
- **Branch status** (verified branches of active clients): active = Force1 case in the last 3 months; dormant = earlier cases only; never active = none since Jan-2026.

## Ask Crux v4 — the AI analyst (9-Nov-2026, wave 105)
- **How an answer is made:** question (+ the page month and filters, + last 3 turns) → Gemini decides which look-ups it needs → tools run the dashboard calculations (bi_call) or one read-only SQL query (ai.run_select) → Gemini writes the answer → figure check → stored in bi.ai_message with its trace.
- **Figure check:** every figure in the answer (₹ / L / cr / % / counts; dates, years and counts ≤ 12 ignored) must match a looked-up figure, or a difference, sum, ratio or % change of two figures from the same row or a total, within one unit of the last digit shown. 3+ untraced figures, or more than 25%, → calculated answer shown instead.
- **Same rules as the dashboard:** likely month end = so far ÷ share of month done; vs BAU = so far ÷ BAU − 1; root cause: ahead (≥ 100%), on track (≥ 95%), business slowdown (vs BAU < −5%), else target stretch; potential = current + untapped headroom; penetration = current ÷ potential.
- **Names:** replaced by codes before anything is sent to the AI; shown back in the answer.

## Ask Crux memory (9-Nov-2026, wave 105c)
- **Similarity** = cosine similarity of the two questions' embeddings (gemini-embedding-2, 768 dimensions, task SEMANTIC_SIMILARITY; names replaced by codes first).
- **Content words** = the question's words without filler words (how, is, the, which, show …), plurals reduced to singular. **Key words** = numbers; team, zone, client and person names; month and period words (last, next, week, year …); level (team / zone / client / branch / manager); direction (ahead / behind, top / bottom, grew / fell, not); topic (TAT, receivables, potential, plan, Force1, penalty, backlog, coverage, dormant).
- **Reused** = same page context + unchanged data version + similarity ≥ MEMORY_REUSE_SIM (0.92) + same content words → saved answer, 0 AI calls.
- **Updated (adapted)** = same page context + similarity ≥ MEMORY_ADAPT_SIM (0.85) + same key words + a saved look-up plan → plan re-run on today's data, then one AI turn updates the earlier answer.
- **Fresh** = everything else.
- **AI calls saved (estimate, last 30 days)** = Σ over reused and updated answers of max(average AI calls per fresh answer − AI calls used, 0).
- **Answers in memory** = AI answers with an embedding that an admin has not excluded from reuse.
- **Lesson** = a 👎 note on an answer whose question is at least 0.72 similar to the new question (up to 3, admin-switchable).

## AI agents (9-Nov-2026, wave 105f)
- **Morning briefing figures checked** = figures in the published briefing that match a look-up or simple arithmetic between related figures (same rule as Ask Crux). Statements whose figures cannot be checked are left out; "left out" = number of table rows, bullets or sentences removed. The report fails when more than 40% of its lines would be removed.
- **Our figures beside a news item** = the client family's revenue month to date, and likely month end ÷ target, summed over that family's client rows of the dashboard client breakdown (sorted by revenue, top 40 rows) — calculated in code, never by the AI.
- **Chat review numbers** (since the previous review): questions, answered by the AI, updated from memory, reused from memory, calculated fallback (the AI could not answer), 👍, 👎, answers with untraced figures.
- **AI calls** per agent run are counted in bi.ai_provider_usage under purposes agent_brief, agent_news, agent_review, agent_weekly.

