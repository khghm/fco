-- =============================================================================
-- 0008_audit_settings_negative — BR-1 گام ۷
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4/§6
--   (T-SEC-01 مجوز، T-PLT-04 تنظیم نسخه‌دار، T-PLT-05 request_id)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0008_audit_settings_negative.sql
--
-- پوشش: اعتبارسنجی مسیر نوشتن Audit، جست‌وجوی Audit با/بدون مجوز و سقف صفحه،
--       جلوگیری از بازنویسی تاریخچه تنظیمات، مجوز/دلیل/تاریخ تغییر تنظیم،
--       و Audit خودکار تخصیص نقش و تغییر رمز.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

-- --- fixtureها ---------------------------------------------------------------
insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('55555555-5555-5555-5555-555555555555', '09120000051', 'مدیر سیستم آزمون', 'active', 'fixture-hash-0051'),
  ('66666666-6666-6666-6666-666666666666', '09120000052', 'اپراتور بدون مجوز', 'active', 'fixture-hash-0052');

insert into iam.user_roles (user_id, role_id)
select '55555555-5555-5555-5555-555555555555'::uuid, id from iam.roles where key = 'R-SYS';
insert into iam.user_roles (user_id, role_id)
select '66666666-6666-6666-6666-666666666666'::uuid, id from iam.roles where key = 'R-OP';

-- --- اعتبارسنجی مسیر نوشتن Audit ---------------------------------------------
do $$
begin
  begin
    perform sys.audit_write(
      p_actor => '55555555-5555-5555-5555-555555555555'::uuid,
      p_action => 'test.action',
      p_entity_type => 'users',
      p_after => '{"a":1}'::jsonb,
      p_request_id => '   ');
    raise exception 'FAIL AUDIT: request_id خالی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS AUDIT | request_id خالی → %', sqlerrm;
  end;

  begin
    perform sys.audit_write(
      p_actor => '55555555-5555-5555-5555-555555555555'::uuid,
      p_action => 'test.action',
      p_entity_type => 'users',
      p_request_id => 'req-1');
    raise exception 'FAIL AUDIT: رکورد بدون before/after ثبت شد';
  exception when sqlstate '22023' then
    raise notice 'PASS AUDIT | بدون before/after → %', sqlerrm;
  end;

  begin
    perform sys.audit_write(
      p_actor => '00000000-0000-0000-0000-000000000000'::uuid,
      p_action => 'test.action',
      p_entity_type => 'users',
      p_after => '{"a":1}'::jsonb,
      p_request_id => 'req-2');
    raise exception 'FAIL AUDIT: actor ناموجود پذیرفته شد';
  exception when sqlstate '28000' then
    raise notice 'PASS AUDIT | actor ناموجود → %', sqlerrm;
  end;
end $$;

-- --- جست‌وجو: مجوز و سقف -----------------------------------------------------
do $$
declare v_audit_id bigint; v_count integer; i integer;
begin
  v_audit_id := sys.audit_write(
    p_actor => '55555555-5555-5555-5555-555555555555'::uuid,
    p_action => 'user.disable',
    p_entity_type => 'users',
    p_entity_id => '66666666-6666-6666-6666-666666666666'::uuid,
    p_before => '{"status":"active"}'::jsonb,
    p_after => '{"status":"disabled"}'::jsonb,
    p_permission => 'iam.user.disable',
    p_request_id => 'req-3');
  raise notice 'PASS AUDIT | رکورد Audit ساخته شد (id=%)', v_audit_id;

  begin
    perform 1 from sys.audit_search('66666666-6666-6666-6666-666666666666'::uuid);
    raise exception 'FAIL AUDIT: جست‌وجو بدون مجوز عبور کرد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL AUDIT: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS AUDIT | بدون iam.audit.read → %', sqlerrm;
  end;

  select count(*) into v_count
    from sys.audit_search('55555555-5555-5555-5555-555555555555'::uuid,
                          p_action => 'user.disable',
                          p_entity_id => '66666666-6666-6666-6666-666666666666'::uuid);
  if v_count <> 1 then
    raise exception 'FAIL AUDIT: فیلتر جست‌وجو % ردیف داد، نه 1', v_count;
  end if;
  raise notice 'PASS AUDIT | جست‌وجوی فیلترشده با مجوز کار کرد';

  -- سقف سخت ۱۰۰ ردیف، حتی با درخواست بزرگ‌تر
  for i in 1..105 loop
    perform sys.audit_write(
      p_actor => '55555555-5555-5555-5555-555555555555'::uuid,
      p_action => 'bulk.test',
      p_entity_type => 'test',
      p_after => jsonb_build_object('i', i),
      p_request_id => 'bulk-' || i);
  end loop;

  select count(*) into v_count
    from sys.audit_search('55555555-5555-5555-5555-555555555555'::uuid,
                          p_action => 'bulk.test', p_limit => 1000);
  if v_count <> 100 then
    raise exception 'FAIL AUDIT: سقف صفحه اعمال نشد (% ردیف)', v_count;
  end if;

  select count(*) into v_count
    from sys.audit_search('55555555-5555-5555-5555-555555555555'::uuid,
                          p_action => 'bulk.test');
  if v_count <> 50 then
    raise exception 'FAIL AUDIT: سقف پیش‌فرض ۵۰ نبود (% ردیف)', v_count;
  end if;
  raise notice 'PASS AUDIT | سقف ۱۰۰ و پیش‌فرض ۵۰ اعمال شد';
end $$;

-- --- تنظیمات: مجوز، دلیل، تاریخ اعتبار ---------------------------------------
do $$
begin
  begin
    perform sys.setting_set('66666666-6666-6666-6666-666666666666'::uuid,
                            'auth.session.idle_minutes', '45'::jsonb,
                            null, 'آزمون', 'req-s1');
    raise exception 'FAIL SETTING: تغییر بدون مجوز پذیرفته شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL SETTING: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS SETTING | بدون platform.setting.write → %', sqlerrm;
  end;

  begin
    perform sys.setting_set('55555555-5555-5555-5555-555555555555'::uuid,
                            'auth.session.idle_minutes', '45'::jsonb,
                            null, '   ', 'req-s2');
    raise exception 'FAIL SETTING: تغییر بدون دلیل پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS SETTING | بدون دلیل → %', sqlerrm;
  end;

  begin
    perform sys.setting_set('55555555-5555-5555-5555-555555555555'::uuid,
                            'auth.unknown.key', '1'::jsonb,
                            null, 'آزمون', 'req-s3');
    raise exception 'FAIL SETTING: کلید ناشناخته پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS SETTING | کلید ناشناخته → %', sqlerrm;
  end;

  begin
    perform sys.setting_set('55555555-5555-5555-5555-555555555555'::uuid,
                            'auth.session.idle_minutes', '45'::jsonb,
                            now() - interval '1 day', 'آزمون', 'req-s4');
    raise exception 'FAIL SETTING: تاریخ اعتبار گذشته پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS SETTING | تاریخ اعتبار گذشته → %', sqlerrm;
  end;
end $$;

-- --- تنظیم معتبر، بستن بازه، Audit و تغییرناپذیری ----------------------------
do $$
declare
  v_version_id bigint;
  v_prev_id    bigint;
  v_value      jsonb;
  v_audit      integer;
begin
  select id into v_prev_id from sys.setting_versions
   where key = 'auth.session.idle_minutes' and effective_to is null;

  v_version_id := sys.setting_set('55555555-5555-5555-5555-555555555555'::uuid,
                                  'auth.session.idle_minutes', '45'::jsonb,
                                  null, 'کاهش بی‌فعالیتی به ۴۵ دقیقه', 'req-s5');

  v_value := sys.setting_value('auth.session.idle_minutes');
  if v_value <> '45'::jsonb then
    raise exception 'FAIL SETTING: مقدار جاری % است، نه 45', v_value;
  end if;

  if not exists (select 1 from sys.setting_versions
                  where id = v_prev_id and effective_to is not null) then
    raise exception 'FAIL SETTING: بازه نسخه قبلی بسته نشد';
  end if;

  select count(*) into v_audit from sys.audit_search(
    '55555555-5555-5555-5555-555555555555'::uuid,
    p_action => 'setting.update');
  if v_audit <> 1 then
    raise exception 'FAIL SETTING: Audit تغییر تنظیم ثبت نشد (% ردیف)', v_audit;
  end if;
  raise notice 'PASS SETTING | تغییر معتبر + بستن بازه + Audit ثبت شد';

  -- نسخه آینده: مقدار جاری تغییر نمی‌کند
  perform sys.setting_set('55555555-5555-5555-5555-555555555555'::uuid,
                          'auth.session.idle_minutes', '60'::jsonb,
                          now() + interval '2 days', 'برنامه آینده', 'req-s6');
  if sys.setting_value('auth.session.idle_minutes') <> '45'::jsonb then
    raise exception 'FAIL SETTING: نسخه آینده مقدار جاری را عوض کرد';
  end if;
  raise notice 'PASS SETTING | نسخه آینده مقدار جاری را تغییر نداد';

  -- تغییر جدید نباید قبل از نسخه آینده ثبت شود
  begin
    perform sys.setting_set('55555555-5555-5555-5555-555555555555'::uuid,
                            'auth.session.idle_minutes', '50'::jsonb,
                            null, 'تلاش خارج از ترتیب', 'req-s7');
    raise exception 'FAIL SETTING: نسخه خارج از ترتیب پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1020%' then
      raise exception 'FAIL SETTING: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS SETTING | نسخه خارج از ترتیب → %', sqlerrm;
  end;

  -- تاریخچه: تغییر مقدار نسخه قبلی
  begin
    update sys.setting_versions set value = '1'::jsonb where id = v_prev_id;
    raise exception 'FAIL SETTING: بازنویسی مقدار نسخه قدیمی مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS SETTING | بازنویسی نسخه قدیمی → %', sqlerrm;
  end;

  begin
    delete from sys.setting_versions where id = v_prev_id;
    raise exception 'FAIL SETTING: حذف نسخه مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS SETTING | حذف نسخه → %', sqlerrm;
  end;
end $$;

-- --- Audit خودکار عملیات حساس -----------------------------------------------
do $$
declare v_audit integer;
begin
  perform iam.grant_role('55555555-5555-5555-5555-555555555555'::uuid,
                         '55555555-5555-5555-5555-555555555555'::uuid,
                         'R-OP', 'req-r1');

  select count(*) into v_audit from sys.audit_search(
    '55555555-5555-5555-5555-555555555555'::uuid,
    p_action => 'role.assign');
  if v_audit <> 1 then
    raise exception 'FAIL AUDIT: تخصیص نقش Audit نشد (% ردیف)', v_audit;
  end if;
  raise notice 'PASS AUDIT | تخصیص نقش خودکار Audit شد';

  perform iam.set_password_hash('66666666-6666-6666-6666-666666666666'::uuid,
                                '$argon2id$v=19$m=65536,t=3,p=4$fixture$fixture',
                                'req-r2');

  select count(*) into v_audit from sys.audit_search(
    '55555555-5555-5555-5555-555555555555'::uuid,
    p_action => 'password.change');
  if v_audit <> 1 then
    raise exception 'FAIL AUDIT: تغییر رمز Audit نشد (% ردیف)', v_audit;
  end if;
  raise notice 'PASS AUDIT | تغییر رمز خودکار Audit شد';
end $$;

-- --- فیلتر زمانی جست‌وجو ------------------------------------------------------
do $$
declare v_count integer;
begin
  select count(*) into v_count
    from sys.audit_search('55555555-5555-5555-5555-555555555555'::uuid,
                          p_from => now() - interval '1 hour');
  if v_count = 0 then
    raise exception 'FAIL AUDIT: فیلتر from ردیفی برنگرداند';
  end if;

  select count(*) into v_count
    from sys.audit_search('55555555-5555-5555-5555-555555555555'::uuid,
                          p_to => now() - interval '1 hour');
  if v_count <> 0 then
    raise exception 'FAIL AUDIT: فیلتر to ردیف قدیمی برگرداند (%)', v_count;
  end if;
  raise notice 'PASS AUDIT | فیلتر زمانی from/to کار کرد';
end $$;

select 'ALL STEP-7 NEGATIVE CASES PASSED' as result;
rollback;
