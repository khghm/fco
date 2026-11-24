-- =============================================================================
-- 0005_identity_negative — BR-1 گام ۵: آزمون منفی هویت و مجوز
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §6 (T-SEC-01/03/05/06)
--
-- اجرا (روی دیتابیس توسعه، پس از `scripts/db-migrate.sh up`):
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0005_identity_negative.sql
--
-- قاعده: هر مورد در یک بلوک با انتظار مشخص است؛ اگر کنترل غایب باشد،
-- `FAIL` می‌دهد و psql با کد غیرصفر خارج می‌شود (آزمون سبز همیشگی = بی‌اثر).
-- همه fixtureها در یک تراکنش ساخته و در پایان rollback می‌شوند.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

-- --- fixtureها ---------------------------------------------------------------
insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('11111111-1111-1111-1111-111111111111', '09120000001', 'اپراتور آزمون', 'active', 'fixture-hash-value-0001'),
  ('22222222-2222-2222-2222-222222222222', '09120000002', 'مدیر مالی آزمون', 'active', 'fixture-hash-value-0002'),
  ('33333333-3333-3333-3333-333333333333', '09120000003', 'مدیر سیستم آزمون', 'active', 'fixture-hash-value-0003');

insert into iam.user_roles (user_id, role_id)
select '11111111-1111-1111-1111-111111111111'::uuid, id from iam.roles where key = 'R-OP';
insert into iam.user_roles (user_id, role_id)
select '22222222-2222-2222-2222-222222222222'::uuid, id from iam.roles where key = 'R-FIN';
insert into iam.user_roles (user_id, role_id)
select '33333333-3333-3333-3333-333333333333'::uuid, id from iam.roles where key = 'R-SYS';

-- --- T-SEC-01: بدون مجوز ⇒ 403 FCO-1003 ------------------------------------
do $$
begin
  begin
    perform iam.authorize('11111111-1111-1111-1111-111111111111'::uuid, 'iam.audit.read');
    raise exception 'FAIL T-SEC-01: کاربر بدون مجوز عبور کرد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL T-SEC-01: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS T-SEC-01 | بدون مجوز → %', sqlerrm;
  end;
end $$;

-- با مجوز، همان فراخوانی باید عبور کند (کنترل واقعاً روی داده است، نه همیشه‌قرمز)
do $$
begin
  insert into iam.user_roles (user_id, role_id)
  select '11111111-1111-1111-1111-111111111111'::uuid, id from iam.roles where key = 'R-FIN';

  perform iam.authorize('11111111-1111-1111-1111-111111111111'::uuid, 'iam.audit.read');
  raise notice 'PASS T-SEC-01 | با مجوز iam.audit.read عبور کرد';
end $$;

-- مجوز ناموجود هم نباید به‌عنوان «دارد» تلقی شود
do $$
begin
  begin
    perform iam.authorize('22222222-2222-2222-2222-222222222222'::uuid, 'finance.journal.post');
    raise exception 'FAIL T-SEC-01: مجوز تعریف‌نشده پذیرفته شد';
  exception when insufficient_privilege then
    raise notice 'PASS T-SEC-01 | مجوز تعریف‌نشده رد شد';
  end;
end $$;

-- --- T-SEC-03: تفکیک وظایف در DB -------------------------------------------
do $$
begin
  begin
    insert into iam.user_roles (user_id, role_id, granted_by)
    select '33333333-3333-3333-3333-333333333333'::uuid, id,
           '33333333-3333-3333-3333-333333333333'::uuid
      from iam.roles where key = 'R-FIN';
    raise exception 'FAIL T-SEC-03: ترکیب R-SYS + R-FIN پذیرفته شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1004%' then
      raise exception 'FAIL T-SEC-03: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS T-SEC-03 | SoD-7 (ترکیب نقش) → %', sqlerrm;
  end;
end $$;

do $$
begin
  begin
    perform iam.grant_role('33333333-3333-3333-3333-333333333333'::uuid,
                           '33333333-3333-3333-3333-333333333333'::uuid,
                           'R-SYS');
    raise exception 'FAIL T-SEC-03: تخصیص نقش سیستمی به خود پذیرفته شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1004%' then
      raise exception 'FAIL T-SEC-03: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS T-SEC-03 | SoD-4 (تخصیص به خود) → %', sqlerrm;
  end;
end $$;

do $$
begin
  begin
    perform sys.assert_separation('22222222-2222-2222-2222-222222222222'::uuid,
                                  '22222222-2222-2222-2222-222222222222'::uuid,
                                  'payment.approve');
    raise exception 'FAIL T-SEC-03: Maker=Checker پذیرفته شد';
  exception when insufficient_privilege then
    raise notice 'PASS T-SEC-03 | Maker=Checker → %', sqlerrm;
  end;

  perform sys.assert_separation('22222222-2222-2222-2222-222222222222'::uuid,
                                '11111111-1111-1111-1111-111111111111'::uuid,
                                'payment.approve');
  raise notice 'PASS T-SEC-03 | Maker≠Checker عبور کرد';
end $$;

-- --- T-SEC-06: نقش حساس بدون MFA -------------------------------------------
do $$
begin
  begin
    perform iam.start_session('22222222-2222-2222-2222-222222222222'::uuid,
                              decode(repeat('ab', 32), 'hex'), '127.0.0.1'::inet, 'psql-test');
    raise exception 'FAIL T-SEC-06: ورود R-FIN بدون MFA پذیرفته شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1006%' then
      raise exception 'FAIL T-SEC-06: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS T-SEC-06 | بدون MFA → %', sqlerrm;
  end;
end $$;

do $$
declare v_sid uuid;
begin
  insert into iam.mfa_factors (user_id, kind, secret_ciphertext, confirmed_at)
  values ('22222222-2222-2222-2222-222222222222'::uuid, 'totp',
          decode(repeat('5c', 32), 'hex'), now());

  v_sid := iam.start_session('22222222-2222-2222-2222-222222222222'::uuid,
                             decode(repeat('ab', 32), 'hex'), '127.0.0.1'::inet, 'psql-test');
  raise notice 'PASS T-SEC-06 | پس از تأیید TOTP نشست ساخته شد (%)', v_sid;
end $$;

-- --- T-SEC-05: نشست ابطال‌شده ⇒ 401 FCO-1001 -------------------------------
do $$
declare v_sid uuid;
begin
  select sid into v_sid from iam.authenticate(decode(repeat('ab', 32), 'hex'), false);
  raise notice 'PASS T-SEC-05 | نشست معتبر شناسایی شد (%)', v_sid;

  perform iam.revoke_session(v_sid, 'test_revoke');

  begin
    perform 1 from iam.authenticate(decode(repeat('ab', 32), 'hex'), false);
    raise exception 'FAIL T-SEC-05: نشست ابطال‌شده پذیرفته شد';
  exception when sqlstate '28000' then
    if sqlerrm not like 'FCO-1001%' then
      raise exception 'FAIL T-SEC-05: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS T-SEC-05 | پس از ابطال → %', sqlerrm;
  end;
end $$;

-- تغییر رمز باید همه نشست‌ها را باطل کند (چرخش ADR-007)
do $$
declare v_sid uuid;
begin
  insert into iam.mfa_factors (user_id, kind, secret_ciphertext, confirmed_at)
  values ('11111111-1111-1111-1111-111111111111'::uuid, 'totp',
          decode(repeat('7d', 32), 'hex'), now());

  v_sid := iam.start_session('11111111-1111-1111-1111-111111111111'::uuid,
                             decode(repeat('cd', 32), 'hex'), '127.0.0.1'::inet, 'psql-test');
  perform iam.set_password_hash('11111111-1111-1111-1111-111111111111'::uuid,
                                '$argon2id$v=19$m=65536,t=3,p=4$fixture$fixture');

  if exists (select 1 from iam.sessions where id = v_sid and revoked_at is null) then
    raise exception 'FAIL T-SEC-05: نشست پس از تغییر رمز معتبر ماند';
  end if;
  raise notice 'PASS T-SEC-05 | تغییر رمز همه نشست‌ها را باطل کرد';
end $$;

-- --- سیاست رمز (تنظیم نسخه‌دار، بدون هارد‌کد) -------------------------------
do $$
begin
  begin
    perform iam.assert_password_policy('Short1!');
    raise exception 'FAIL POLICY: رمز کوتاه پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS POLICY | رمز کوتاه → %', sqlerrm;
  end;

  begin
    perform iam.assert_password_policy('Password123!');
    raise exception 'FAIL POLICY: رمز رایج پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS POLICY | رمز رایج → %', sqlerrm;
  end;

  begin
    perform iam.assert_password_policy('abcdefghijklmn');
    raise exception 'FAIL POLICY: رمز تک‌دسته پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS POLICY | تنوع دسته ناکافی → %', sqlerrm;
  end;

  perform iam.assert_password_policy('FCO-Strong-Pass-2026');
  raise notice 'PASS POLICY | رمز مطابق سیاست عبور کرد';
end $$;

-- --- قفل ورود پس از آستانه ---------------------------------------------------
do $$
declare v_locked timestamptz; i integer;
begin
  for i in 1..5 loop
    v_locked := iam.register_login_failure('11111111-1111-1111-1111-111111111111'::uuid);
  end loop;

  if v_locked is null or v_locked <= now() then
    raise exception 'FAIL LOCK: پس از آستانه، قفل فعال نشد';
  end if;
  raise notice 'PASS LOCK | پس از ۵ تلاش قفل تا %', v_locked;
end $$;

-- --- دسترسی نقش اپ (کمترین امتیاز) -----------------------------------------
set local role fco_app;

do $$
begin
  begin
    execute 'create table iam.should_not_exist (id int)';
    raise exception 'FAIL APP-ROLE: DDL در schema iam مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | DDL مسدود شد';
  end;

  perform sys.audit_write(
    p_actor => '33333333-3333-3333-3333-333333333333'::uuid,
    p_action => 'login_succeeded',
    p_entity_type => 'users',
    p_entity_id => '33333333-3333-3333-3333-333333333333'::uuid,
    p_after => '{"via":"psql-test"}'::jsonb,
    p_request_id => 'psql-test-1');
  raise notice 'PASS APP-ROLE | ثبت Audit از مسیر تابع مجاز بود';

  begin
    insert into sys.audit_log (action, entity_type, "after")
    values ('bypass', 'users', '{}'::jsonb);
    raise exception 'FAIL APP-ROLE: درج مستقیم Audit مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم Audit مسدود شد';
  end;

  begin
    update sys.audit_log set action = 'tamper';
    raise exception 'FAIL APP-ROLE: تغییر Audit مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | تغییر Audit مسدود شد';
  end;

  begin
    delete from sys.audit_log;
    raise exception 'FAIL APP-ROLE: حذف Audit مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | حذف Audit مسدود شد';
  end;

  begin
    insert into sys.outbox (aggregate_type, aggregate_id, event_name, payload)
    values ('test', gen_random_uuid(), 'test.event', '{}'::jsonb);
    raise exception 'FAIL APP-ROLE: درج مستقیم Outbox مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | Outbox مستقیم مسدود شد';
  end;

  -- بازبینی: نشست نباید دور از start_session ساخته شود (وگرنه MFA دور زده می‌شود)
  begin
    insert into iam.sessions (user_id, token_hash, expires_at)
    values ('11111111-1111-1111-1111-111111111111'::uuid,
            decode(repeat('aa', 32), 'hex'), now() + interval '1 hour');
    raise exception 'FAIL APP-ROLE: ساخت نشست بدون start_session مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم نشست مسدود شد';
  end;

  -- بازبینی: تغییر رمز فقط از set_password_hash (با ابطال نشست‌ها)
  begin
    update iam.users set password_hash = '$argon2id$v=19$m=1,t=1,p=1$bypass'
     where id = '22222222-2222-2222-2222-222222222222'::uuid;
    raise exception 'FAIL APP-ROLE: تغییر مستقیم password_hash مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | تغییر مستقیم password_hash مسدود شد';
  end;

  -- درج کاربر هم نباید ستون رمز را در اختیار اپ بگذارد
  begin
    insert into iam.users (mobile, full_name, password_hash)
    values ('09120000099', 'کاربر آزمون هک', '$argon2id$v=19$m=1,t=1,p=1$x');
    raise exception 'FAIL APP-ROLE: درج کاربر با password_hash مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج کاربر با password_hash مسدود شد';
  end;

  insert into iam.users (mobile, full_name)
  values ('09120000098', 'کاربر ایجادشده توسط اپ');
  raise notice 'PASS APP-ROLE | ایجاد کاربر بدون ستون رمز مجاز بود';

  update iam.users set full_name = 'نام آزمون ویرایش‌شده'
   where id = '22222222-2222-2222-2222-222222222222'::uuid;
  raise notice 'PASS APP-ROLE | ویرایش ستون مجاز (full_name) انجام شد';
end $$;

reset role;

-- --- بازبینی: قالب هش و آزادسازی قفل منقضی --------------------------------
do $$
begin
  begin
    perform iam.set_password_hash('22222222-2222-2222-2222-222222222222'::uuid,
                                  'plain-text-password-value-1234');
    raise exception 'FAIL HASH: هش نامعتبر ذخیره شد';
  exception when sqlstate '22023' then
    raise notice 'PASS HASH | قالب نامعتبر → %', sqlerrm;
  end;
end $$;

do $$
declare v_sid uuid;
begin
  begin
    perform iam.start_session('11111111-1111-1111-1111-111111111111'::uuid,
                              decode(repeat('ef', 32), 'hex'), '127.0.0.1'::inet, 'lock-test');
    raise exception 'FAIL LOCK: ورود با قفل فعال پذیرفته شد';
  exception when sqlstate '28000' then
    raise notice 'PASS LOCK | قفل فعال ورود را رد کرد';
  end;

  -- پایان مدت قفل را شبیه‌سازی می‌کنیم؛ ورود بعدی باید خودکار آزاد شود
  update iam.users set locked_until = now() - interval '1 minute'
   where id = '11111111-1111-1111-1111-111111111111'::uuid;

  v_sid := iam.start_session('11111111-1111-1111-1111-111111111111'::uuid,
                             decode(repeat('ef', 32), 'hex'), '127.0.0.1'::inet, 'lock-test');

  if not exists (select 1 from iam.users
                  where id = '11111111-1111-1111-1111-111111111111'::uuid
                    and status = 'active' and failed_attempts = 0) then
    raise exception 'FAIL LOCK: قفل منقضی آزاد نشد';
  end if;
  raise notice 'PASS LOCK | قفل منقضی خودکار آزاد شد و نشست ساخته شد (%)', v_sid;
end $$;

select 'ALL STEP-5 NEGATIVE CASES PASSED' as result;
rollback;
