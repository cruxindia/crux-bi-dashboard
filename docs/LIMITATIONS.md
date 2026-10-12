# Known limitations register

| # | Limitation | Impact | Mitigation / next step |
|---|---|---|---|
| L1 | Point Wise ends Jul-2026; Case Wise ends Oct-2026 (some groups earlier: Odisha, Lucknow, Kolhapur Jul; Kolkata Apr; Mumbai Sep) | Field/document TAT unavailable Aug–Oct | Upload newer Point Wise files; freshness shown per group in the UI |
| L2 | No Case Wise files for Amaravati, Jalgaon, Solapur, Nanded, Punjab (partly), Bihar/Patna, Goa (via Mumbai only) | ~4,100 Oct cases cannot be compared with Force | Shown as "not received", never as 0% Force |
| L3 | Case Wise cannot distinguish BOM MSME PRE/POST, SBI Car Loan+ | Force usage only at client-family level | Need a product/sub-client field in Force export |
| L4 | Route is rule-based (D17), not an explicit source flag | Manual share may be overstated if back-office staff submit field points in-app | Validate with Ops; a Force submission-channel flag would make it exact |
| L5 | Tracker expense block (L/M/N) inconsistent; "YTD" is not YTD | Expense metrics not used in KPIs | Business to define; values preserved raw |
| L6 | Historical tracker targets not in source | No historical achievement % | — |
| L7 | 2,425 negative case TATs (mostly Guwahati), 1,353 points without a Case Wise case | Excluded / counted at point level only | Logged in `bi.dq_exception` |
| L8 | Supabase free tier 500 MB; DB now ~195 MB after compaction; Point Wise adds ~15 MB/month | ~1.5–2 years of headroom | Monitor in Data quality; archive points older than 24 months if needed |
| L9 | Dashboard is public (anyone with the link can read business figures and employee names) | Business decision | `noindex`; rotate the link by renaming the repo if it leaks; admin functions need the key |
| L13 | Anonymous API calls can be repeated by anyone (no rate limit) | Possible load spikes | Result cache absorbs repeats; Supabase rate limits apply |
| L10 | Browser upload uses SheetJS 0.20.3 (inlined in artifact build) | — | Keep pinned; files from trusted internal sources only |
| L11 | 1-Jul, 1-Sep, 1-Oct snapshots have no targets yet; 6–17 Jul and 1/3/4/5-Sep source totals disagree with leaf rows | Pan-India totals in those files unreliable | Leaf rows used; mismatches logged |
| L12 | Udyam classification conflicts with brief | Possible misclassification of 1,189 points | Admin review in Data quality |
