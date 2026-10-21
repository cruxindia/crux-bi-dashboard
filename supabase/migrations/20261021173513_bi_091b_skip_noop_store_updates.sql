-- Applied to Supabase project via MCP on 20261021173513
-- bi_091b: stop rewriting unchanged Force1 rows on re-import (storage churn fix).
-- Root cause (measured 21-Oct-2026): commit_point / commit_case / relocate_cases re-write every row of a
-- re-imported file even when nothing changed — 2 new row versions per unchanged point, 3 per unchanged case.
-- Fix: a BEFORE UPDATE row trigger that skips an update when no stored value other than last_batch changes.
-- Stored business values are identical to before. last_batch now records the batch that last CHANGED a row.
-- Rollback (no data impact): alter table bi.point_store disable trigger zz_skip_noop_update;
--                            alter table bi.case_store  disable trigger zz_skip_noop_update;
create or replace function bi.trg_skip_noop_update() returns trigger
language plpgsql set search_path to 'bi', 'public' as $$
begin
  -- created_month / received_month are generated columns: NULL in NEW inside a BEFORE trigger, and derived
  -- from created_at / received_at, which are compared.
  if (to_jsonb(new) - 'last_batch' - 'created_month' - 'received_month')
   = (to_jsonb(old) - 'last_batch' - 'created_month' - 'received_month') then
    return null;   -- nothing but the batch stamp would change: keep the existing row version
  end if;
  return new;
end $$;
comment on function bi.trg_skip_noop_update() is
  'bi_091b: skips UPDATEs on point_store/case_store that would only change last_batch (storage churn fix).';
create trigger zz_skip_noop_update before update on bi.point_store
  for each row execute function bi.trg_skip_noop_update();
create trigger zz_skip_noop_update before update on bi.case_store
  for each row execute function bi.trg_skip_noop_update();
