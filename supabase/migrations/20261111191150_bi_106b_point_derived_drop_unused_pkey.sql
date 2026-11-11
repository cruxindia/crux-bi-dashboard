-- Applied to Supabase project via MCP on 20261111191150
-- wave 106b (SOW D313, night window 12-Nov-2026 00:45 IST): storage under the 500 MB free-plan quota without a paid plan.
-- point_derived_pkey (PRIMARY KEY (point_id), 24.5 MB) has 0 index scans; bi.refresh_point_derived() rebuilds the table with truncate + insert
-- from bi.point_store (whose point_id is already unique), no foreign key references it, no ON CONFLICT uses it (checked), and the table is not published.
-- To restore if ever needed:  alter table bi.point_derived add constraint point_derived_pkey primary key (point_id);
alter table bi.point_derived drop constraint if exists point_derived_pkey;
