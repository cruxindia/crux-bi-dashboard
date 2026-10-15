-- Applied to Supabase project via MCP on 20261015003328
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'bi-warm-drill-cache') then
    perform cron.schedule('bi-warm-drill-cache', '5-59/10 * * * *', $c$set statement_timeout = '290s'; select bi.warm_drill_cache(240)$c$);
  end if;
end $$;
