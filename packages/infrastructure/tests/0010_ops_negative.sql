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

  if (v_report ->> 'schema_migrations')::integer < 8 then
    raise exception 'FAIL HEALTH: تعداد Migration در گزارش کم است';
  end if;
  raise notice 'PASS HEALTH | گزارش با مجوز و محتوای صف/نشست/Job';
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
