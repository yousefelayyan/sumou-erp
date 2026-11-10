-- =====================================================================
--  نظام السمو ERP — المرحلة 1: الأساس
--  المستخدمين، الصلاحيات، الشركات، السنوات المالية، سجل النشاط
--  طريقة التشغيل: Supabase ← SQL Editor ← New query ← الصق الملف كله ← Run
--  الملف آمن للتشغيل أكثر من مرة.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) الملفات الشخصية للمستخدمين
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  email              text,
  full_name          text,
  phone              text,
  is_admin           boolean not null default false,   -- مدير النظام: صلاحيات كاملة على كل الشركات
  is_active          boolean not null default false,   -- الحساب الجديد بيستنى موافقة المدير
  default_company_id uuid,
  created_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2) الشركات
-- ---------------------------------------------------------------------
create table if not exists public.companies (
  id                   uuid primary key default gen_random_uuid(),
  code                 text not null unique,
  name                 text not null,
  legal_name           text,
  trade_name           text,
  company_type         text,              -- فردية، تضامن، ذات مسؤولية محدودة، ...
  activity_type        text,              -- تجارية، صناعية، خدمية، ...
  currency             text not null default 'JOD',
  national_no          text,              -- الرقم الوطني للمنشأة
  commercial_reg_no    text,              -- رقم السجل التجاري
  income_tax_no        text,              -- الرقم الضريبي (ضريبة الدخل)
  sales_tax_no         text,              -- رقم ضريبة المبيعات
  subject_to_sales_tax boolean not null default false,
  sales_tax_period     text not null default 'bimonthly' check (sales_tax_period in ('monthly','bimonthly')),
  import_code          text,
  export_code          text,
  city                 text,
  address              text,
  phone                text,
  mobile               text,
  email                text,
  website              text,
  logo_url             text,
  notes                text,
  is_active            boolean not null default true,
  created_by           uuid references auth.users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_default_company_fk') then
    alter table public.profiles
      add constraint profiles_default_company_fk
      foreign key (default_company_id) references public.companies(id) on delete set null;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3) المجموعات (الأدوار) والصلاحيات
--    permissions مثال: {"companies":{"view":true,"edit":true}, "fiscal_years":{"view":true,"add":true}}
-- ---------------------------------------------------------------------
create table if not exists public.user_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  permissions jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4) ربط المستخدم بالشركات (كل موظف بيشوف بس الشركات المسموح إله فيها)
-- ---------------------------------------------------------------------
create table if not exists public.user_companies (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  group_id   uuid references public.user_groups(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, company_id)
);

-- ---------------------------------------------------------------------
-- 5) السنوات المالية
-- ---------------------------------------------------------------------
create table if not exists public.fiscal_years (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text,
  start_date date not null,
  end_date   date not null,
  is_closed  boolean not null default false,
  created_at timestamptz not null default now(),
  unique (company_id, code),
  check (end_date > start_date)
);

-- ---------------------------------------------------------------------
-- 6) سجل النشاط
-- ---------------------------------------------------------------------
create table if not exists public.activity_log (
  id         bigserial primary key,
  user_id    uuid default auth.uid(),
  company_id uuid references public.companies(id) on delete set null,
  action     text not null,      -- إضافة، تعديل، حذف، دخول ...
  entity     text,               -- اسم الشاشة/الجدول
  entity_id  text,
  details    jsonb,
  created_at timestamptz not null default now()
);
create index if not exists activity_log_created_idx on public.activity_log (created_at desc);

-- =====================================================================
--  دوال مساعدة للصلاحيات
-- =====================================================================
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_active from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin and is_active from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.has_company(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    public.is_active_user() and exists (
      select 1 from public.user_companies uc
      join public.companies c on c.id = uc.company_id and c.is_active
      where uc.user_id = auth.uid() and uc.company_id = cid
    )
  );
$$;

-- هل المستخدم بيقدر يعمل action على screen جوّا شركة معيّنة؟
create or replace function public.can(cid uuid, screen text, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    public.is_active_user() and exists (
      select 1 from public.user_companies uc
      join public.user_groups g on g.id = uc.group_id
      where uc.user_id = auth.uid() and uc.company_id = cid
        and coalesce((g.permissions -> screen ->> act)::boolean, false)
    )
  );
$$;

-- =====================================================================
--  إنشاء الملف الشخصي تلقائياً عند التسجيل
--  أول مستخدم بيسجّل بيصير مدير النظام ومفعّل تلقائياً
-- =====================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first_user boolean;
begin
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, email, full_name, is_admin, is_active)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
          first_user, first_user)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- المستخدم العادي ما بيقدر يرفع صلاحياته أو يفعّل حاله
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.is_admin  := old.is_admin;
    new.is_active := old.is_active;
    new.email     := old.email;
  end if;
  return new;
end $$;

drop trigger if exists protect_profile_fields on public.profiles;
create trigger protect_profile_fields
  before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- تحديث وقت التعديل للشركة
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

-- الموظف (غير المدير) ما بيقدر يغيّر رمز الشركة أو يوقفها
create or replace function public.protect_company_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then new.code := old.code; new.is_active := old.is_active; new.created_by := old.created_by; end if;
  return new;
end $$;
drop trigger if exists protect_company_fields on public.companies;
create trigger protect_company_fields before update on public.companies
  for each row execute function public.protect_company_fields();

drop trigger if exists companies_touch on public.companies;
create trigger companies_touch before update on public.companies
  for each row execute function public.touch_updated_at();

-- منع تعديل سنة مالية مغلقة (إلا إعادة فتحها من المدير)
create or replace function public.guard_closed_year() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.is_closed and not public.is_admin() then
    raise exception 'السنة المالية مغلقة، بس مدير النظام بيقدر يعدّلها أو يفتحها';
  end if;
  new.company_id := old.company_id;
  if (new.start_date <> old.start_date or new.end_date <> old.end_date)
     and to_regclass('public.journal_entries') is not null then
    if exists (select 1 from public.journal_entries e where e.fiscal_year_id = old.id
               and (e.entry_date < new.start_date or e.entry_date > new.end_date)) then
      raise exception 'في قيود رح تصير برّا السنة المالية إذا غيّرت التواريخ';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists fiscal_years_guard on public.fiscal_years;
create trigger fiscal_years_guard before update on public.fiscal_years
  for each row execute function public.guard_closed_year();

-- =====================================================================
--  سياسات الحماية (RLS)
-- =====================================================================
alter table public.profiles       enable row level security;
alter table public.companies      enable row level security;
alter table public.user_groups    enable row level security;
alter table public.user_companies enable row level security;
alter table public.fiscal_years   enable row level security;
alter table public.activity_log   enable row level security;

-- profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.is_admin() and id <> auth.uid());

-- companies
drop policy if exists companies_select on public.companies;
create policy companies_select on public.companies for select to authenticated
  using (public.has_company(id));
drop policy if exists companies_insert on public.companies;
create policy companies_insert on public.companies for insert to authenticated
  with check (public.is_admin());
drop policy if exists companies_update on public.companies;
create policy companies_update on public.companies for update to authenticated
  using (public.can(id, 'companies', 'edit')) with check (public.can(id, 'companies', 'edit'));
drop policy if exists companies_delete on public.companies;
create policy companies_delete on public.companies for delete to authenticated
  using (public.is_admin());

-- user_groups
drop policy if exists groups_select on public.user_groups;
create policy groups_select on public.user_groups for select to authenticated
  using (public.is_active_user());
drop policy if exists groups_write on public.user_groups;
create policy groups_write on public.user_groups for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- user_companies
drop policy if exists uc_select on public.user_companies;
create policy uc_select on public.user_companies for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists uc_write on public.user_companies;
create policy uc_write on public.user_companies for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- fiscal_years
drop policy if exists fy_select on public.fiscal_years;
create policy fy_select on public.fiscal_years for select to authenticated
  using (public.has_company(company_id));
drop policy if exists fy_insert on public.fiscal_years;
create policy fy_insert on public.fiscal_years for insert to authenticated
  with check (public.can(company_id, 'fiscal_years', 'add'));
drop policy if exists fy_update on public.fiscal_years;
create policy fy_update on public.fiscal_years for update to authenticated
  using (public.can(company_id, 'fiscal_years', 'edit')) with check (public.can(company_id, 'fiscal_years', 'edit'));
drop policy if exists fy_delete on public.fiscal_years;
create policy fy_delete on public.fiscal_years for delete to authenticated
  using (public.can(company_id, 'fiscal_years', 'delete') and not is_closed);

-- activity_log
drop policy if exists log_insert on public.activity_log;
create policy log_insert on public.activity_log for insert to authenticated
  with check (user_id = auth.uid() and public.is_active_user() and (company_id is null or public.has_company(company_id)));
drop policy if exists log_select on public.activity_log;
create policy log_select on public.activity_log for select to authenticated
  using (public.is_admin());

-- =====================================================================
--  مجموعات جاهزة للبداية (بتقدر تعدّلها من النظام)
-- =====================================================================
insert into public.user_groups (name, description, permissions) values
  ('محاسب', 'إدخال وتعديل على الشركات المسموحة',
   '{"companies":{"view":true,"edit":true,"print":true},
     "fiscal_years":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb),
  ('مدخل بيانات', 'إدخال فقط بدون تعديل بيانات الشركة',
   '{"companies":{"view":true},
     "fiscal_years":{"view":true}}'::jsonb),
  ('مشاهد', 'عرض وطباعة فقط',
   '{"companies":{"view":true,"print":true},
     "fiscal_years":{"view":true,"print":true}}'::jsonb)
on conflict (name) do nothing;

-- =====================================================================
--  صلاحيات الوصول للجداول (الحماية الفعلية من سياسات RLS فوق)
-- =====================================================================
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.companies, public.user_groups,
  public.user_companies, public.fiscal_years, public.activity_log
  to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.is_active_user(), public.is_admin(),
  public.has_company(uuid), public.can(uuid, text, text) to authenticated;

-- احتياط: إذا في حسابات انعملت قبل تشغيل هالملف، اعمل إلها ملفات شخصية
-- (أول حساب بيصير مدير النظام إذا ما في ولا ملف شخصي)
insert into public.profiles (id, email, full_name, is_admin, is_active)
select u.id, u.email,
       coalesce(u.raw_user_meta_data ->> 'full_name', split_part(u.email, '@', 1)),
       (not exists (select 1 from public.profiles)) and row_number() over (order by u.created_at) = 1,
       (not exists (select 1 from public.profiles)) and row_number() over (order by u.created_at) = 1
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

-- انتهى ✅
