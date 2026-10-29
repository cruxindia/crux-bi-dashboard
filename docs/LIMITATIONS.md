# Known limitations register

| # | Limitation | Impact | Mitigation / next step |
|---|---|---|---|
| L1 | Point Wise now to Oct-2026 except Kolhapur-Vinayak (Jul only) and Lucknow/Kolkata (no new files); Case Wise ends Oct-2026 (some groups earlier) | Field metrics missing for those groups after their last file | Upload their files; freshness shown per group |
| L2 | No Case Wise files for Amaravati, Jalgaon, Solapur, Nanded, Punjab (partly), Bihar/Patna, Goa (via Mumbai only) | ~4,100 Oct cases cannot be compared with Force | Shown as "not received", never as 0% Force |
| L3 | Case Wise cannot distinguish BOM MSME PRE/POST, SBI Car Loan+ | Force usage only at client-family level | Need a product/sub-client field in Force export |
| L4 | Route is rule-based (D17), not an explicit source flag | Manual share may be overstated if back-office staff submit field points in-app | Validate with Ops; a Force submission-channel flag would make it exact |
| L5 | Tracker expense block (L/M/N) is incorrect (business confirmed 14-Oct) | Ignored everywhere — not displayed, not used | — |
| L6 | Historical tracker targets not in source | No historical achievement % | — |
| L7 | 2,425 negative case TATs (mostly Guwahati), 1,353 points without a Case Wise case | Excluded / counted at point level only | Logged in `bi.dq_exception` |
| L8 | Storage: **527,134,897 bytes (all databases) on 28-Oct-2026 13:20 UTC — over the 500,000,000-byte Free-plan limit** (482.2 million after the 21-Oct cleanup; new data adds about 42 MB/month). The project was still writable on 28-Oct (not read-only), but Supabase can switch an over-limit Free project to read-only, after which uploads and cron jobs stop | Limit already passed | **Decide now** (SOW Q10/Q19): Supabase Pro or an approved archive design; owner script frees ~23 MB (STORAGE_AUDIT §9) |
| L9 | Dashboard is public (anyone with the link can read business figures and employee names) | Business decision | `noindex`; rotate the link by renaming the repo if it leaks; admin functions need the key |
| L13 | Anonymous API calls can be repeated by anyone (no rate limit) | Possible load spikes | Result cache absorbs repeats; Supabase rate limits apply |
| L10 | Browser upload uses SheetJS 0.20.3 (inlined in artifact build) | — | Keep pinned; files from trusted internal sources only |
| L11 | 1-Jul, 1-Sep, 1-Oct snapshots have no targets yet; 6–17 Jul and 1/3/4/5-Sep source totals disagree with leaf rows | Pan-India totals in those files unreliable | Leaf rows used; mismatches logged |
| L12 | Udyam classification conflicts with brief | Possible misclassification of 1,189 points | Admin review in Data quality |
| L15 | ~~No verified client branch list~~ — replaced by the source-verified master (14-Oct night) | — | Client lists can still be uploaded; they are matched by normalised code and never overwrite official rows |
| L16 | No workforce list (joining/exit dates) uploaded yet | People → Headcount & attrition shows a banner | **Ready for data:** Data quality → Master data → Workforce master. People are matched to Point Wise by name unless names are spelt the same way, so workload links may be partial |
| L17 | Ask Crux AI wording is a short summary without figures; it is dropped (calculated answer only) when it fails the figure/format/direction check, for people questions, or when the free-tier quota is exhausted | Some answers show no AI summary | By design; the calculated answer is always complete. Free-tier prompts may be used by Google to improve its products (paid tier: not used) — switch to a paid key if that matters |
| L18 | ~~Interrupted loader batches #361/#366~~ | Resolved 14-Oct (marked rejected, staging rows cleared) | — |
| L19 | Tracker replica recomputes subtotals from leaf rows; the source BD-revenue/Shortfall (J/K) totals use broken ranges (e.g. Mumbai+Goa BD ₹2,400 vs ₹1,200) | Small differences in J/K totals only; all target/MTD/revenue totals match | Fix the Excel formulas or accept dashboard values |
| L21 | Master uploads are additive (upsert); a branch or person wrongly uploaded cannot be removed from the dashboard | Wrong rows persist | Re-upload with status `closed`/`ineligible` (branches) or an exit date (people); deletion needs a governed admin function if required |
| L23 | Organic seasonality is by calendar month (Pan India). Festivals that move between months (Diwali: 1-Nov-2024, 20-Oct-2025, 8-Nov-2026) shift business between October and November | Organic can be off by ~10–20% in Oct/Nov (e.g. Nov-2025 effort shows +44%) | Read Oct/Nov effort with care; a festival-calendar adjustment can be added with the market-events agent |
| L24 | Organic needs 3 complete prior months for a location × client; brand-new rows have organic 0 (all business = effort / new business) | Correct by definition but large % for new rows | Shown as "New business" |
| L25 | Branch evidence behind effort covers Force1 case reports only (not every location) | Partial attribution | Labelled on screen |
| L26 | First page load after each data change computes the new figures (Overview up to ~15–20 s once); later loads are cached | One slow load per change | Acceptable; pre-warming can be added |
| L27 | The Lumen bill extractor shares this project (tables in `public`, buckets `ocr` and `bills`). It was wrongly removed on 14-Oct and rebuilt on 15-Oct (SOW D84); bills before 15-Oct were not reloaded (owner's 14-Oct choice) and its client list re-learns from new bills. Its page uses the public key with no login, so anyone with that key can read and change its bill data — as before | Lumen only; the BI dashboard is unaffected | Keep both buckets; add a login to Lumen if its data must be protected |
| L22 | One person without an employee ID in one upload and with it in another becomes two records | Headcount overstated | Always include employee_id |
| L20 | Daily update rows come from the latest tracker snapshot; a brand-new location or client row still needs one full tracker upload. Back-dating a date that falls before a label change (e.g. 2-Oct) may need a full-file upload instead | — | Add row management to the entry table if structure changes often |
| L28 | Bank branch universe uses IFSC entries; some banks list more IFSCs than branches (SBI about 8% above a published branch count) and 1,052 same-name, same-PIN pairs (mostly merged-bank IFSCs) await review | Universe slightly overstated; coverage slightly understated | Review queue in Data quality; nothing merged automatically |
| L29 | Non-bank lender lists (updated 15-Oct): Can Fin Homes and Tata Capital partial (satellite / "all branches" views not captured); PNB Housing partial (89 of ~356 branches, mostly name/locality only — site refuses automated requests); Nido taken from its Sep-2025 SEBI filing (website refuses automated reading, later changes unseen); Axis Finance page lists 86 in-scope offices incl. non-branch offices (annual report: 72 branches); Toyota Financial publishes only its head office; 12 newest LIC HFL area offices have no address; BRT identity unclear | Coverage for these clients is not calculated; their branches are counted only where listed | Owner may supply client lists (upload) or authorise another source; never filled in by guesswork |
| L30 | Territory rules exist for 36 live locations; 16,782 verified branches fall outside any mapped Crux territory and 80 client × location combinations have no established territory | Those branches are in the master but in no location's coverage | Add district/PIN rules when a location's catchment is confirmed |
| L31 | The monthly monitor reads the IFSC data release published on GitHub (`razorpay/ifsc`), which compiles the RBI lists; if that project stops publishing, the run records "source unchanged" and the master is not refreshed | Stale bank lists after 40 days are flagged as overdue in Data quality | Switch the source URL in `branch-monitor` to the RBI download if needed |
| L32 | Duplicate branches are possible when a client list uploaded before the official source carries a code the official source later lists with a different format (the official monitor adds by exact code) | Rare double count | Review queue; uploads after the official load are matched by normalised code |
| L33 | Name scrubbing for AI calls matches name tokens of Force1 employees, location stakeholders and the HR list; a person not in those lists (e.g. a client contact) typed into a question is not recognised | That name could reach Google inside a question | Questions are business-only by design; do not type client contacts' personal details into Ask Crux |
| L34 | BRT (Pune) cannot be researched until its legal entity is known; candidates found are weak (Bharati Sahakari Bank, Baramati Sahakari Bank, a Bharti group company) | 36 research combinations stay "not researched" | Business to name the entity (SOW Q11) |
| L35 | Four sub-unit locations (two Lucknow/ROUP, two Nagpur) share districts with other units, so no territory rule exists for them | 100 combinations "territory not established"; their branches count under the main unit's territory only | Business to say how the units split (SOW Q12) |
| L36 | Client mapping corrections for Force1-file aliases cannot move past cases (the original label is not stored on case rows); they apply to new uploads | Past Force1 cases keep the old client | Tracker aliases and location aliases do move records from the effective date |
| L37 | A mapping correction moves records dated on/after the effective date only; there is no one-click undo — apply a second correction back to the old target with its own reason | Two history rows for an undo | Preview shows affected records before applying |
| L38 | First opening of a drill-down level after new data takes about 4–7 s (projection, organic and history are calculated); repeat opens are cached until the next data change | Short wait on first click | `bi_082` cut the slowest case from 23 s to 7 s |
| L39 | Case-level Force1 utilisation is measured per location group, so it is blank for a location that shares its group with other locations | Location rows may show "–" for Force1 case % | Open the zone or location group, or use field-visit utilisation |
| L40 | Branch status uses complete months only and Force1 Case Wise coverage of the branch's location group; the current month is not classified yet | A branch that restarted this month still shows its last complete-month status | "This month (Force1)" line shows new / reactivated branches of the current month |
| L41 | Points and cases without an identified location (location-group records) count in totals but not in any location row | Location rows can add up to less than the zone total for TAT and Force1 | Shown as "Not identified" in the TAT section summary |
| L42 | Panels other than Pan India and zones (locations, clients, branches, other months) are calculated on first open (≈3–8 s) and then cached until the next data change | First click on a deep level waits | Warm-up job covers the most-opened panels |

## Finance (21-Oct-2026)
- One outstanding snapshot (as at 15-Oct-2026, inferred from the file date) — trends in the outstanding balance need more snapshots.
- Receipts cover 1-Apr to 13-Oct-2026 only; realisation for invoice months before April 2026 is not measured.
- 4,832 receipts (₹1.69 cr) carry no invoice number and cannot be matched; 1,344 receipt rows (₹58.3 L) have no identifiable location (mostly "Unadj" / blank).
- Amounts whose city is not stated are shown on zone lines (Gujarat Zone, Bhopal MP Zone, Lucknow/ROUP Zone, Rest of Maharashtra Zone, Patna Zone).
- No payment terms, so no "overdue"; age is counted from the end of the invoice month because invoice dates are unreliable.
- Receipts include GST and are after TDS; revenue excludes GST — cash cover is therefore not a realisation rate.
- A receipt that quotes several invoices is matched on the first one (56 cases, listed).

## Growth analytics (22-Oct-2026)
| # | Limitation | Effect | Handling |
|---|---|---|---|
| L20 | Daily reports start Jun-2026 | Month to date cannot be compared with the same point last year until Jun-2027 | Shown as "not available" with the reason; YoY uses full months |
| L21 | Targets exist only from Jun-2026 | No target attainment for earlier months or quarters | Attainment shown only when every month of the period has a target |
| L22 | Locations reporting changed (15 in 2024, 20 in 2025, 36 from Jan-2026) | Reported YoY growth includes new locations | Like-for-like and new/lost pairs shown beside every comparison |
| L23 | Force1 utilisation is per location group | Locations sharing a group show the same value in the pair ranking | Labelled "group" |
| L24 | No HR workforce master | Capacity / availability per pair cannot be shown | Stated in the method; upload in Admin › HR |
| L25 | No verified external competitor or market data | No competitor volumes or market share | Not shown or estimated; opportunity uses verified branch lists and internal peer benchmarks only |
| L26 | Organic estimate error ≈ 5.8 % Pan India, ≈ 21.3 % per location × client (last 10 months, MoM/QoQ/YoY blend from 22-Oct-2026; was 6.7 % / 21.5 %) | Pair-level effort is indicative | Error shown on the page by month; small pairs flagged |
| L27 | First uncached growth request takes 3–5 s | Slower first view after a data change for filtered selections | Pan India pre-computed every 10 minutes; results cached until data changes |

## Revenue-first growth (22-Oct-2026)
| # | Limitation | Effect | Handling |
|---|---|---|---|
| L28 | Invoices are complete only for Mar–Aug 2026 (finance workbooks start Apr-2026; snapshot 15-Oct) | MoM and QTD on actual revenue only; QoQ, YoY, quarter vs last year and YTD on invoices unavailable (YoY from Mar-2027) | Card shows the reason and the expected-minimum benchmark; never substituted |
| L29 | Sep-26 and Oct-26 invoices still being raised at the snapshot date | Not compared | Listed as "in progress" with billed so far and coverage |
| L30 | Gujarat, Bhopal-MP and Lucknow invoices mostly do not name the city | Their locations cannot be ranked separately on revenue | Compared as one billing unit; a location filter inside them lists the unit under "not in totals" |
| L31 | No revenue-recognition rules; invoice date ≠ service date in general | "Actual billed revenue" = invoiced value by invoice month (ex-GST), not recognised revenue | Invoice month used as service month (best-fit evidence in the method); per-case labelled approximate |
| L32 | Revenue organic model: Pan India error 6.4 %, unit × client WAPE 29.6 % (4 back-test months, after the 22-Oct organic blend; was 6.1 % / 29.2 %) | Pair-level growth beyond organic is indicative, noisier than the cases model (21.3 %) | Error, coverage and basis (pair / family / unavailable) shown; unavailable never shown as zero |
| L33 | Some tracker revenue has no identified invoice (Aug-26: 20 unit × client pairs, ₹11.26 L expected minimum) — cause not established (could be billing under another client or location, or not yet invoiced) | Billed below expected for those pairs | Confidence note "no invoices identified" and billing coverage per pair |
| L34 | First uncached revenue growth request takes about 4–10 s (more under concurrent load) | Slower first view after a data change for a new filter | Pan India pre-computed every 10 minutes; cached until data changes |

## Organic blend and branch managers (22-Oct-2026, wave 093)
| # | Limitation | Effect | Handling |
|---|---|---|---|
| L43 | Only 76 % of business has a usable month last year (many locations started or changed since 2025) | The YoY basis covers 76 % of organic cases; the rest use 5/9 MoM + 4/9 QoQ | The explanation states how many rows have a YoY basis; YoY weight kept at 10 % because a larger share back-tested worse |
| L44 | Aug-2026 actual was 13.4 % above the organic estimate (largest monthly miss in the back-test) | Aug effort looks high; Sep growth beyond organic (MoM, cases) looks low — partly an Aug estimate miss rather than a Sep fall-off | Monthly accuracy table in Growth → method; read Sep MoM beyond organic with Aug's miss in mind |
| L45 | The branch-manager list was supplied as free text: two names appear with two spellings, one shared entry is written two ways, one state has two managers listed for one place, and one city has a client-specific manager (BOM) as well as a location manager | Names shown as loaded (one spelling chosen, the other kept in the row note); the client-specific manager wins for that client | Notes on each row in Admin → Master data & mapping; correct there (end / withdraw / add, audited). Open questions are in the SOW |
| L46 | One location has no listed manager, and some invoices are not tied to a location ("Location not identified", a zone office without a dashboard location) | Branch manager shows "not mapped" / "–" | The admin page lists locations without a current manager |
| L47 | Branch manager and stakeholder are mapped responsibility | Not evidence of who caused a change | Stated in drills, Ask answers and the method |

## Branch managers, current month and revenue first (28-Oct-2026, wave 094)
| # | Limitation | Effect | Mitigation |
|---|---|---|---|
| L48 | Billed, collected and outstanding per branch manager are allocations: finance is pooled per billing unit × client family × month and shared to location × client by tracker expected revenue | Per-manager finance is an estimate where a billing unit covers several locations or managers | Totals reconcile exactly (manager rows + "not attributable" = source, tests M3–M5); the drawer and method say "allocated" |
| L49 | 72 % of October receipts to 13-Oct (₹36.6 L of ₹50.9 L) carry no location; Sep-2026 ₹3.2 L likewise; some Aug/Sep invoices (₹1.7 L) are zone-level | Per-manager collections are understated this month | Shown as "not attributable" on the Overview; the Collected column is flagged ⚠ when more than 20 % of the month's receipts cannot be attributed |
| L50 | Receipts bunch late in the month, and the receipt workbook ends 13-Oct while the tracker runs to 24-Oct | Collected-to-date looks low against the previous full month early in a month | The collection card states its own dates and the caveat; upload newer finance workbooks (SOW Q24) |
| L51 | Hand-over shifts compare the same location × client keys before and after a change (up to three completed months each side) with the rest of the business | Association, not cause; one or two months after a change is an early read; several changes on one date share the same keys | Labelled "early read" and "mapped responsibility, not proof of cause"; relative shift removes the business-wide movement |
| L52 | No global branch-manager filter | Pages cannot be filtered to one manager's portfolio from the filter bar | The branch-manager drawer (Overview panel or People) shows each manager's expected revenue, finance, trend, portfolio and hand-overs |
| L53 | The 21-Oct and 22-Oct-2026 tracker files were loaded with every rate empty (revenue present) | The rate column is blank for those dates in the tracker | Revenue unaffected; rate recomputation carries the last stored rate forward (D147); re-upload the two files to fill the column (SOW Q25) |

## Finance identity (28-Oct-2026, wave 095)
L48 and L49 above are superseded: finance is no longer shared out by expected revenue (each line counts whole), and October receipts tied to a location rose from 28 % to 81 % with the paying-branch look-up.
| # | Limitation | Effect | Mitigation |
|---|---|---|---|
| L54 | Invoices whose series covers a whole zone (GUJ, CHH, UP / LUK, AHN) and whose row names no place cannot be tied to one location | ≈ 11 % of Aug-2026 billing (₹23.1 L) and ≈ 8 % of outstanding (₹85.8 L) show as "not attributable" in the branch-manager view (unless the zone has one manager for the client) | Write the location (or branch) in the workbook row, or ask finance to use location-level invoice series |
| L55 | Payer branches outside the territory map take their district / city / state through the case-mapping place rules; a payer branch in another zone than the work is possible (customer paying from elsewhere) | A small share of receipts may sit in the paying branch's location | Receipts that quote an invoice always follow the invoice; the basis is kept on each line (`bi.fin_attr.basis`) |
| L56 | The client of a line is read from the client text; plain family text (e.g. "BOM") goes to the family's largest client at that location | Pre / post or retail variants of one family are not separated unless the text names them | Client text in the workbook decides when present |
| L57 | The full finance rebuild now takes ≈ 40 s; the upload page's immediate rebuild can time out and the scheduled refresh completes it | Figures may take up to 10 minutes to refresh after an upload | The upload result already says "figures refresh within 10 minutes" when the immediate rebuild does not finish |

## Case location, operations, outstanding, roles, graphics, Ask (28-Oct-2026, wave 096)
| # | Limitation | Effect | Mitigation |
|---|---|---|---|
| L58 | The case-location rules read the area office, branch name and residence pincode as typed in Force1; 25 of 236,441 cases have none of them and no file default | Those cases show as "not identified" | Correct the case in Force1 or add a place / branch word in the reference and re-run the relocation |
| L59 | Rule 4 (branch customers' area) and the pincode table can place a case where the customer lives rather than where the bank branch is, when the branch name and area office are empty | A few cases count in a neighbouring location | Change log `bi.case_loc_change` keeps the old and new location and the basis of every move |
| L60 | Ageing counts calendar days (including Sundays and holidays) from the received time to the end of the last reported day | A Monday case open since Saturday is ">1–3 days" | Same rule for every location; TAT keeps its own definition |
| L61 | Outstanding comes from the latest outstanding workbook (15-Oct-2026); "received but not linked" is the workbook's own "Less Unadj" lines | Figures change only when a new workbook is imported | Q24 (newer finance workbooks) |
| L62 | The receipt-identification share and the summary-vs-sheets explanation in Ask Crux are company-wide | With a client or location filter Ask gives the filtered outstanding but not the company-wide gap | The Cash view shows both |
| L63 | Operations handlers and collections owners are not yet entered | Ask's "who handles" lists only branch managers | Q26 |
| L64 | The zone tile map colours zones by distance from the organic level (or likely vs target); zones with under 100 organic cases so far are grey ("too small to compare") | Small zones never show a colour | Value and text are printed on every tile |
| L65 | First names that appear only inside a location label are now replaced by [name] before text reaches the AI provider; the shown answer is unchanged | AI wording may read "Nagpur ([name])" internally | The calculated answer is always shown word for word |

## Identity, reconciliation, operations and roles (29-Oct-2026, wave 097)
| # | Limitation | Effect | Mitigation |
|---|---|---|---|
| L66 | Outstanding lines are stored without the branch, so "invoice numbers in two sheets that look like the same line" is an upper bound | 15-Oct workbook: 11 numbers / ₹25,670 by the stored fields; an independent check with the branch column found 8 identical (₹12,805) and 3 with a different branch text | Confirm in the workbook before correcting it |
| L67 | Ageing and TAT are in calendar days (IST); no working-day ageing | A case received on Saturday is ">1–3 days" on Monday | Stated on the page and in Ask; same rule everywhere |
| L68 | The Amaravati branch-manager hand-over from 26-Oct is inferred from the tracker's team label | Amaravati figures from 26-Oct are shown under the second Nagpur team's manager | Q27 — confirm or withdraw the row |
| L69 | Operations handlers and collections owners are still not entered | The handler column shows "not entered"; Ask lists branch managers only | Q26 lists the records needed |
| L70 | The upload's post-import status line was not exercised end-to-end (no new finance workbook in this wave) | — | It reads the same reconciliation APIs that are tested on the Cash view |
| L71 | The coverage status's code counts are cached with the data version; the monitor status is live | Codes refresh on the next data change, not on every page load | — |
| L72 | Month totals for Aug and Sep-2026 shown between the 26/27-Oct tracker uploads and 29-Oct-2026 06:20 UTC were 349 / 389 cases too high (D187) | Growth, trends and the forecast seen in that window were slightly overstated | Corrected; I16 guards it || L73 | After a data change a figure can be served from the previous data version until the background job recomputes it (normally a minute or two; longer when many requests are queued) | Right after an upload or a mapping save the page may still show the earlier figures | Every figure carries its own as-of date; the queue is visible in `bi.api_cache_queue` |
| L74 | Free-plan (Nano) instance: disk IO bursts only for a short time each day, then runs at 5 MB/s and 250 IOPS. A day of heavy work (bulk saves, full test runs, refresh cascades) exhausts the burst and everything slows sharply | 29-Oct outage (SOW incident) | Pro plan / compute upgrade (Q19); background jobs one at a time |

