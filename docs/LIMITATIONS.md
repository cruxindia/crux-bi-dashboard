# Known limitations register

| # | Limitation | Impact | Mitigation / next step |
|---|---|---|---|
| L1 | Point Wise ends Jul-2026; Case Wise ends Oct-2026 (some groups earlier: Odisha, Lucknow, Kolhapur Jul; Kolkata Apr; Mumbai Sep) | Field/document TAT unavailable Aug–Oct | Upload newer Point Wise files; freshness shown per group in the UI |
| L2 | No Case Wise files for Amaravati, Jalgaon, Solapur, Nanded, Punjab (partly), Bihar/Patna, Goa (via Mumbai only) | ~4,100 Oct cases cannot be compared with Force | Shown as "not received", never as 0% Force |
| L3 | Case Wise cannot distinguish BOM MSME PRE/POST, SBI Car Loan+ | Force usage only at client-family level | Need a product/sub-client field in Force export |
| L4 | No explicit "processed outside Force" flag | Outside-Force field work cannot be measured; route is inferred | Ask Force team for submission-channel/device flag |
| L5 | Tracker expense block (L/M/N) inconsistent; "YTD" is not YTD | Expense metrics not used in KPIs | Business to define; values preserved raw |
| L6 | Historical tracker targets not in source | No historical achievement % | — |
| L7 | 2,425 negative case TATs (mostly Guwahati), 1,353 points without a Case Wise case | Excluded / counted at point level only | Logged in `bi.dq_exception` |
| L8 | Supabase free tier: DB 401 MB of 500 MB; Point Wise grows ~40 MB/month | Will hit the cap within ~2–3 months | Upgrade to Pro, or archive raw point columns older than 12 months |
| L9 | GitHub Pages unavailable for private repos on the free plan | No public-host deployment yet | Options in OPERATIONS.md |
| L10 | Browser upload uses SheetJS 0.20.3 (inlined in artifact build) | — | Keep pinned; files from trusted internal sources only |
| L11 | 1-Jul, 1-Sep, 1-Oct snapshots have no targets yet; 6–17 Jul and 1/3/4/5-Sep source totals disagree with leaf rows | Pan-India totals in those files unreliable | Leaf rows used; mismatches logged |
| L12 | Udyam classification conflicts with brief | Possible misclassification of 1,189 points | Admin review in Data quality |
