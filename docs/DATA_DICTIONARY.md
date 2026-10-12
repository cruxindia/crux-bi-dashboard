# Source data dictionary

Confidence: H = verified against values/formulas; M = consistent evidence, not formally confirmed; L = provisional.

## Zonal Tracker — `Main Tracker` (one file per snapshot date)
| Col | Header | Meaning | Type | Derivation / rule | Conf |
|---|---|---|---|---|---|
| A | Location | Location label (leaf) or zone header / `Total …` | text | Typos and renames resolved via `bi.location_alias` | H |
| B | Client | Client label; on total rows holds tier (`Zone A`, `Zone B`, `Client Total`) | text | `bi.client_alias` | H |
| C | (unlabelled) | Region tag on total rows (`West Client Total`…) | text | Region of member locations | H |
| D | Target `<Mon YY>` | Current-month case target | int | Entered by Business Support | H |
| E | Actual MTD | Cumulative cases this month to snapshot | int | Leaf: constant or `=a+b+c` (sub-branch parts); roll-up: SUMIF; total: SUM | H |
| F | Revenue Tgt | `D × rate` | ₹ | rate parsed from formula | H |
| G | Actual Revenue | `E × rate` | ₹ | rate stored in `zt_row.rate` | H |
| H | % Achmt | `G/F` (= E/D) | ratio | | H |
| I | Achieved (graph) | `REPT("█",H×20)` | text | Not stored (presentation only) | H |
| J | BD Revenue | Business-development revenue | ₹ | Stored as-is | M |
| K | Shortfall | `G − F` | ₹ | | H |
| L | Projected Expense | Location expense; formula or constant, placed on varying rows | ₹ | Stored as-is; aggregated only at location-total level | L |
| M | Shortfall | Totals: `G − L`; Zone A/Pan India: `G − K` (inconsistent) | ₹ | Stored as `margin_after_expense`; not used in KPIs | L |
| N | YTD | Actually `G − 2×L` — **not year-to-date** | ₹ | Stored as `col_n_value`; not shown as YTD | L |
| O | `<dd.mm.yyyy>` | Leaf: `E − prev MTD` (case delta). Totals: `G − prev revenue` (revenue delta) | mixed | Kept as `src_daily_value`; database recomputes deltas | H |
| P,Q,R | Location/Client/Region (history side) | Labels for the history block (e.g. `SBI HL`) | text | Used as alias evidence | H |
| S… | Month blocks | Per month: cases (`Actual MTD`/`Target MTD`), revenue, billing | num | Row 1 marker: month = month, year = 2000 + day | H (2026) / M (2024–25) |
| bottom | Zone A/B, N/S/E/W, ROI, Pan India; client-wise; stakeholder-wise | Summary formulas | — | Stored as summary rows; Pan India used as control total | H |

## Case Wise — `Case MIS`
| Field | Meaning | Rule | Conf |
|---|---|---|---|
| Case ID | Force case identifier | Primary key; duplicates across files resolved (D9) | H |
| Client | Full bank name | → client code/family | H |
| Branch, Branch Code, Branch Type, Area Office | Client branch details | Area Office/branch tokens refine location within a group | H |
| Status | Completed / In Progress / Pending | | H |
| Received At | Case received (UTC) | Month bucket in IST | H |
| Completed At | Case completed (UTC) | Case TAT = Completed − Received | H |
| Estimated TAT | **Due datetime** (Received + 24/42/48/72 h) | SLA met = Completed ≤ Due | H |
| Product | Loan product | | H |
| Points | Declared point count | Compared with Point Wise | M |
| Applicant Name, Mobile, Reference No./Name | PII / not needed | **Not ingested** | — |

## Point Wise — `Point MIS`
| Field | Meaning | Rule | Conf |
|---|---|---|---|
| Point ID | Verification point id | Primary key | H |
| Case ID | Parent case | 99.7% link to Case Wise | H |
| Point Type | Verification type | → `bi.point_type` category (field/document/tele) with evidence | H |
| Created Date | Point created (UTC) | Document TAT start | H |
| Assign To / Assign Date | Assigned executive / time | Field TAT start | H |
| Field Reviewed Date | Review timestamp — populated for ~98% of **all** types | Field TAT end (field types only); dates outside 2026 flagged invalid | H |
| Verified By / Completed By / Created By | Users | Workload; classification of employees | H |
| Completed Date | Point completion | Document/tele TAT end | H |
| Address (U) / Pincode (V) | Location of visit | Address → `has_address` only; PIN kept | H |
| PAN, Aadhaar, Bank A/c, applicant name/mobile, other reference numbers | PII | **Not ingested** | — |
