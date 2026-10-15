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
| L | Projected Expense | Projected monthly cost (salary + rent + other) | ₹ | **Ignored (D39: business confirmed incorrect)** — not loaded into reports | — |
| M | Shortfall | Revenue − expense | ₹ | **Ignored (D39)** | — |
| N | YTD | `G − 2×L` in the source | ₹ | **Ignored (D39)** | — |
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

## Dashboard-maintained tables (entered in the app, not from source files)
| Table | Holds | Key | Written by |
|---|---|---|---|
| `bi.zt_matrix_draft` / `bi.zt_matrix_meta` | Daily update table drafts (cumulative MTD per row × date) and per-date state | snapshot date × location × client | Upload centre → daily update table |
| `bi.zt_reopen` | Corrections: who reopened a committed date and why | date | ✎ on a committed date |
| `bi.zt_snapshot_archive` | Previous leaf values replaced by a correction | date × row × version | commit of a correction |
| `bi.client` (`summary_under`, `product`) | Client hierarchy for client-wise totals (e.g. SBI Car Loan+ → SBI, product Car Loan) | client code | Data quality |
| `bi.client_branch_master` | Verified client branch list: client, branch code/name, state, city, Crux location, status (active/closed/ineligible), opened/closed dates, source, verified on, confidence | client + branch code | Data quality → Master data |
| `bi.workforce_master` | HR list: employee ID, name, role, classification, location, joining date, exit date, exit reason (admin only), source | employee ID (else name) | Data quality → Master data |
| `bi.rate_change` | Rate per case for a location × client from a WEF date, with reason, who, undo trail | location × client × WEF | Daily update table → Rate changes from a date (or a rate typed in the table) |
| `bi.penalty` | ₹ penalties by date × location (optional client), reason, reference, who; cancelled entries kept | id | Business tracker → Penalties (admin) |
| `bi.organic_store` | Organic expectation and its inputs per month × location × client | month × location × client | Refreshed automatically every 10 minutes when data changed (`bi-organic-refresh`) |

## Branch intelligence and AI tables (addendum, 14-Oct-2026)
| Table | Holds | Key | Written by |
|---|---|---|---|
| `bi.client_branch_master` (extended) | Plus: branch_uid (`IFSC:…`, `CANFH:…`, `GIC_HFL:…`, `TATA_CAP:…`, `UPLOAD:…`), client_family, IFSC, MICR, aliases, address, district, PIN, centre, branch_type, zone group, territory basis, source type/URL/version, first/last seen, verification status, research notes, row hash, `code_norm` (generated) | client × branch code; branch_uid unique | monthly monitor, research loads, client-list uploads |
| `bi.client_branch_history` | Effective-dated changes: added, renamed, relocated, address/territory/status changed, reappeared, closed | id | monitor, review resolution, uploads |
| `bi.branch_seen` | Last monitor run in which each branch was listed | branch_uid | monitor |
| `bi.branch_review` | Review queue: duplicate candidates, no longer listed, source incomplete/unavailable/changed, conflicts | id; one open item per family × branch × issue | monitor, uploads; resolved by admins |
| `bi.branch_source` | Hash and fetch date of each lender's official locator page | family | monitor |
| `bi.client_family_research` | Research registry per client family: entity type, primary source, locator URL, status, notes, source version | family | research loads, monitor |
| `bi.location_territory` | Territory rules: state + district (or PIN prefix, or state default) → Crux location, effective-dated | rule | admin (`territory_set`) |
| `bi.job_run` | Background job runs: trigger, status, heartbeat, per-family stats, errors, summary | id | monitor |
| `bi.branch_activity` | Force1 case activity per client family × normalised branch code (first/last month, totals, last 3 months) | family × code | cron `bi-branch-activity` |
| `bi.branch_cov_mv` | Narrow materialized projection of the master used by coverage | — | refreshed after each monitor run and upload |
| `bi.ai_config` | Non-secret AI settings | key | admin / validation job |
| `bi.ai_model_check` | Model validation results (models.list + synthetic test) | id | cron `bi-ai-validate` |
| `bi.ai_provider_usage` | Each AI call: model, purpose, ok, ms, HTTP status, retries, tokens, note (no prompts, no secrets) | id | ask-crux |
| `bi.kb_doc` / `bi.kb_chunk` | Approved definitions and methods for RAG; chunk embeddings (vector 768) with model and dimension | doc / chunk | `bi_admin('kb')`, cron `bi-ai-embed-sync` |

## Wave 15-Oct-2026
| Object | Purpose | Key | Written by |
|---|---|---|---|
| `bi.mapping_correction` | History of mapping corrections: kind, source, alias, old → new target, effective date, reason, actor, affected counts | id | `bi_admin('mapping_retarget')` (admin key) |
| `bi.api_drill(month, filters, level, p)` | Drawer data: selected, parent, children with ids, organic to date, 12-month history, branch rows (level = branch) | — | read via `bi_call('drill')` |
| `bi.api_branch_detail(p)` | One client branch: master record, monthly Force1 cases, first/last month, peer median | — | read via `bi_call('branch_detail')` |
| `bi.api_drill_ops(month, filters, level, part)` | Drawer parts: tat, force1, coverage, lifecycle, revenue, penalty — selection total and per child | — | read via `bi_call('drill_ops')` |
| `bi.tat_summary(month, filters, group)` | Case, document, field and tele TAT by total / zone / location / client / unit / branch | — | read via `bi_call('tat_summary')` |
| `bi.branch_lifecycle_rows(units)` | Branch lifecycle classification (same rules as the priority list) | — | internal |
| `bi.cache_warm` | Last cache warm-up: data version, start / finish, calls, seconds | id = 1 | cron `bi-warm-drill-cache` |
