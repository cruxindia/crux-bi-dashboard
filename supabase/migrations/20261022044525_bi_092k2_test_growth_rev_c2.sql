-- Applied to Supabase project via MCP on 20261022044525
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.test_growth_rev(date)'::regprocedure);
  o := $o$       a as (select v.location_id, coalesce(cl.family, v.client_code) fam, v.month, sum(v.cases) cs from bi.v_month_business v join bi.location l on l.id = v.location_id and not coalesce(l.is_rollup, false)
             left join bi.client cl on cl.code = v.client_code where v.month in ((GC->>'completed_month')::date, ((GC->>'completed_month')::date - interval '1 month')::date) group by 1, 2, 3),
       cov as (select location_id, fam from o group by 1, 2 having count(*) = 2
               intersect select location_id, fam from a group by 1, 2)$o$;
  n := $n$       -- a pair is compared when it had cases in at least one of the two months (a pair idle in both is not part of this comparison)
       a as (select v.location_id, coalesce(cl.family, v.client_code) fam from bi.v_month_business v join bi.location l on l.id = v.location_id and not coalesce(l.is_rollup, false)
             left join bi.client cl on cl.code = v.client_code where v.month in ((GC->>'completed_month')::date, ((GC->>'completed_month')::date - interval '1 month')::date)
             group by 1, 2 having coalesce(sum(v.cases), 0) > 0),
       cov as (select location_id, fam from o group by 1, 2 having count(*) = 2
               intersect select location_id, fam from a)$n$;
  if position(o in d) = 0 then raise exception 'C2 fragment not found'; end if;
  execute replace(d, o, n);
end $do$;
