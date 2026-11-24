-- =============================================================================
-- 0009_outbox_negative — BR-1 گام ۸
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4
--   (T-PLT-01 اجرای دوباره بدون اثر تکراری، T-PLT-02 انتقال به DLQ)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0009_outbox_negative.sql
--
-- پوشش: اعتبارسنجی رویداد، lease و ضدتحویل هم‌زمان، تکمیل، مسیر شکست تا DLQ،
--       عدم تحویل دوباره رویداد DLQ، مصرف ایدم‌پوتنت و مجوز فهرست DLQ.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('77777777-7777-7777-7777-777777777777', '09120000071', 'مدیر سیستم آزمون صف', 'active', 'fixture-hash-0071'),
  ('88888888-8888-8888-8888-888888888888', '09120000072', 'اپراتور بدون مجوز صف', 'active', 'fixture-hash-0072');

insert into iam.user_roles (user_id, role_id)
select '77777777-7777-7777-7777-777777777777'::uuid, id from iam.roles where key = 'R-SYS';
insert into iam.user_roles (user_id, role_id)
select '88888888-8888-8888-8888-888888888888'::uuid, id from iam.roles where key = 'R-OP';

-- --- اعتبارسنجی رویداد -------------------------------------------------------
do $$
begin
  begin
    perform sys.outbox_emit('order', gen_random_uuid(), 'OrderPlaced', '{}'::jsonb);
    raise exception 'FAIL OUTBOX: نام رویداد نامعتبر پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS OUTBOX | نام رویداد نامعتبر → %', sqlerrm;
  end;

  begin
    perform sys.outbox_emit('order', gen_random_uuid(), 'order.placed', '[1,2]'::jsonb);
    raise exception 'FAIL OUTBOX: payload غیرشیء پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS OUTBOX | payload غیرشیء → %', sqlerrm;
  end;

  begin
    perform sys.outbox_emit('  ', gen_random_uuid(), 'order.placed', '{}'::jsonb);
    raise exception 'FAIL OUTBOX: aggregate_type خالی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS OUTBOX | aggregate_type خالی → %', sqlerrm;
  end;
end $$;

-- --- تحویل با lease، تکمیل و ضدتحویل دوباره ----------------------------------
do $$
declare v_id bigint; v_count integer; v_attempts integer;
begin
  v_id := sys.outbox_emit('order', gen_random_uuid(), 'order.placed',
                          '{"total_rial":150000}'::jsonb, '{"trace":"t1"}'::jsonb);

  select count(*), max(attempts) into v_count, v_attempts
    from sys.outbox_claim('worker-a', 10);
  if v_count <> 1 or v_attempts <> 1 then
    raise exception 'FAIL OUTBOX: تحویل اول % ردیف با attempts=%', v_count, v_attempts;
  end if;
  raise notice 'PASS OUTBOX | تحویل اول انجام شد (attempts=1)';

  select count(*) into v_count from sys.outbox_claim('worker-b', 10);
  if v_count <> 0 then
    raise exception 'FAIL OUTBOX: در دوره lease دو Worker همان رویداد را گرفتند';
  end if;
  raise notice 'PASS OUTBOX | lease مانع تحویل هم‌زمان شد';

  if not sys.outbox_complete(v_id) then
    raise exception 'FAIL OUTBOX: تکمیل رویداد ثبت نشد';
  end if;

  select count(*) into v_count from sys.outbox_claim('worker-a', 10);
  if v_count <> 0 then
    raise exception 'FAIL OUTBOX: رویداد تکمیل‌شده دوباره تحویل شد';
  end if;
  raise notice 'PASS OUTBOX | رویداد تکمیل‌شده دوباره تحویل نشد';
end $$;

-- --- مسیر شکست تا DLQ --------------------------------------------------------
do $$
declare v_id bigint; v_out text; v_count integer; i integer;
begin
  v_id := sys.outbox_emit('payment', gen_random_uuid(), 'payment.captured', '{}'::jsonb);

  for i in 1..5 loop
    select count(*) into v_count from sys.outbox_claim('worker-f', 1);
    if v_count <> 1 then
      raise exception 'FAIL DLQ: تلاش % رویدادی تحویل نگرفت', i;
    end if;

    v_out := sys.outbox_fail(v_id, 'boom-' || i);
    if i < 5 and v_out <> 'retry' then
      raise exception 'FAIL DLQ: تلاش % نتیجه % داد، نه retry', i, v_out;
    end if;
    if i = 5 and v_out <> 'dead_letter' then
      raise exception 'FAIL DLQ: تلاش آخر نتیجه % داد، نه dead_letter', v_out;
    end if;
  end loop;

  if not exists (select 1 from sys.outbox
                  where id = v_id and dead_lettered_at is not null and processed_at is null) then
    raise exception 'FAIL DLQ: رویداد وارد DLQ نشد';
  end if;

  select count(*) into v_count from sys.outbox_claim('worker-f', 10);
  if v_count <> 0 then
    raise exception 'FAIL DLQ: رویداد DLQ دوباره تحویل شد';
  end if;
  raise notice 'PASS DLQ | پس از ۵ تلاش dead_letter شد و دیگر تحویل نمی‌شود';
end $$;

-- --- مصرف ایدم‌پوتنت ---------------------------------------------------------
do $$
declare v_count integer;
begin
  if not sys.inbox_consume('evt-1', 'consumer-a') then
    raise exception 'FAIL INBOX: مصرف اول false داد';
  end if;
  if sys.inbox_consume('evt-1', 'consumer-a') then
    raise exception 'FAIL INBOX: مصرف دوباره true داد (اثر تکراری)';
  end if;

  select count(*) into v_count from sys.inbox_events
   where event_id = 'evt-1' and consumer = 'consumer-a';
  if v_count <> 1 then
    raise exception 'FAIL INBOX: رکورد مصرف % بار ثبت شد', v_count;
  end if;

  if sys.inbox_consume('evt-1', 'consumer-b') then
    raise exception 'FAIL INBOX: رویداد پردازش‌شده برای مصرف‌کننده دیگر نو شد';
  end if;
  raise notice 'PASS INBOX | تحویل دوباره اثر تکراری نداد (کلید = event_id)';
end $$;

-- --- DLQ: مجوز و محتوا ------------------------------------------------------
do $$
declare v_count integer;
begin
  begin
    perform 1 from sys.dlq_list('88888888-8888-8888-8888-888888888888'::uuid);
    raise exception 'FAIL DLQ: فهرست بدون مجوز خوانده شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL DLQ: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS DLQ | بدون platform.dlq.inspect → %', sqlerrm;
  end;

  select count(*) into v_count
    from sys.dlq_list('77777777-7777-7777-7777-777777777777'::uuid);
  if v_count < 1 then
    raise exception 'FAIL DLQ: با مجوز، فهرست خالی بود';
  end if;
  raise notice 'PASS DLQ | فهرست با مجوز % ردیف داد', v_count;
end $$;

-- --- اپ: بدون INSERT مستقیم، با مسیر تابع ------------------------------------
set local role fco_app;

do $$
begin
  begin
    insert into sys.outbox (aggregate_type, aggregate_id, event_name, payload)
    values ('order', gen_random_uuid(), 'order.bypass', '{}'::jsonb);
    raise exception 'FAIL APP-ROLE: درج مستقیم Outbox مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم Outbox مسدود شد';
  end;

  perform sys.outbox_emit('order', gen_random_uuid(), 'order.app_path', '{}'::jsonb);
  raise notice 'PASS APP-ROLE | تولید رویداد فقط از مسیر تابع کار کرد';
end $$;

reset role;

select 'ALL STEP-8 NEGATIVE CASES PASSED' as result;
rollback;
