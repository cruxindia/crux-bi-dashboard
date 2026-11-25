-- Applied to Supabase project via MCP on 20261121075808
-- wave 119e: for the months the latest sales register covers, billed revenue = the register only. An invoice seen in the outstanding ledger or a receipt but
-- not in the register (typo in a receipt, another entity, a cancelled invoice) no longer adds to billed revenue of those months; it stays in the traced value
-- (realisation unchanged) and is reported as "not in the register" (fin_inv_month.nreg_basic).
alter table bi.fin_inv_month add column if not exists nreg_basic numeric;
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '119e');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.fin_derive(text)'::regprocedure, array[
  $r$v_sr bigint; v_ua bigint;$r$, $r$v_sr bigint; v_ua bigint; v_rf date; v_rt date;$r$,
  $r$  select id into v_ua from bi.fin_upload where kind = 'unadjusted'$r$,
  $r$  select period_from, period_to into v_rf, v_rt from bi.fin_upload where id = v_sr;   -- wave 119e: months the register covers
  select id into v_ua from bi.fin_upload where kind = 'unadjusted'$r$,
  $r$               coalesce(sk.basic, ok.basic, rk.basic, 0) basic,$r$,
  $r$               case when sk.inv_key is null and v_sr is not null and coalesce(ok.im, rk.im) between v_rf and v_rt then 0 else coalesce(sk.basic, ok.basic, rk.basic, 0) end basic,
               case when sk.inv_key is null and v_sr is not null and coalesce(ok.im, rk.im) between v_rf and v_rt then coalesce(ok.basic, rk.basic, 0) else 0 end nreg_basic,$r$,
  $r$traced_basic, reg_basic, reg_n, untraced_basic, untraced_n, reg_open_basic)$r$, $r$traced_basic, reg_basic, reg_n, untraced_basic, untraced_n, reg_open_basic, nreg_basic)$r$,
  $r$count(*) filter (where in_register and not in_ledger and not in_receipts), sum(reg_open)$r$, $r$count(*) filter (where in_register and not in_ledger and not in_receipts), sum(reg_open), sum(nreg_basic)$r$,
  $r$untraced_basic = excluded.untraced_basic, untraced_n = excluded.untraced_n, reg_open_basic = excluded.reg_open_basic$r$,
  $r$untraced_basic = excluded.untraced_basic, untraced_n = excluded.untraced_n, reg_open_basic = excluded.reg_open_basic, nreg_basic = excluded.nreg_basic$r$,
  $r$traced_basic = 0, reg_basic = 0, reg_n = 0, untraced_basic = 0, untraced_n = 0, reg_open_basic = 0$r$,
  $r$traced_basic = 0, reg_basic = 0, reg_n = 0, untraced_basic = 0, untraced_n = 0, reg_open_basic = 0, nreg_basic = 0$r$], array[1, 1, 1, 1, 1, 1, 1]);
select pg_temp.patch('bi.fin_attr_refresh(bigint,bigint[])'::regprocedure, array[
  $r$v_sr bigint; v_run bigint$r$, $r$v_sr bigint; v_rf date; v_rt date; v_run bigint$r$,
  $r$  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;$r$,
  $r$  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;
  select period_from, period_to into v_rf, v_rt from bi.fin_upload where id = v_sr;$r$,
  $r$coalesce(ok.im, sk.im, rk.im) im, coalesce(sk.basic, ok.basic, rk.basic, 0) basic,$r$,
  $r$coalesce(ok.im, sk.im, rk.im) im,
                            case when sk.inv_key is null and v_sr is not null and coalesce(ok.im, rk.im) between v_rf and v_rt then 0 else coalesce(sk.basic, ok.basic, rk.basic, 0) end basic,$r$], array[1, 1, 1]);
select pg_temp.patch('bi.api_fin_sources(jsonb)'::regprocedure, array[
  $r$sum(i.reg_open_basic) reg_open, sum(i.open_basic) ledger_open, sum(i.settled_basic) settled, sum(i.basic) billed$r$,
  $r$sum(i.reg_open_basic) reg_open, sum(i.open_basic) ledger_open, sum(i.settled_basic) settled, sum(i.basic) billed, sum(coalesce(i.nreg_basic, 0)) nreg$r$,
  $r$'open_per_register', (select round(sum(reg_open)) from reg), 'open_per_ledger', (select round(sum(ledger_open)) from reg),$r$,
  $r$'open_per_register', (select round(sum(reg_open)) from reg), 'open_per_ledger', (select round(sum(ledger_open)) from reg),
        'traced_not_in_register', (select round(sum(nreg)) from reg),$r$,
  $r$'settled', round(settled), 'open_per_ledger', round(ledger_open), 'open_per_register', round(reg_open),$r$,
  $r$'settled', round(settled), 'open_per_ledger', round(ledger_open), 'open_per_register', round(reg_open), 'traced_not_in_register', round(nreg),$r$], array[1, 1, 1]);
-- rebuild now (data changed: the rule)
insert into bi.fin_config (key, value, note, updated_by, updated_at) values ('register_months_register_only', 'true'::jsonb, 'wave 119e: billed revenue of register months = the register only', 'wave 119e', now())
on conflict (key) do update set value = excluded.value, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
