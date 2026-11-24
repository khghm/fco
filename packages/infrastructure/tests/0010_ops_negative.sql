-- =============================================================================
-- 0010_ops_negative — BR-1 گام ۹
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4/§6
--   (T-DR-01 بازیابی، Job یک‌بار در slot، مجوز پایش)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0010_ops_negative.sql
--
-- پوشش: یک‌باری Job در slot، پایان دوباره، اندازه دسته، حذف فقط نشست منقضی،
--       idempotency پاک‌سازی، گزارش سلامت با/بدون مجوز و محتوای صف.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('99999999-9999-9999-9999-999999999999', '09120000091', 'مدیر سیستم آزمون رصد', 'active', 'fixture-hash-0091'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '09120000092', 'اپراتور بدون مجوز رصد', 'active', 'fixture-hash-0092');

insert into iam.user_roles (user_id, role_id)
select '99999999-9999-9999-9999-999999999999'::uuid, id from iam.roles where key = 'R-SYS';
insert into iam.user_roles (user_id, role_id)
select 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, id from iam.roles where key = 'R-OP';

-- --- Job: یک‌بار در هر slot ------------------------------------------------
do $$
declare v_run bigint; v_second bigint;
begin
  v_run := sys.job_begin('session_cleanup', '2026-11-24 10:00:00+00');
  if v_run is null then
    raise exception 'FAIL JOB: شروع اول NULL داد';
  end if;

  v_second := sys.job_begin('session_cleanup', '2026-11-24 10:00:00+00');
  if v_second is not null then
    raise exception 'FAIL JOB: همان slot دو بار شروع شد';
  end if;
  raise notice 'PASS JOB | هر slot یک‌بار شروع می‌شود';

  perform sys.job_finish(v_run, 'succeeded');

  begin
    perform sys.job_finish(v_run, 'succeeded');
    raise exception 'FAIL JOB: پایان دوباره پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1040%' then
      raise exception 'FAIL JOB: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS JOB | پایان دوباره → %', sqlerrm;
  end;

  begin
    perform sys.job_begin('   ');
    raise exception 'FAIL JOB: نام خالی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS JOB | نام خالی → %', sqlerrm;
  end;
end $$;

-- --- تلاش دوباره همان slot پس از شکست ---------------------------------------
do $$
declare v_run bigint; v_retry bigint; v_attempt integer; v_status text;
begin
  v_run := sys.job_begin('session_cleanup', '2026-11-24 12:00:00+00');
  if v_run is null then
    raise exception 'FAIL RETRY: شروع اول NULL داد';
  end if;

  perform sys.job_finish(v_run, 'failed', 'db timeout');

  v_retry := sys.job_begin('session_cleanup', '2026-11-24 12:00:00+00');
  if v_retry is null then
    raise exception 'FAIL RETRY: slot شکست‌خورده دوباره باز نشد';
  end if;
  if v_retry <> v_run then
    raise exception 'FAIL RETRY: رکورد جدید ساخته شد (%)، انتظار همان رکورد (%)', v_retry, v_run;
  end if;

  select attempt, status into v_attempt, v_status from sys.job_runs where id = v_run;
  if v_attempt <> 2 or v_status <> 'running' then
    raise exception 'FAIL RETRY: attempt=% status=%', v_attempt, v_status;
  end if;
  raise notice 'PASS RETRY | همان slot با attempt=2 دوباره running شد';

  -- در حال اجرا: شروع دوباره نباید بدهد
  if sys.job_begin('session_cleanup', '2026-11-24 12:00:00+00') is not null then
    raise exception 'FAIL RETRY: slot در حال اجرا دوباره شروع شد';
  end if;
  raise notice 'PASS RETRY | slot در حال اجرا دوباره شروع نشد';

  perform sys.job_finish(v_run, 'succeeded');
  if sys.job_begin('session_cleanup', '2026-11-24 12:00:00+00') is not null then
    raise exception 'FAIL RETRY: slot موفق دوباره باز شد';
  end if;
  raise notice 'PASS RETRY | slot موفق دوباره باز نشد';
end $$;

-- --- پاک‌سازی نشست: فقط منقضی/باطل قدیمی --------------------------------
do $$
declare
  v_purged integer;
  v_active integer;
  v_run    record;
  v_again  record;
begin
  -- نشست فعال (باید بماند)
  insert into iam.sessions (user_id, token_hash, created_at, expires_at)
  values ('99999999-9999-9999-9999-999999999999'::uuid,
          decode(repeat('a1', 32), 'hex'), now(), now() + interval '8 hours');

  -- نشست منقضی قدیمی (باید حذف شود)
  insert into iam.sessions (user_id, token_hash, created_at, expires_at)
  values ('99999999-9999-9999-9999-999999999999'::uuid,
          decode(repeat('a2', 32), 'hex'),
          now() - interval '10 days', now() - interval '9 days');

  -- نشست باطل‌شده اخیر (در grace، باید بماند)
  insert into iam.sessions (user_id, token_hash, created_at, expires_at, revoked_at, revoke_reason)
  values ('99999999-9999-9999-9999-999999999999'::uuid,
          decode(repeat('a3', 32), 'hex'),
          now() - interval '1 hour', now() + interval '7 hours',
          now() - interval '1 hour', 'logout');

  -- منقضیِ دیروز (برای آزمون idempotency Job)
  insert into iam.sessions (user_id, token_hash, created_at, expires_at)
  values ('99999999-9999-9999-9999-999999999999'::uuid,
          decode(repeat('a4', 32), 'hex'),
          now() - interval '2 days', now() - interval '1 day');

  v_purged := sys.purge_expired_sessions(10);
  if v_purged <> 1 then
    raise exception 'FAIL CLEANUP: % نشست حذف شد، انتظار ۱', v_purged;
  end if;

  select count(*) into v_active from iam.sessions
   where token_hash in (decode(repeat('a1', 32), 'hex'), decode(repeat('a3', 32), 'hex'));
  if v_active <> 2 then
    raise exception 'FAIL CLEANUP: نشست فعال/در grace حذف شد (%)', v_active;
  end if;
  raise notice 'PASS CLEANUP | فقط نشست منقضی قدیمی حذف شد';

  -- Job روی slot: یک بار ran، بار دوم already_ran
  insert into iam.sessions (user_id, token_hash, created_at, expires_at)
  values ('99999999-9999-9999-9999-999999999999'::uuid,
          decode(repeat('a5', 32), 'hex'),
          now() - interval '3 days', now() - interval '2 days');

  select * into v_run from sys.run_session_cleanup('2026-11-24 11:00:00+00', 10);
  if v_run.outcome <> 'ran' or v_run.purged <> 1 then
    raise exception 'FAIL CLEANUP: اجرای Job %/% بود، انتظار ran/1', v_run.outcome, v_run.purged;
  end if;

  select * into v_again from sys.run_session_cleanup('2026-11-24 11:00:00+00', 10);
  if v_again.outcome <> 'already_ran' or v_again.purged <> 0 then
    raise exception 'FAIL CLEANUP: اجرای دوباره %/% بود', v_again.outcome, v_again.purged;
  end if;
  raise notice 'PASS CLEANUP | Job یک‌بار ran شد و دوباره already_ran';

  begin
    perform sys.purge_expired_sessions(0);
    raise exception 'FAIL CLEANUP: اندازه دسته ۰ پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS CLEANUP | دسته نامعتبر → %', sqlerrm;
  end;
end $$;

-- --- گزارش سلامت: مجوز و محتوا ------------------------------------------
do $$
declare v_report jsonb; v_pending bigint;
begin
  begin
    perform sys.health_report('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid);
    raise exception 'FAIL HEALTH: گزارش بدون مجوز خوانده شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL HEALTH: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS HEALTH | بدون platform.health.read → %', sqlerrm;
  end;

  perform sys.outbox_emit('order', gen_random_uuid(), 'order.health',
                          '{"probe":true}'::jsonb);

  v_report := sys.health_report('99999999-9999-9999-9999-999999999999'::uuid);

  if v_report -> 'queue' ->> 'pending' is null then
    raise exception 'FAIL HEALTH: بخش queue در گزارش نیست';
  end if;

  v_pending := (v_report -> 'queue' ->> 'pending')::bigint;
  if v_pending < 1 then
    raise exception 'FAIL HEALTH: صف با رویداد در انتظار، pending=%', v_pending;
  end if;

  if (v_report -> 'queue' ->> 'oldest_pending_seconds')::integer < 0 then
    raise exception 'FAIL HEALTH: سن صف منفی شد';
  end if;

  if (v_report ->> 'schema_migrations')::integer < 10 then
    raise exception 'FAIL HEALTH: تعداد Migration در گزارش کم است';
  end if;
  raise notice 'PASS HEALTH | گزارش با مجوز و محتوای صف/نشست/Job';
end $$;

-- --- سقف تلاش در همان slot -------------------------------------------------
do $$
declare
  v_run bigint;
  v_cap integer := sys.setting_int('job.max_attempts');
  v_i   integer;
begin
  v_run := sys.job_begin('retry_cap_probe', '2026-11-24 13:00:00+00');
  if v_run is null then
    raise exception 'FAIL CAP: شروع اول NULL داد';
  end if;

  for v_i in 1..v_cap loop
    perform sys.job_finish(v_run, 'failed', 'boom ' || v_i);
    exit when v_i = v_cap;
    v_run := sys.job_begin('retry_cap_probe', '2026-11-24 13:00:00+00');
    if v_run is null then
      raise exception 'FAIL CAP: تلاش % باز نشد', v_i + 1;
    end if;
  end loop;

  begin
    perform sys.job_begin('retry_cap_probe', '2026-11-24 13:00:00+00');
    raise exception 'FAIL CAP: تلاش بیش از سقف % پذیرفته شد', v_cap;
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1042%' then
      raise exception 'FAIL CAP: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS CAP | سقف % تلاش → %', v_cap, sqlerrm;
  end;
end $$;

-- --- شکست Job پاک‌سازی ثبت می‌شود و همان slot باز می‌ماند ---------------------
do $$
declare v_res record; v_attempt integer;
begin
  select * into v_res from sys.run_session_cleanup('2026-11-24 14:00:00+00', 0);
  if v_res.outcome <> 'failed' or v_res.run_id is null then
    raise exception 'FAIL CLEANUP: شکست ثبت نشد (outcome=%)', v_res.outcome;
  end if;

  select attempt into v_attempt from sys.job_runs where id = v_res.run_id;
  if v_attempt <> 1 then
    raise exception 'FAIL CLEANUP: attempt شکست‌خورده = %، انتطار ۱', v_attempt;
  end if;
  raise notice 'PASS CLEANUP | شکست Job با outcome=failed ثبت شد';

  select * into v_res from sys.run_session_cleanup('2026-11-24 14:00:00+00', 10);
  if v_res.outcome <> 'ran' then
    raise exception 'FAIL CLEANUP: تلاش دوباره outcome=%', v_res.outcome;
  end if;
  select attempt into v_attempt from sys.job_runs where id = v_res.run_id;
  if v_attempt <> 2 then
    raise exception 'FAIL CLEANUP: attempt پس از تلاش دوباره = %، انتطار ۲', v_attempt;
  end if;
  raise notice 'PASS CLEANUP | تلاش دوباره همان slot ran شد (attempt=2)';
end $$;

-- --- گزارش سلامت: Job گیرکرده و تلاش تمام‌شده -------------------------------
do $$
declare v_report jsonb; v_found boolean;
begin
  insert into sys.job_runs (job_name, scheduled_for, started_at)
  values ('stuck_probe', '2026-11-24 09:00:00+00', now() - interval '2 hours');

  v_report := sys.health_report('99999999-9999-9999-9999-999999999999'::uuid);

  if (v_report -> 'jobs' ->> 'stuck')::integer < 1 then
    raise exception 'FAIL HEALTH: Job گیرکرده شمرده نشد (%)', v_report -> 'jobs' ->> 'stuck';
  end if;

  select exists (
    select 1 from jsonb_array_elements(v_report -> 'jobs' -> 'stuck_runs') e
     where e ->> 'job_name' = 'stuck_probe'
  ) into v_found;
  if not v_found then
    raise exception 'FAIL HEALTH: stuck_runs شامل stuck_probe نیست: %',
      v_report -> 'jobs' -> 'stuck_runs';
  end if;
  raise notice 'PASS HEALTH | Job گیرکرده در stuck/stuck_runs دیده شد';

  if (v_report -> 'jobs' ->> 'exhausted_24h')::integer < 1 then
    raise exception 'FAIL HEALTH: تلاش تمام‌شده شمرده نشد (%)',
      v_report -> 'jobs' ->> 'exhausted_24h';
  end if;
  raise notice 'PASS HEALTH | Job با تلاش تمام‌شده در exhausted_24h دیده شد';
end $$;

-- --- اپ: حذف مستقیم نشست ممنوع -----------------------------------------
set local role fco_app;

do $$
begin
  begin
    delete from iam.sessions;
    raise exception 'FAIL APP-ROLE: حذف مستقیم نشست مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | حذف مستقیم نشست مسدود شد';
  end;

  perform sys.purge_expired_sessions(10);
  raise notice 'PASS APP-ROLE | پاک‌سازی فقط از مسیر تابع کار کرد';
end $$;

reset role;

select 'ALL STEP-9 NEGATIVE CASES PASSED' as result;
rollback;
