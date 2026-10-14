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
| L8 | Storage: DB 341 MB of 500 MB on 14-Oct evening (388 MB before VACUUM FULL). Point Wise adds ~110k points ≈ 40 MB/month | ~4 months of headroom | Decide before Feb-2027: archive points older than 18 months, or move to Supabase Pro (8 GB) |
| L9 | Dashboard is public (anyone with the link can read business figures and employee names) | Business decision | `noindex`; rotate the link by renaming the repo if it leaks; admin functions need the key |
| L13 | Anonymous API calls can be repeated by anyone (no rate limit) | Possible load spikes | Result cache absorbs repeats; Supabase rate limits apply |
| L10 | Browser upload uses SheetJS 0.20.3 (inlined in artifact build) | — | Keep pinned; files from trusted internal sources only |
| L11 | 1-Jul, 1-Sep, 1-Oct snapshots have no targets yet; 6–17 Jul and 1/3/4/5-Sep source totals disagree with leaf rows | Pan-India totals in those files unreliable | Leaf rows used; mismatches logged |
| L12 | Udyam classification conflicts with brief | Possible misclassification of 1,189 points | Admin review in Data quality |
| L15 | No verified client branch list uploaded yet | Branch lifecycle covers only branches seen in Force1; coverage % and never-activated list show a banner | **Ready for data:** Data quality → Master data → Client branch master (template, check, import) |
| L16 | No workforce list (joining/exit dates) uploaded yet | People → Headcount & attrition shows a banner | **Ready for data:** Data quality → Master data → Workforce master. People are matched to Point Wise by name unless names are spelt the same way, so workload links may be partial |
| L17 | Ask Crux narrative needs GEMINI_API_KEY (not set) | Answers are the deterministic SQL text | Set the Edge Function secret; budget cap via GEMINI_DAILY_CAP |
| L18 | ~~Interrupted loader batches #361/#366~~ | Resolved 14-Oct (marked rejected, staging rows cleared) | — |
| L19 | Tracker replica recomputes subtotals from leaf rows; the source BD-revenue/Shortfall (J/K) totals use broken ranges (e.g. Mumbai+Goa BD ₹2,400 vs ₹1,200) | Small differences in J/K totals only; all target/MTD/revenue totals match | Fix the Excel formulas or accept dashboard values |
| L21 | Master uploads are additive (upsert); a branch or person wrongly uploaded cannot be removed from the dashboard | Wrong rows persist | Re-upload with status `closed`/`ineligible` (branches) or an exit date (people); deletion needs a governed admin function if required |
| L23 | Organic seasonality is by calendar month (Pan India). Festivals that move between months (Diwali: 1-Nov-2024, 20-Oct-2025, 8-Nov-2026) shift business between October and November | Organic can be off by ~10–20% in Oct/Nov (e.g. Nov-2025 effort shows +44%) | Read Oct/Nov effort with care; a festival-calendar adjustment can be added with the market-events agent |
| L24 | Organic needs 3 complete prior months for a location × client; brand-new rows have organic 0 (all business = effort / new business) | Correct by definition but large % for new rows | Shown as "New business" |
| L25 | Branch evidence behind effort covers Force1 case reports only (not every location) | Partial attribution | Labelled on screen |
| L26 | First page load after each data change computes the new figures (Overview up to ~15–20 s once); later loads are cached | One slow load per change | Acceptable; pre-warming can be added |
| L27 | Retired invoice app tables (now empty-of-access, ~20 MB) remain until the owner runs `remove_old_invoice_app.sql`; the connector used here cannot run DROP/TRUNCATE | ~20 MB of database space | Run the script once (OPERATIONS.md) |
| L22 | One person without an employee ID in one upload and with it in another becomes two records | Headcount overstated | Always include employee_id |
| L20 | Daily update rows come from the latest tracker snapshot; a brand-new location or client row still needs one full tracker upload. Back-dating a date that falls before a label change (e.g. 2-Oct) may need a full-file upload instead | — | Add row management to the entry table if structure changes often |
