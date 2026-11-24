-- =============================================================================
-- 0001_init_base — BR-1 گام ۴: Migration پایه
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §1، §3.1 (هویت)، §3.11 (پلتفرم)
-- محدوده: schemaهای `iam` و `sys` — هویت/نشست، حسابرسی، Outbox/Job، تنظیمات نسخه‌دار
--
-- خارج از این Migration (عمداً):
--   * `iam.otp_requests`            → BR-1 گام ۶ (OTP مشتری)
--   * `iam.mfa_factors`             → BR-1 گام ۵، مسدود تا تأیید ADR-007
--   * نقش کاربر اپ و GRANT           → BR-1 گام ۵ (کاربر Migration ≠ کاربر اپ)
--   * جدول‌های دامنه (cat/oms/inv…)   → BR-2 به بعد
--
-- قاعده: هر تغییر schema فقط از طریق Migration نسخه‌دار؛ اجرا: scripts/db-migrate.sh
-- =============================================================================

create extension if not exists citext;
create schema if not exists iam;
create schema if not exists sys;

comment on schema iam is 'هویت، نقش و نشست (DATABASE_DESIGN §3.1)';
comment on schema sys is 'پلتفرم: حسابرسی، Outbox، Job، تنظیمات (DATABASE_DESIGN §3.11)';

-- -----------------------------------------------------------------------------
-- توابع مشترک
-- -----------------------------------------------------------------------------

-- updated_at خودکار (فقط جدول‌های قابل‌ویرایش؛ دفترها touch نمی‌شوند)
create function sys.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- دفتر تغییرناپذیر: هیچ UPDATE/DELETE (اصل ۴ سند پایگاه داده)
create function sys.reject_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'FCO-DB-001: % روی % مجاز نیست — این دفتر فقط INSERT می‌پذیرد',
    tg_op, tg_table_name
    using errcode = 'insufficient_privilege';
end $$;

-- Outbox: بدنه رویداد قفل است، ولی Worker باید attempts/processed_at را به‌روز کند
create function sys.outbox_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'FCO-DB-002: DELETE روی sys.outbox مجاز نیست'
      using errcode = 'insufficient_privilege';
  end if;
  if new.event_name   is distinct from old.event_name
     or new.aggregate_type is distinct from old.aggregate_type
     or new.aggregate_id   is distinct from old.aggregate_id
     or new.payload        is distinct from old.payload
     or new.occurred_at    is distinct from old.occurred_at then
    raise exception 'FCO-DB-003: بدنه رویداد sys.outbox تغییرناپذیر است (id=%)', old.id
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- iam — هویت و دسترسی
-- -----------------------------------------------------------------------------

create table iam.users (
  id                    uuid primary key default gen_random_uuid(),
  mobile                varchar(11),
  email                 citext,
  full_name             text,
  password_hash         text,                      -- Argon2id؛ هرگز رمز خام
  status                text not null default 'active'
                          check (status in ('active', 'locked', 'disabled')),
  mfa_required          boolean not null default false,
  must_change_password  boolean not null default false,
  last_login_at         timestamptz,
  failed_attempts       integer not null default 0 check (failed_attempts >= 0),
  locked_until          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz,
  created_by            uuid references iam.users (id),
  updated_by            uuid references iam.users (id),
  version               integer not null default 1 check (version >= 1),
  archived_at           timestamptz,
  constraint users_mobile_format check (mobile is null or mobile ~ '^09[0-9]{9}$'),
  constraint users_identity_present check (mobile is not null or email is not null),
  constraint users_email_format check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

create unique index users_mobile_key on iam.users (mobile) where mobile is not null;
create unique index users_email_key on iam.users (email) where email is not null;
create index users_active_idx on iam.users (status) where archived_at is null;
create trigger users_touch_updated_at before update on iam.users
  for each row execute function sys.touch_updated_at();

comment on table iam.users is 'کاربران کارکنان و مشتریان؛ هویت با موبایل یا ایمیل';

create table iam.roles (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique,               -- R-ADMIN، R-WH… (USER_ROLES_AND_PERMISSIONS)
  title        text not null,
  description  text,
  is_system    boolean not null default true,       -- نقش سیستمی حذف/تغییرنام نمی‌شود
  created_at   timestamptz not null default now(),
  updated_at   timestamptz,
  -- کلید نقش مطابق USER_ROLES_AND_PERMISSIONS: R-ADMIN، R-WH_MANAGER…
  constraint roles_key_format check (key ~ '^[A-Z][A-Z0-9_-]{1,31}$')
);
create trigger roles_touch_updated_at before update on iam.roles
  for each row execute function sys.touch_updated_at();

create table iam.permissions (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique,               -- product.read، order.cancel…
  domain       text not null,                      -- cat، oms، fin…
  description  text,
  created_at   timestamptz not null default now(),
  constraint permissions_key_format check (key ~ '^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$')
);

create table iam.role_permissions (
  role_id        uuid not null references iam.roles (id) on delete cascade,
  permission_id  uuid not null references iam.permissions (id) on delete cascade,
  granted_at     timestamptz not null default now(),
  primary key (role_id, permission_id)
);

create table iam.user_roles (
  user_id     uuid not null references iam.users (id) on delete cascade,
  role_id     uuid not null references iam.roles (id) on delete restrict,
  granted_by  uuid references iam.users (id),
  granted_at  timestamptz not null default now(),
  primary key (user_id, role_id)
);

create table iam.sessions (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references iam.users (id) on delete cascade,
  token_hash     bytea not null unique,             -- هش توکن؛ هرگز مقدار خام
  ip             inet,
  user_agent     text,
  created_at     timestamptz not null default now(),
  last_seen_at   timestamptz,
  expires_at     timestamptz not null,
  revoked_at     timestamptz,
  revoke_reason  text,
  constraint sessions_expiry_after_creation check (expires_at > created_at)
);
create index sessions_user_active_idx on iam.sessions (user_id) where revoked_at is null;
create index sessions_expiry_idx on iam.sessions (expires_at);

create table iam.password_resets (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references iam.users (id) on delete cascade,
  token_hash   bytea not null unique,
  request_ip   inet,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  constraint password_resets_expiry_after_creation check (expires_at > created_at)
);
create index password_resets_user_idx on iam.password_resets (user_id)
  where consumed_at is null;

-- -----------------------------------------------------------------------------
-- sys — حسابرسی
-- -----------------------------------------------------------------------------

create table sys.audit_log (
  id           bigserial primary key,
  actor_id     uuid references iam.users (id),
  actor_ip     inet,
  action       text not null,                       -- create/update/delete/login/…
  entity_type  text not null,                       -- users، settings، orders…
  entity_id    uuid,
  before       jsonb,
  after        jsonb,
  reason       text,
  request_id   text,
  permission   text,
  created_at   timestamptz not null default now(),
  constraint audit_action_not_blank check (btrim(action) <> ''),
  constraint audit_entity_type_not_blank check (btrim(entity_type) <> ''),
  constraint audit_change_present check (before is not null or after is not null)
);
create index audit_log_entity_idx on sys.audit_log (entity_type, entity_id, created_at desc);
create index audit_log_actor_idx on sys.audit_log (actor_id, created_at desc);
create index audit_log_created_idx on sys.audit_log (created_at desc);
create trigger audit_log_immutable before update or delete on sys.audit_log
  for each row execute function sys.reject_mutation();

comment on table sys.audit_log is 'دفتر حسابرسی فقط‌افزودنی؛ تغییر/حذف با تریگر رد می‌شود';

-- -----------------------------------------------------------------------------
-- sys — Outbox و مصرف ایدم‌پوتنت (ADR-008)
-- -----------------------------------------------------------------------------

create table sys.outbox (
  id                bigserial primary key,
  aggregate_type    text not null,
  aggregate_id      uuid not null,
  event_name        text not null,
  payload           jsonb not null,
  headers           jsonb,
  occurred_at       timestamptz not null default now(),
  available_at      timestamptz not null default now(),
  attempts          integer not null default 0 check (attempts >= 0),
  processed_at      timestamptz,
  dead_lettered_at  timestamptz,
  last_error        text,
  constraint outbox_dead_letter_after_processing
    check (dead_lettered_at is null or processed_at is null)
);
create index outbox_pending_idx on sys.outbox (available_at)
  where processed_at is null and dead_lettered_at is null;
create index outbox_aggregate_idx on sys.outbox (aggregate_type, aggregate_id);
create trigger outbox_immutable before update or delete on sys.outbox
  for each row execute function sys.outbox_guard();

comment on table sys.outbox is 'صف رویداد تراکنشی (ADR-008)؛ Worker با FOR UPDATE SKIP LOCKED';

create table sys.inbox_events (
  event_id      text primary key,
  consumer      text not null,
  processed_at  timestamptz not null default now()
);

create table sys.idempotency_keys (
  key            text primary key,                  -- scope+کلید سمت کلاینت
  scope          text not null,
  request_hash   text,
  response       jsonb,
  status         text not null default 'in_progress'
                   check (status in ('in_progress', 'succeeded', 'failed')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null
);
create index idempotency_keys_expiry_idx on sys.idempotency_keys (expires_at);

create table sys.job_runs (
  id             bigserial primary key,
  job_name       text not null,
  scheduled_for  timestamptz not null,
  started_at     timestamptz,
  finished_at    timestamptz,
  status         text not null default 'running'
                   check (status in ('running', 'succeeded', 'failed')),
  attempt        integer not null default 1 check (attempt >= 1),
  error          text,
  constraint job_runs_once_per_slot unique (job_name, scheduled_for)
);

-- -----------------------------------------------------------------------------
-- sys — تنظیمات (نسخه‌دار، دارای تاریخ اعتبار)
-- -----------------------------------------------------------------------------

create table sys.settings (
  key          text primary key,
  value        jsonb not null,
  description  text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz,
  constraint settings_key_format check (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$')
);
create trigger settings_touch_updated_at before update on sys.settings
  for each row execute function sys.touch_updated_at();

comment on table sys.settings is 'مقدار جاری؛ تاریخچه و اعتبار در sys.setting_versions';

create table sys.setting_versions (
  id              bigserial primary key,
  key             text not null references sys.settings (key) on delete restrict,
  value           jsonb not null,
  effective_from  timestamptz not null,
  effective_to    timestamptz,
  changed_by      uuid references iam.users (id),
  reason          text,
  created_at      timestamptz not null default now(),
  constraint setting_versions_window check (effective_to is null or effective_to > effective_from),
  constraint setting_versions_unique_start unique (key, effective_from)
);
create index setting_versions_valid_idx on sys.setting_versions (key, effective_from desc);

comment on table sys.setting_versions is 'هیچ نرخ قانونی/مدت هارد‌کد نمی‌شود؛ اینجا با تاریخ اعتبار ثبت می‌شود';
