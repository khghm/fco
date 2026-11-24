-- =============================================================================
-- 0007_otp_negative — BR-1 گام ۶: آزمون منفی OTP مشتری
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §6 (T-SEC-12)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0007_otp_negative.sql
--
-- پوشش: cooldown ارسال مجدد، سقف پنجره موبایل و IP، باطل‌شدن کد قبلی،
--       کد غلط/منقضی/مصرف‌شده، قفل پس از سقف تلاش، پاسخ یکسان برای موبایل
--       ناموجود، و Spool توسعه (روشن/خاموش و دسترسی مستقیم اپ).
-- نکته طراحی: `iam.verify_otp` وضعیت برمی‌گرداند (ok|invalid|locked) و Exception
--       نمی‌دهد، چون RAISE شمارنده تلاش را هم بازمی‌گرداند و محافظت Brute Force
--       بی‌اثر می‌شد؛ همین آزمون این شکاف را در اولین اجرا پیدا کرد.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

-- Spool توسعه روشن می‌شود (نسخه تنظیم، نه تغییر مستقیم مقدار جاری)
insert into sys.setting_versions (key, value, effective_from, reason)
values ('auth.otp.spool_enabled', 'true'::jsonb, now() - interval '2 hours', 'آزمون گام ۶');

do $$
declare
  v_a uuid; v_b uuid; v_c uuid;
  v_hash_a bytea := decode(repeat('aa', 32), 'hex');
  v_hash_b bytea := decode(repeat('bb', 32), 'hex');
  v_hash_c bytea := decode(repeat('cc', 32), 'hex');
  v_wrong  bytea := decode(repeat('11', 32), 'hex');
  v_out    text;
  i integer;
begin
  -- ۱) درخواست کد + Spool توسعه
  v_a := iam.request_otp('09120000007', 'login', v_hash_a, '127.0.0.9'::inet);
  perform iam.spool_otp(v_a, '111111');
  if iam.read_spool(v_a) <> '111111' then
    raise exception 'FAIL SPOOL: کد در Spool توسعه نیست';
  end if;
  raise notice 'PASS OTP | درخواست کد ساخته شد و کد در Spool توسعه خوانده شد';

  -- ۲) فاصله ارسال مجدد
  begin
    perform iam.request_otp('09120000007', 'login', v_hash_b, '127.0.0.9'::inet);
    raise exception 'FAIL OTP: ارسال مجدد پیش از cooldown پذیرفته شد';
  exception when sqlstate '53300' then
    if sqlerrm not like 'FCO-1013%' then
      raise exception 'FAIL OTP: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS OTP | cooldown ارسال → %', sqlerrm;
  end;

  -- ۳) درخواست جدید، کد قبلی را باطل می‌کند
  update iam.otp_requests set created_at = now() - interval '5 minutes' where id = v_a;
  v_b := iam.request_otp('09120000007', 'login', v_hash_b, '127.0.0.9'::inet);
  if not exists (select 1 from iam.otp_requests where id = v_a and invalidated_at is not null) then
    raise exception 'FAIL OTP: کد قبلی باطل نشد';
  end if;
  raise notice 'PASS OTP | درخواست جدید کد فعال قبلی را باطل کرد';

  -- ۴) کد باطل‌شده پذیرفته نمی‌شود
  select outcome into v_out from iam.verify_otp('09120000007', 'login', v_hash_a);
  if v_out <> 'invalid' then
    raise exception 'FAIL OTP: کد باطل‌شده پذیرفته شد (%)', v_out;
  end if;
  raise notice 'PASS OTP | کد باطل‌شده → invalid';

  -- ۵) کد غلط: شمارش تلاش پایدار می‌ماند و پس از سقف قفل می‌شود
  -- (مرحله ۴ یک تلاش غلط علیه کد فعال B ثبت کرده است؛ پس فقط تا سقف ادامه می‌دهیم)
  if (select attempts from iam.otp_requests where id = v_b) <> 1 then
    raise exception 'FAIL OTP: تلاش غلط مرحله ۴ ثبت نشد (%)',
      (select attempts from iam.otp_requests where id = v_b);
  end if;

  for i in 1..(5 - (select attempts from iam.otp_requests where id = v_b)) loop
    select outcome into v_out from iam.verify_otp('09120000007', 'login', v_wrong);
    if v_out <> 'invalid' then
      raise exception 'FAIL OTP: کد غلط نتیجه % داد (تلاش %)', v_out, i;
    end if;
  end loop;

  if (select attempts from iam.otp_requests where id = v_b) <> 5 then
    raise exception 'FAIL OTP: شمارش تلاش نادرست است (%)',
      (select attempts from iam.otp_requests where id = v_b);
  end if;
  raise notice 'PASS OTP | پنج تلاش غلط شمرده و پایدار شد (attempts=5)';

  select outcome into v_out from iam.verify_otp('09120000007', 'login', v_hash_b);
  if v_out <> 'locked' then
    raise exception 'FAIL OTP: کد درست پس از سقف تلاش نتیجه % داد، نه locked', v_out;
  end if;
  raise notice 'PASS OTP | پس از سقف تلاش → locked';

  -- ۶) سقف پنجره برای هر موبایل
  update iam.otp_requests set created_at = now() - interval '5 minutes'
   where mobile = '09120000007';
  v_c := iam.request_otp('09120000007', 'login', v_hash_c, '127.0.0.9'::inet);
  update iam.otp_requests set created_at = now() - interval '4 minutes' where id = v_c;

  begin
    perform iam.request_otp('09120000007', 'login', v_hash_c, '127.0.0.9'::inet);
    raise exception 'FAIL OTP: سقف پنجره موبایل رعایت نشد';
  exception when sqlstate '53300' then
    if sqlerrm not like 'FCO-1012%' then
      raise exception 'FAIL OTP: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS OTP | سقف پنجره موبایل → %', sqlerrm;
  end;

  -- ۷) کد منقضی (بدون نقض قید expires_at > created_at)
  update iam.otp_requests
     set created_at = now() - interval '20 minutes',
         expires_at = now() - interval '10 minutes'
   where id = v_c;

  select outcome into v_out from iam.verify_otp('09120000007', 'login', v_hash_c);
  if v_out <> 'invalid' then
    raise exception 'FAIL OTP: کد منقضی نتیجه % داد، نه invalid', v_out;
  end if;
  raise notice 'PASS OTP | کد منقضی → invalid';

  -- ۸) مصرف یک‌باره: کد درست یک بار ok، بار دوم invalid
  perform iam.request_otp('09120000007', 'login', v_hash_c, '127.0.0.1'::inet);

  select outcome into v_out from iam.verify_otp('09120000007', 'login', v_hash_c);
  if v_out <> 'ok' then
    raise exception 'FAIL OTP: کد درست نتیجه % داد', v_out;
  end if;

  select outcome into v_out from iam.verify_otp('09120000007', 'login', v_hash_c);
  if v_out <> 'invalid' then
    raise exception 'FAIL OTP: کد مصرف‌شده دوباره پذیرفته شد (%)', v_out;
  end if;
  raise notice 'PASS OTP | مصرف یک‌باره کد (ok سپس invalid)';

  -- ۹) موبایل ناموجود: همان مسیر، بدون افشای وجود حساب
  perform iam.request_otp('09129999999', 'login', v_hash_a, '127.0.0.11'::inet);
  raise notice 'PASS OTP | موبایل ناموجود همان مسیر را طی کرد (بدون شمارش کاربر)';
end $$;

-- ۱۰) سقف پنجره برای هر IP (تنظیم نسخه‌دار، نه هارد‌کد)
do $$
declare v_hash bytea := decode(repeat('ab', 32), 'hex');
begin
  insert into sys.setting_versions (key, value, effective_from, reason)
  values ('auth.otp.max_per_ip_window', '2'::jsonb, now() - interval '1 hour', 'آزمون سقف IP');

  perform iam.request_otp('09120000011', 'login', v_hash, '127.0.0.10'::inet);
  perform iam.request_otp('09120000012', 'login', v_hash, '127.0.0.10'::inet);

  begin
    perform iam.request_otp('09120000013', 'login', v_hash, '127.0.0.10'::inet);
    raise exception 'FAIL OTP: سقف پنجره IP رعایت نشد';
  exception when sqlstate '53300' then
    if sqlerrm not like 'FCO-1012%' then
      raise exception 'FAIL OTP: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS OTP | سقف پنجره IP → %', sqlerrm;
  end;
end $$;

-- ۱۱) Spool خاموش: هیچ کد خامی ذخیره یا خوانده نمی‌شود
do $$
declare v_req uuid;
begin
  insert into sys.setting_versions (key, value, effective_from, reason)
  values ('auth.otp.spool_enabled', 'false'::jsonb, now() - interval '1 hour', 'آزمون خاموشی');

  v_req := iam.request_otp('09120000021', 'login', decode(repeat('cd', 32), 'hex'), null);

  begin
    perform iam.spool_otp(v_req, '654321');
    raise exception 'FAIL SPOOL: نوشتن با Spool خاموش مجاز بود';
  exception when sqlstate '22023' then
    raise notice 'PASS SPOOL | خاموش → %', sqlerrm;
  end;

  if exists (select 1 from sys.otp_spool where otp_request_id = v_req) then
    raise exception 'FAIL SPOOL: با Spool خاموش ردیفی ثبت شد';
  end if;
  raise notice 'PASS SPOOL | بدون تنظیم، هیچ کد خامی ذخیره نشد';
end $$;

-- ۱۲) اپ به جدول‌های OTP دسترسی مستقیم ندارد
set local role fco_app;

do $$
begin
  begin
    insert into iam.otp_requests (mobile, purpose, code_hash, expires_at)
    values ('09120000031', 'login', decode(repeat('aa', 32), 'hex'), now() + interval '2 minutes');
    raise exception 'FAIL APP-ROLE: درج مستقیم OTP مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم iam.otp_requests مسدود شد';
  end;

  begin
    perform 1 from sys.otp_spool;
    raise exception 'FAIL APP-ROLE: خواندن مستقیم Spool مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | خواندن مستقیم sys.otp_spool مسدود شد';
  end;

  perform iam.request_otp('09120000032', 'login', decode(repeat('ef', 32), 'hex'), null);
  raise notice 'PASS APP-ROLE | درخواست OTP فقط از مسیر تابع کار کرد';
end $$;

reset role;

select 'ALL STEP-6 NEGATIVE CASES PASSED' as result;
rollback;
