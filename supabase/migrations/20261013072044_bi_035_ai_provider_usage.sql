-- Applied to Supabase project via MCP on 20261013072044

create table if not exists bi.ai_provider_usage (id bigserial primary key, at timestamptz default now(), provider text, model text, purpose text,
  message_id bigint, ok boolean, ms int, input_chars int, output_chars int, note text);
alter table bi.ai_provider_usage enable row level security;
create or replace function public.bi_ai_record(p jsonb) returns jsonb language plpgsql security definer set search_path=bi,public as $$
declare cap int := coalesce(nullif(p->>'daily_cap','')::int, 200); used int;
begin
  if p->>'op' = 'budget' then
    select count(*) into used from bi.ai_provider_usage where provider=p->>'provider' and at > date_trunc('day', now());
    return jsonb_build_object('ok', used < cap, 'used', used, 'cap', cap);
  end if;
  insert into bi.ai_provider_usage(provider,model,purpose,message_id,ok,ms,input_chars,output_chars,note)
  values (p->>'provider',p->>'model',p->>'purpose',nullif(p->>'message_id','')::bigint,(p->>'ok')::boolean,(p->>'ms')::int,(p->>'in')::int,(p->>'out')::int,left(p->>'note',300));
  if (p->>'ok')::boolean and p->>'message_id' is not null then
    update bi.ai_message set provider=p->>'provider', model=p->>'model', answer = answer || jsonb_build_object('narrative', p->>'narrative') where id=(p->>'message_id')::bigint;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.bi_ai_record(jsonb) from public, anon, authenticated;
grant execute on function public.bi_ai_record(jsonb) to service_role;

