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

## Finance workbooks (21-Oct-2026)
**Collection workbook** (`Crux PanIndia Collection Sheet - till Sep26.xlsx`): one sheet per bank account (BOM, ICICI Bank, SBI - Ghatkopar, SBI - PBB Aundh, SBI - CIT, CANARA, AXIS) — Location, Bank, receipt Month, Date, Branch Code, Narration, Credit, invoice Month, Client, Branch, Invoice, Basic, Invoice Date; "Main" = April-only consolidation (cross-check); "Pvt Location" / "Pvt Client" = pivots of Main. Imported: sheet row, location label, bank, receipt month, receipt date, credit, client, invoice number as written, basic, invoice month and its source, and an 8-character fingerprint of narration + cheque + branch code + date + amount (the narration itself is not imported).
**Outstanding workbook** (`Crux Pan India Outstanding Sheet till Oct26.xlsx`): one sheet per location group — Location, Month, Client, Branch, Invoice No., Basic, GST, Gross, TDS, Net, Remark, Partial Received, Actual Outstanding (+ Date, Zone, Applicant Name, bank contact, GST no. on some sheets — **not imported**; the Branch column is not imported either because on some sheets it holds a borrower's name); a totals row, "Less Unadj" lines and "Total Outstanding" at the foot; "Pvt" = location summary. Imported per line: sheet row, location label, invoice month and its source, client, invoice number, basic, gross, TDS, net, partial received, actual outstanding, remark; per sheet: totals row, unadjusted lines, net control.

| Table | Content |
|---|---|
| bi.fin_upload | One row per imported workbook: kind, file hash (idempotency), as-of date and basis, period, status (staging / committed / superseded / rejected), control totals and file checks |
| bi.fin_part | Normalised rows as compressed arrays per sheet chunk (no personal data) |
| bi.fin_os_agg | Outstanding by upload × location × client family × invoice month (incl. ex-GST open value, negatives, possible duplicates) |
| bi.fin_unadj | Unadjusted receipt lines by upload and sheet label |
| bi.fin_rcpt_agg | Receipts by upload × location × client family × bank sheet × receipt month, with ledger match status and collection lag |
| bi.fin_inv_month | Identified invoices by location × client family × invoice month: value, settled, open, collected |
| bi.fin_review | Admin review queue (kind, key, amount, evidence, status, note) |
| bi.fin_loc_map / bi.fin_client_map / bi.fin_config | Admin-editable location rules (prefix / label / sheet), client families, settings |

## Growth endpoint and admin diagnostics (22-Oct-2026)
- `bi.api_growth(month, filters, p)` (via `bi_call('growth')`): `cards` (mom, mtd, qoq, qtd, yoy, qyoy, mtd_yoy — current/previous with label, cases, revenue, working days, targets, attainment, pairs, locations; change, change %, per-working-day %, like for like, new/lost pairs, complete flag), `unavailable` (id + reason), `organic` (share to date, validation by month), `net`, `pairs` (location, zone, unit, client family, owner, owner_changed, mapping_changed, cases, revenue, mom/qoq/yoy/mtd blocks, organic, branches, force1, tat, confidence, priority), `method`. No new table: computed from v_month_business, v_zt_leaf, organic_store, branch_cov_mv, branch_activity, v_force_usage and v_case.
- `bi.api_db_health()` (admin only, `bi_admin('db_health')`): database bytes, limit, headroom, growth per month, days to limit, 15 largest relations (heap/index/TOAST/free space), jobs, storage buckets, safeguards, owner actions.
- `bi.test_growth(month)`: 14 SQL tests (fixtures + independent recalculation).
- Trigger `zz_skip_noop_update` on `bi.point_store` and `bi.case_store`; `point_store.last_batch` / `case_store.last_batch` = batch that last changed the row.

## Revenue-first growth and finance integration (22-Oct-2026, wave 092)
Grains: **business** = `bi.v_month_business` (tracker cases, expected minimum revenue; location × client × month) · **invoices** = `bi.fin_inv_month` (each invoice once, by invoice month) · **receipts** = `bi.fin_rcpt_agg` (by receipt month) · **outstanding** = `bi.fin_os_agg` (by snapshot upload; never summed across snapshots) · **derived monthly** = `bi.fin_rev_facts` (computed on request, not stored). Existing tables reused; nothing new is persisted except the columns below.

| Object | Change / purpose |
|---|---|
| `bi.fin_config` | + `billing_complete_days` = 30 (a month is completely billed once the snapshot is this many days past month end), `zone_billing_share` = 0.10 (zone becomes one billing unit when this share of its invoices is zone-level) |
| `bi.fin_os_agg` | + `gross`, `tds` (ledger GST-inclusive and TDS, by snapshot) |
| `bi.fin_inv_month` | + `gross_l`, `tds_l`, `net_l` (ledger values of the identified invoices; receipt-only invoices have basic only) |
| `bi.fin_upload.controls.content_sha256` | SHA-256 over every staged chunk (`sheet|seq|sha256(rows)` joined by `;`, ordered by sheet, seq) — a re-saved copy of an imported workbook (new file bytes, same rows) is refused at `begin` (browser hash) or rejected at `commit` (server hash, audit `fin_duplicate_content`) |
| `bi.fin_derive()` | Receipts repeated across current uploads counted once (latest upload wins); identical credits inside one file kept and flagged; summary `receipts_repeated_across_uploads` |
| `bi.fin_billing_basis()` | Snapshot and receipt cut-off dates, first / last completely billed month, rule text |
| `bi.fin_month_status(month, basis)` | none / incomplete / complete / partial |
| `bi.fin_unit_map()` | Location → billing unit (location or zone), members, basis |
| `bi.fin_rev_facts(from, to, filters, at)` | Unit × client family × month: billed, invoices, settled, open, cash allocated, gross / TDS / net, expected minimum, cases, organic cases, `unit_ok`, `unit_split` |
| `bi.fin_org_rev(months, filters, at)` | Revenue organic expectation per unit × family × month with basis, reference months and rates |
| `bi.fin_org_validation(filters)` | Revenue organic back-test (also computed inside `api_growth_rev`) |
| `bi.api_growth_rev(month, filters, p)` | Revenue measure of the Growth / Organic / Overview / Revenue & collections business view: `billing`, `cards` (mom, qtd, qoq, yoy, qyoy, ytd — available or reason + expected-minimum benchmark), `in_progress`, `trend` (13 months), `organic.validation`, `pairs` (unit × client with per-period cur / prev / chg / pct / expected / cases / org / beyond / effort, owner as mapped, branches, Force1, TAT, settlement, confidence), `groups` (`p.group` = client / unit / zone / stakeholder / region), `not_in_totals`, `method` |
| `bi.api_growth(month, filters, p)` | Cases measure: cards and pairs now carry organic for both periods (`org_cur`, `org_prev`, `org_growth`, `beyond`, `effort_cur`, `effort_prev`), `groups`, `measure` = cases |
| `public.bi_call('growth', {measure})` | `measure: 'revenue'` → `api_growth_rev`, otherwise `api_growth` (same cache and authorisation path) |
| `bi.api_collections` | `flow` months gain expected minimum, cash allocated, gross / TDS in ledger, billing status; top-level `billing` |
| `bi.test_growth_rev(month)` | 14 SQL checks of the revenue and cases comparisons, recomputed from base tables |
| `bi.test_fin_fixtures()` | 15 controlled finance fixtures through the real ingest and derive, always rolled back |

## Organic blend and branch managers (22-Oct-2026, wave 093)
| Object | Change / purpose |
|---|---|
| `bi.organic_store` | + `b_mom`, `b_qoq`, `b_yoy` (the three bases, cases), `q_trend` (bounded quarter trend, 1 when not usable), `y_shape` (bounded same-month shape last year; null when not usable); `organic` = 0.5·MoM + 0.4·QoQ + 0.1·YoY, or (0.5·MoM + 0.4·QoQ) ÷ 0.9 without YoY. Unchanged rows are not rewritten |
| `bi.organic_pairs(month)` | Independent single-month implementation used by `bi.test_organic` to check the stored figures |
| `bi.test_organic()` | Store = function (< 0.1 %), three largest pairs recomputed one by one from monthly tracker figures (± 0.2 or 0.05 %), API total and zone rows reconcile, effort identity |
| `bi.api_organic` | `inputs` gain `organic_cases`, `b_mom`, `b_qoq`, `b_yoy`, `rows_with_yoy`, `organic_with_yoy`, and `q_trend` / `y_shape` for a single row; new `formula` and `why` texts |
| `bi.api_tracker_sheet` | Each row's `ob` = [MoM, QoQ, YoY bases, rows with YoY, organic of those rows, quarter trend, YoY shape] for the per-cell explanation |
| `bi.branch_manager` | id, location_id, client_family (null = whole location), manager, valid_from / valid_to (inclusive, null = open), active (false = withdrawn, kept), source, note, changed_by, changed_at. RLS on; reachable only through the admin RPC. **Names are data, loaded with `execute_sql`, never in migrations** |
| `bi.branch_manager_at(location, family, date)` | Manager on that date: client-family row first, then location row; latest start wins |
| `bi.branch_manager_admin(actor, p)` | `list` (rows, current flag, locations without a current manager, client families) · `add` (overlap refused unless `end_previous`; the audit row records any assignment it ended) · `end` (last day) · `withdraw` (reason ≥ 5 characters). Audit actions `branch_manager_add` / `_end` / `_withdraw` / `_load` (these do not mark derived tables stale) |
| `public.bi_admin('branch_manager', p)` | Admin-key path to the above (actor `admin-key:<editor>`) |
| `bi.api_growth_rev` pairs | + `branch_manager`, `branch_manager_prev`, `branch_manager_changed`, `branch_manager_shared`, `branch_manager_missing`; `group: 'manager'`; confidence notes for a changed manager and for different managers across combined locations |
| `bi.api_growth` pairs | + `branch_manager`, `branch_manager_prev`, `branch_manager_changed`; `group: 'manager'`; confidence note when the manager changed; `method.organic` and `method.owner` texts updated |
| `bi.ask_h_revenue(m, f, q)` | Ask Crux handler for revenue-growth questions (period, focus, measure detection); findings with Stakeholder (mapped) and Branch manager (mapped) |
| `public.bi_ai_gateway` | Name scrubbing also covers `bi.branch_manager` names (bi_093e) |


## Branch managers first, current month, revenue first (28-Oct-2026, wave 094)
| Object | Purpose |
|---|---|
| `bi.branch_manager.client_code` (new column, references `bi.client.code`) | Client-level assignment; precedence client code > client family > location (bi_094a) |
| `bi.branch_manager_code_at(location, client code, date)` | The single manager of a location × client on a date (client-code row, then its family row, then the location row; latest start wins) |
| `bi.branch_manager_at(location, family, date)` | Now also folds client-code rows of the family: returns "A, B" when clients of one family have different managers |
| `bi.branch_manager_admin(actor, p)` | `list` adds `client_code`, `client_label` and the `clients` list; `add` accepts `client_code` (overlap and end-previous scoped to location × family × code) and `source`; new `rename` (from, to — every row of a name, audited as `branch_manager_rename`) |
| `bi.api_bm(month, filters, p)` | Branch-manager performance: `month`, `as_of`, `partial`, working days, `previous_month_snapshot`; `finance` (billing months and rule, receipt month and date, outstanding date, `unallocated` by kind and month); `total`; `managers[]` (expected revenue, target, attainment, pace gap, projection, organic / effort, billed / collected / outstanding allocated, since, hand-overs in / out, `current`); `handovers[]`; `portfolio` and `trend` when `p.manager` is given; `method` texts |
| `public.bi_call('bm', …)` | Public path to `bi.api_bm` (args `m`, `f`, `p`); growth with `measure: "expected"` calls `bi.api_growth(…, {"value": "revenue"})` |
| `bi.api_growth(m, f, p)` with `p.value = 'revenue'` | Expected revenue (tracker cases × rate) instead of cases: cards, pairs, organic valued at each row's rate, small-base threshold ₹25,000; `measure: 'expected_revenue'` |
| `bi.api_tracker_sheet` | + `bm` on every row (leaf: manager on the report date; location total: distinct managers active on that date) |
| `bi.warm_drill_cache` | Also warms growth `measure: "expected"` and `bm` |
| `bi.ask_h_bm(m, f, q, manager)` | Ask Crux branch-manager answers (named manager; ranking; hand-overs) |
| `bi.bi_ask3` intents `bm`, `revenue_now` | Manager questions and "how is revenue" questions (expected → billed → collected, each with its own dates) |
| `bi.ask_h_revenue` | "Revenue" = expected revenue month to date unless billed / invoice / billing words are used |
| `bi.test_bm()` | 11 live checks M1–M11 (METRICS) |
| `bi.rate_recompute`, `bi.rate_admin` (`end`) | Null stored rates carried from the last stored rate of the month (bi_094j) |

## Finance identity (28-Oct-2026, wave 095)
| Object | Purpose |
|---|---|
| `bi.ref_place`, `bi.ref_state_default`, `bi.ref_branch_word`, `bi.ref_pin_prefix` | Case-mapping reference (28-Oct-2026): place → grouping → location; state default; branch-name words → place; pincode prefixes. Loaded with `public.bi_ref_load(token, json)` (admin token, upsert) |
| `bi.loc_of_grouping`, `bi.loc_of_place(place, hint)`, `bi.place_of_branch(name)`, `bi.loc_of_payer(family, code, name)` | Look-ups: grouping → location; place → location (Nagpur places follow the team named in the hint); branch name → place (last match wins, longer phrase first); paying bank branch → location / family / basis |
| `bi.rollup_zone(id)`, `bi.loc_refine(base, candidates)` | Zone of a zone-level location; first candidate inside that zone |
| `bi.fin_os_lines`, `bi.fin_receipts` | Same columns; location now refined as in METRICS (`loc_src` / `map_state` gain `+place`, `invoice_ref`, `payer_branch`, `payer_branch_place`, `payer_branch_name`) |
| Collection row columns 13–15 | `pbc` payer branch code or IFSC, `pbn` payer branch name, `ir` invoice number quoted in the narration (`web/extract.js`; earlier uploads have none) |
| `bi.fin_attr` | Whole-line attribution: kind (billed / collected / outstanding), upload, month, location, client code ('' = not identified), family, basis, client basis, amount, lines. Rebuilt by `bi.fin_attr_refresh()` at the end of every `bi.fin_derive` |
| `bi.fin_client_word`, `bi.fin_client_fits` | Client words in the finance client text and whether a client code fits them |
| `bi.test_fin_attr()` | F1–F5 |
