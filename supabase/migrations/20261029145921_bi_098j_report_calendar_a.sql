-- Applied to Supabase project via MCP on 20261029145921
-- Wave 098 (owner 29-Oct-2026): admins mark days without a tracker report, past or future, with a reason from a list.
-- Holiday-type reasons are not working days; "report missing" reasons stay working days. Withdrawn entries are kept (active = false).
alter table bi.report_calendar_exception
  add column if not exists reason_code text,
  add column if not exists working_day boolean not null default false,
  add column if not exists note text,
  add column if not exists active boolean not null default true,
  add column if not exists withdrawn_by text,
  add column if not exists withdrawn_at timestamptz;

create or replace function bi.report_calendar_reasons()
returns jsonb language sql immutable as $f$
  select '[{"code":"public_holiday","label":"Public holiday","working_day":false},
           {"code":"company_holiday","label":"Company holiday / office closed","working_day":false},
           {"code":"festival_leave","label":"Festival / team on leave","working_day":false},
           {"code":"strike_closure","label":"Strike, bandh or local closure","working_day":false},
           {"code":"weekly_off","label":"Weekly off (other than Sunday)","working_day":false},
           {"code":"other_closed","label":"Other — office closed","working_day":false},
           {"code":"report_not_received","label":"Business done, tracker not received","working_day":true},
           {"code":"system_issue","label":"System or upload problem","working_day":true},
           {"code":"other_open","label":"Other — office open, report missing","working_day":true}]'::jsonb
$f$;

create or replace function bi.workdays(d1 date, d2 date)
returns integer language sql stable set search_path to 'bi', 'public' as $f$
  select count(*)::int from generate_series(d1, d2, interval '1 day') g
   where extract(isodow from g) <> 7
     and not exists (select 1 from bi.report_calendar_exception e where e.report_date = g::date and e.active and not e.working_day)
$f$;
comment on function bi.workdays(date, date) is 'Wave 098: Monday to Saturday minus active non-working report-calendar days.';
