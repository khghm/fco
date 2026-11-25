-- =============================================================================
-- m1_chain.sql — Milestone M1: زنجیره کامل روی دیتابیس یکبارمصرف
-- مالک انتظارها: docs/Engineering-04/IMPLEMENTATION_START_PLAN.md §4 و §5.۱۱
--                docs/Engineering-04/TEST_STRATEGY.md §6 (T-M1-01)
--
-- زنجیره: ورود کارمند با مجوز محدود → ثبت Audit → اجرای Job (Outbox Worker)
--         → شکست تا DLQ → (بازیابی از پشتیبان در scripts/m1-chain.sh)
--
-- این فایل با نقش اپ `fco_app` اجرا می‌شود، نه مالک schema؛ هر عملیات از
-- مسیر تابع امنیتی می‌گذرد. هر گام یک آزمون منفی دارد و نبود گارد = خطا.
-- اجرا: bash scripts/m1-chain.sh  (این فایل مستقیم اجرا نمی‌شود)
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

-- -----------------------------------------------------------------------------
-- داده ثابت سناریو (فقط روی دیتابیس یکبارمصرف؛ هرگز در `fco` اجرا نمی‌شود)
-- -----------------------------------------------------------------------------
insert into iam.users (id, mobile, full_name, email, status, password_hash) values
  ('11111111-1111-1111-1111-111111111111', '09121110001', 'اپراتور انبار M1',
   'op.m1@example.test', 'active',
   '$2b$12$m1fixtureHashNotUsedBySqlChain0000000000000000000000000000'),
  ('11111111-1111-1111-1111-111111111112', '09121110002', 'مدیر سیستم M1',
   'sys.m1@example.test', 'active',
   '$2b$12$m1fixtureHashNotUsedBySqlChain0000000000000000000000000001');

insert into iam.user_roles (user_id, role_id)
select '11111111-1111-1111-1111-111111111111'::uuid, id from iam.roles where key = 'R-OP';
insert into iam.user_roles (user_id, role_id)
select '11111111-1111-1111-1111-111111111112'::uuid, id from iam.roles where key = 'R-SYS';

-- R-SYS حساس است؛ بدون MFA تأییدشده ورود مسدود می‌ماند (ADR-007).
insert into iam.mfa_factors (user_id, kind, secret_ciphertext, label, confirmed_at)
values ('11111111-1111-1111-1111-111111111112'::uuid, 'totp',
        decode(repeat('5a', 32), 'hex'), 'M1 authenticator', now());

-- -----------------------------------------------------------------------------
-- گام ۱ و ۲: ورود + مجوز محدود + Audit — با نقش اپ
-- -----------------------------------------------------------------------------
set role fco_app;

do $$
declare
  v_emp        uuid := '11111111-1111-1111-1111-111111111111';
  v_sys        uuid := '11111111-1111-1111-1111-111111111112';
  v_emp_token  bytea := decode(repeat('e1', 32), 'hex');
  v_sys_token  bytea := decode(repeat('e2', 32), 'hex');
  v_sid        uuid;
  v_sys_sid    uuid;
  v_uid        uuid;
  v_audit      bigint;
  v_count      integer;
begin
  -- آزمون منفی: توکن ناشناس نباید نشست بدهد
  begin
    perform * from iam.authenticate(decode(repeat('00', 32), 'hex'));
    raise exception 'FAIL LOGIN: توکن ناشناس پذیرفته شد';
  exception when sqlstate '28000' then
    raise notice 'PASS LOGIN-NEGATIVE | توکن ناشناس → %', sqlerrm;
  end;

  perform iam.register_login_success(v_emp);
  v_sid := iam.start_session(v_emp, v_emp_token, '127.0.0.1', 'm1-chain/1.0');

  select a.sid, a.uid into v_sid, v_uid
    from iam.authenticate(v_emp_token) a;
  if v_uid is distinct from v_emp then
    raise exception 'FAIL LOGIN: نشست به کاربر % تعلق گرفت، نه %', v_uid, v_emp;
  end if;
  raise notice 'PASS LOGIN | کارمند R-OP با نشست % وارد شد', v_sid;

  -- آزمون منفی: اپراتور انبار نباید مجوز اجرای Job داشته باشد
  begin
    perform iam.authorize(v_emp, 'platform.job.run');
    raise exception 'FAIL AUTHZ: اپراتور مجوز platform.job.run گرفت';
  exception when insufficient_privilege then
    raise notice 'PASS AUTHZ-NEGATIVE | مجوز محدود → %', sqlerrm;
  end;

  -- Audit ورود: تنها مسیر مجاز، تابع با actor + request_id
  v_audit := sys.audit_write(
    p_actor       => v_emp,
    p_action      => 'session.login',
    p_entity_type => 'sessions',
    p_entity_id   => v_sid,
    p_after       => jsonb_build_object('method', 'password', 'ip', '127.0.0.1'),
    p_reason      => 'ورود کارمند در زنجیره M1',
    p_request_id  => 'm1-login-1');
  if v_audit is null then
    raise exception 'FAIL AUDIT: شناسه رکورد Audit برنگشت';
  end if;
  raise notice 'PASS AUDIT | رکورد % برای ورود ثبت شد', v_audit;

  -- آزمون منفی: Audit بدون request_id نباید ثبت شود (T-PLT-05)
  begin
    perform sys.audit_write(v_emp, 'session.login', 'sessions', v_sid,
                            null, '{}'::jsonb, null, null, null);
    raise exception 'FAIL AUDIT: Audit بدون request_id پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS AUDIT-NEGATIVE | بدون request_id → %', sqlerrm;
  end;

  -- آزمون منفی: نوشتن مستقیم روی دفتر Audit برای اپ ممنوع است
  begin
    insert into sys.audit_log (actor_id, action, entity_type, "after", request_id)
    values (v_emp, 'audit.forged', 'sessions', '{}'::jsonb, 'm1-forged');
    raise exception 'FAIL AUDIT: نوشتن مستقیم روی sys.audit_log مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS AUDIT-NEGATIVE | نوشتن مستقیم → %', sqlerrm;
  end;

  -- ورود مدیر سیستم (R-SYS) با MFA تأییدشده
  perform iam.register_login_success(v_sys);
  perform iam.start_session(v_sys, v_sys_token, '127.0.0.1', 'm1-chain/admin');
  select a.sid into v_sys_sid from iam.authenticate(v_sys_token) a;
  raise notice 'PASS LOGIN | مدیر سیستم R-SYS با MFA وارد شد (نشست %)', v_sys_sid;

  -- جست‌وجوی Audit با مجوز
  select count(*) into v_count
    from sys.audit_search(v_sys, 'sessions', v_sid, null, 'session.login',
                          null, null, 10, 0);
  if v_count <> 1 then
    raise exception 'FAIL AUDIT: جست‌وجوی مجاز % ردیف داد، انتظار ۱', v_count;
  end if;
  raise notice 'PASS AUDIT | جست‌وجوی مجاز رکورد ورود را یافت';

  -- آزمون منفی: اپراتور نباید Audit را جست‌وجو کند
  begin
    perform 1 from sys.audit_search(v_emp, null, null, null, null,
                                    null, null, 10, 0);
    raise exception 'FAIL AUDIT: جست‌وجوی Audit بدون مجوز انجام شد';
  exception when insufficient_privilege then
    raise notice 'PASS AUDIT-NEGATIVE | جست‌وجو بدون iam.audit.read → %', sqlerrm;
  end;
end $$;

-- -----------------------------------------------------------------------------
-- گام ۳: Job (Outbox Worker) → شکست تا DLQ
-- -----------------------------------------------------------------------------
do $$
declare
  v_sys     uuid := '11111111-1111-1111-1111-111111111112';
  v_event   bigint;
  v_outcome text;
  v_max     integer := sys.setting_int('outbox.max_attempts');
  v_claimed integer;
  v_count   integer;
  v_attempt integer;
begin
  v_event := sys.outbox_emit(
    'order', gen_random_uuid(), 'order.paid',
    jsonb_build_object('order_id', 'M1-1001', 'amount_rial', 4500000));
  raise notice 'PASS JOB | رویداد % در Outbox ثبت شد', v_event;

  for v_attempt in 1..v_max loop
    select count(*) into v_claimed from sys.outbox_claim('m1-worker', 1);
    if v_claimed <> 1 then
      raise exception 'FAIL JOB: تلاش % رویدادی تحویل نگرفت', v_attempt;
    end if;

    v_outcome := sys.outbox_fail(v_event,
                   'm1: downstream unavailable (attempt ' || v_attempt || ')');
    if v_attempt < v_max and v_outcome <> 'retry' then
      raise exception 'FAIL JOB: تلاش % نتیجه % داد، نه retry', v_attempt, v_outcome;
    end if;
    if v_attempt = v_max and v_outcome <> 'dead_letter' then
      raise exception 'FAIL DLQ: تلاش آخر نتیجه % داد، نه dead_letter', v_outcome;
    end if;
  end loop;
  raise notice 'PASS JOB | پس از % تلاش، خطا رویداد را به DLQ برد', v_max;

  select count(*) into v_claimed from sys.outbox_claim('m1-worker', 10);
  if v_claimed <> 0 then
    raise exception 'FAIL DLQ: رویداد DLQ دوباره تحویل داده شد';
  end if;

  select count(*) into v_count from sys.dlq_list(v_sys, 10);
  if v_count <> 1 then
    raise exception 'FAIL DLQ: فهرست با مجوز % ردیف داد، انتظار ۱', v_count;
  end if;
  raise notice 'PASS DLQ | مدیر سیستم ۱ رویداد DLQ را با مجوز دید';

  -- آزمون منفی: اپراتور نباید DLQ را ببیند
  begin
    perform 1 from sys.dlq_list('11111111-1111-1111-1111-111111111111'::uuid, 10);
    raise exception 'FAIL DLQ: فهرست DLQ بدون مجوز خوانده شد';
  exception when insufficient_privilege then
    raise notice 'PASS DLQ-NEGATIVE | بدون platform.dlq.inspect → %', sqlerrm;
  end;
end $$;

reset role;

-- -----------------------------------------------------------------------------
-- شاهد نهایی: هر چهار اثر باید در دیتابیس منبع موجود باشند
-- -----------------------------------------------------------------------------
do $$
declare
  v_audit integer;
  v_dead  integer;
  v_sess  integer;
  v_err   text;
begin
  select count(*) into v_audit from sys.audit_log
   where action = 'session.login' and request_id = 'm1-login-1';
  select count(*) into v_dead from sys.outbox
   where event_name = 'order.paid' and dead_lettered_at is not null
     and processed_at is null;
  select count(*) into v_sess from iam.sessions where revoked_at is null;

  if v_audit <> 1 or v_dead <> 1 or v_sess <> 2 then
    raise exception 'FAIL EVIDENCE: audit=% dlq=% sessions=%', v_audit, v_dead, v_sess;
  end if;

  select last_error into v_err from sys.outbox
   where event_name = 'order.paid' and dead_lettered_at is not null;
  if v_err is null or v_err not like 'm1:%' then
    raise exception 'FAIL EVIDENCE: last_error ثبت نشده: %', coalesce(v_err, 'null');
  end if;

  raise notice 'PASS EVIDENCE | نشست=۲، Audit=۱، DLQ=۱ با last_error=%', v_err;
end $$;

select 'ALL M1 CHAIN STEPS PASSED' as result;
