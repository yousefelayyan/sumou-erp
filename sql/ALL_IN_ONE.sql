-- =====================================================================
--  نظام السمو ERP — ملف واحد فيه كل المراحل
--  الصقه كامل بـ Supabase ← SQL Editor ← New query ← Run
--  آمن للتشغيل أكثر من مرة، وما بيمسح أي بيانات موجودة.
-- =====================================================================
-- #################### 01_phase1.sql ####################
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


-- #################### 02_phase2_finance.sql ####################
-- =====================================================================
--  نظام السمو ERP — المرحلة 2: المالية
--  دليل الحسابات، القيود والسندات (قيد، قبض، صرف، افتتاحي)، الترحيل، القيد العكسي
--  طريقة التشغيل: Supabase ← SQL Editor ← New query ← الصق الملف كله ← Run
--  لازم يكون ملف المرحلة 1 مشغّل قبله. الملف آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) دليل الحسابات
-- ---------------------------------------------------------------------
create table if not exists public.accounts (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  code         text not null,
  name         text not null,
  name_en      text,
  parent_id    uuid references public.accounts(id) on delete restrict,
  level        int  not null default 1,
  is_group     boolean not null default false,          -- حساب رئيسي (تجميعي) ما بينقيّد عليه
  category     text not null check (category in ('assets','liabilities','equity','revenue','expenses')),
  nature       text not null check (nature in ('debit','credit')),
  account_type text not null default 'general' check (account_type in ('general','cash','bank','customer','supplier','employee','tax')),
  currency     text not null default 'JOD',
  is_active    boolean not null default true,
  notes        text,
  created_at   timestamptz not null default now(),
  unique (company_id, code)
);
create index if not exists accounts_company_idx on public.accounts (company_id, code);
create index if not exists accounts_parent_idx on public.accounts (parent_id);

-- ---------------------------------------------------------------------
-- 2) القيود والسندات
-- ---------------------------------------------------------------------
create table if not exists public.journal_entries (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete cascade,
  fiscal_year_id   uuid not null references public.fiscal_years(id) on delete restrict,
  entry_type       text not null check (entry_type in ('journal','receipt','payment','opening')),
  entry_no         int,
  entry_date       date not null,
  description      text,
  reference        text,                 -- رقم مرجع / رقم شيك / رقم فاتورة
  party_name       text,                 -- استلمنا من / صرفنا إلى
  cash_account_id  uuid references public.accounts(id) on delete restrict,  -- الصندوق أو البنك بسندات القبض والصرف
  status           text not null default 'draft' check (status in ('draft','posted','reversed')),
  total            numeric(18,3) not null default 0,
  reversal_of      uuid references public.journal_entries(id) on delete set null,
  reversed_by      uuid references public.journal_entries(id) on delete set null,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  posted_by        uuid,
  posted_at        timestamptz,
  unique (company_id, fiscal_year_id, entry_type, entry_no)
);
create index if not exists je_company_idx on public.journal_entries (company_id, fiscal_year_id, entry_type, entry_no desc);

create table if not exists public.journal_lines (
  id          uuid primary key default gen_random_uuid(),
  entry_id    uuid not null references public.journal_entries(id) on delete cascade,
  line_no     int not null default 1,
  account_id  uuid not null references public.accounts(id) on delete restrict,
  description text,
  debit       numeric(18,3) not null default 0 check (debit  >= 0),
  credit      numeric(18,3) not null default 0 check (credit >= 0),
  check (not (debit > 0 and credit > 0)),
  check (debit > 0 or credit > 0)
);
create index if not exists jl_entry_idx on public.journal_lines (entry_id);
create index if not exists jl_account_idx on public.journal_lines (account_id);

-- =====================================================================
--  دوال مساعدة
-- =====================================================================
-- اسم شاشة الصلاحيات حسب نوع السند
create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances' end;
$$;

create or replace function public.can_entry(eid uuid, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.journal_entries e
                 where e.id = eid and public.can(e.company_id, public.entry_screen(e.entry_type), act));
$$;

-- السماح المؤقت للدوال الداخلية (الترحيل والعكس) بتعديل قيود مرحّلة
-- المفتاح سرّي بجدول محمي، فما حدا بيقدر يزوّر الإذن من برّا
create table if not exists public.internal_key (k text not null);
alter table public.internal_key enable row level security;
revoke all on public.internal_key from public, anon, authenticated;
insert into public.internal_key (k) select md5(gen_random_uuid()::text || clock_timestamp()::text)
 where not exists (select 1 from public.internal_key);

create or replace function public.internal_token() returns text
language sql stable security definer set search_path = public as $$ select k from public.internal_key limit 1; $$;
revoke execute on function public.internal_token() from public, anon, authenticated;

create or replace function public.is_internal() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_setting('sumou.internal', true), '') = public.internal_token();
$$;

-- =====================================================================
--  حماية دليل الحسابات
-- =====================================================================
create or replace function public.accounts_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.accounts;
begin
  if new.parent_id is not null then
    select * into p from public.accounts where id = new.parent_id;
    if p.id is null or p.company_id <> new.company_id then raise exception 'الحساب الرئيسي غير موجود بنفس الشركة'; end if;
    if not p.is_group then raise exception 'ما بتقدر تضيف حساب تحت حساب فرعي. خلّي الحساب الأب «رئيسي» أول'; end if;
    if tg_op = 'UPDATE' and exists (
         with recursive up as (select id, parent_id from public.accounts where id = new.parent_id
                               union all select a.id, a.parent_id from public.accounts a join up on a.id = up.parent_id)
         select 1 from up where id = new.id) then
      raise exception 'ما بيصير الحساب يكون تحت واحد من فروعه';
    end if;
    new.level := p.level + 1;
    new.category := p.category;     -- الحساب بيرث تصنيف أبوه
  else
    new.level := 1;
  end if;
  if tg_op = 'UPDATE' then
    if old.is_group and not new.is_group and exists (select 1 from public.accounts where parent_id = new.id) then
      raise exception 'الحساب إله حسابات فرعية، ما بيصير يتحوّل لحساب فرعي';
    end if;
    if not old.is_group and new.is_group and exists (select 1 from public.journal_lines where account_id = new.id) then
      raise exception 'الحساب عليه حركات، ما بيصير يتحوّل لحساب رئيسي';
    end if;
    new.company_id := old.company_id;
  end if;
  return new;
end $$;

drop trigger if exists accounts_before on public.accounts;
create trigger accounts_before before insert or update on public.accounts
  for each row execute function public.accounts_before();

-- تغيير تصنيف حساب رئيسي بينزل على كل فروعه
create or replace function public.accounts_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category is distinct from old.category then
    update public.accounts set category = new.category where parent_id = new.id and category is distinct from new.category;
  end if;
  return null;
end $$;
drop trigger if exists accounts_after on public.accounts;
create trigger accounts_after after update on public.accounts
  for each row execute function public.accounts_after();

-- =====================================================================
--  حماية القيود
-- =====================================================================
create or replace function public.entries_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; ca public.accounts;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' and not public.is_internal() then raise exception 'القيد مرحّل، ما بينحذف. اعمل قيد عكسي'; end if;
    return old;
  end if;

  if not public.is_internal() then
    if tg_op = 'UPDATE' and old.status <> 'draft' then
      raise exception 'القيد مرحّل، ما بينعدّل. اعمل قيد عكسي';
    end if;
    if new.status <> 'draft' then
      raise exception 'الترحيل بس من زر «ترحيل» (بيتأكد إن القيد متوازن)';
    end if;
    -- حقول بتتعبّى من النظام بس
    if tg_op = 'UPDATE' then
      new.total := old.total; new.reversal_of := old.reversal_of; new.reversed_by := old.reversed_by;
      new.posted_by := old.posted_by; new.posted_at := old.posted_at; new.entry_type := old.entry_type;
    else
      new.total := 0; new.reversal_of := null; new.reversed_by := null; new.posted_by := null; new.posted_at := null;
      if new.entry_type = 'invoice' then raise exception 'قيود الفواتير بتنعمل من الفاتورة نفسها'; end if;
    end if;
  end if;

  select * into fy from public.fiscal_years where id = new.fiscal_year_id;
  if fy.id is null or fy.company_id <> new.company_id then raise exception 'السنة المالية مش لهالشركة'; end if;
  if fy.is_closed and not public.is_internal() then raise exception 'السنة المالية مغلقة، ما بتقدر تضيف أو تعدّل قيود فيها'; end if;
  if new.entry_date < fy.start_date or new.entry_date > fy.end_date then
    raise exception 'تاريخ القيد لازم يكون جوّا السنة المالية (% إلى %)', fy.start_date, fy.end_date;
  end if;

  if new.entry_type in ('receipt','payment') and not public.is_internal() then
    if new.cash_account_id is null then raise exception 'اختار حساب الصندوق أو البنك'; end if;
    select * into ca from public.accounts where id = new.cash_account_id;
    if ca.company_id <> new.company_id or ca.is_group then raise exception 'حساب الصندوق/البنك لازم يكون حساب فرعي بنفس الشركة'; end if;
  end if;

  if tg_op = 'INSERT' then
    if new.entry_no is null then
      select coalesce(max(entry_no), 0) + 1 into new.entry_no from public.journal_entries
       where company_id = new.company_id and fiscal_year_id = new.fiscal_year_id and entry_type = new.entry_type;
    end if;
    new.created_by := coalesce(new.created_by, auth.uid());
  else
    new.company_id := old.company_id;
    new.created_by := old.created_by;
  end if;
  return new;
end $$;

drop trigger if exists entries_before on public.journal_entries;
create trigger entries_before before insert or update or delete on public.journal_entries
  for each row execute function public.entries_before();

create or replace function public.lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; a public.accounts; eid uuid;
begin
  if tg_op in ('UPDATE','DELETE') and not public.is_internal() then   -- القيد الأصلي للسطر
    select * into e from public.journal_entries where id = old.entry_id;
    if e.id is not null and e.status <> 'draft' then raise exception 'القيد مرحّل، ما بتقدر تعدّل سطوره'; end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  select * into e from public.journal_entries where id = new.entry_id;
  if e.id is not null and e.status <> 'draft' and not public.is_internal() then
    raise exception 'القيد مرحّل، ما بتقدر تعدّل سطوره';
  end if;
  select * into a from public.accounts where id = new.account_id;
  if a.id is null or a.company_id <> e.company_id then raise exception 'الحساب مش لهالشركة'; end if;
  if a.is_group then raise exception 'الحساب «% - %» حساب رئيسي، اختار حساب فرعي', a.code, a.name; end if;
  if not a.is_active and e.entry_type <> 'opening' and not public.is_internal() then raise exception 'الحساب «% - %» موقوف', a.code, a.name; end if;
  return new;
end $$;

drop trigger if exists lines_before on public.journal_lines;
create trigger lines_before before insert or update or delete on public.journal_lines
  for each row execute function public.lines_before();

-- =====================================================================
--  الترحيل والقيد العكسي
-- =====================================================================
create or replace function public.post_entry(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; d numeric; c numeric; n int; fy public.fiscal_years;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'post') then raise exception 'ما عندك صلاحية ترحيل'; end if;
  if e.status <> 'draft' then raise exception 'القيد مرحّل من قبل'; end if;
  select * into fy from public.fiscal_years where id = e.fiscal_year_id;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
  select coalesce(sum(debit),0), coalesce(sum(credit),0), count(*) into d, c, n from public.journal_lines where entry_id = p_id;
  if n < 2 then raise exception 'القيد لازم يكون فيه سطرين على الأقل'; end if;
  if d <> c then raise exception 'القيد مش متوازن: المدين % والدائن %', d, c; end if;
  if d = 0 then raise exception 'القيد بدون مبالغ'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'ترحيل', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', e.entry_no, 'total', d));
end $$;

create or replace function public.reverse_entry(p_id uuid, p_date date default current_date, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; fy public.fiscal_years; new_id uuid; d numeric;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'post') then raise exception 'ما عندك صلاحية'; end if;
  if e.status <> 'posted' then raise exception 'بس القيود المرحّلة بتنعكس'; end if;
  if e.entry_type = 'opening' then raise exception 'القيد الافتتاحي ما بينعكس. عدّل الأرصدة بقيد يومية'; end if;
  if e.entry_type = 'invoice' then raise exception 'قيد الفاتورة بينلغى من الفاتورة نفسها (زر إلغاء الفاتورة)'; end if;
  if e.entry_type = 'closing' then raise exception 'قيد الإقفال بينلغى بإعادة فتح السنة'; end if;
  select * into fy from public.fiscal_years
   where company_id = e.company_id and p_date between start_date and end_date and not is_closed
   order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, reversal_of)
  values (e.company_id, fy.id, e.entry_type, p_date,
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || coalesce(e.doc_code, e.entry_no::text) || coalesce(' - ' || e.description, '')),
          e.reference, e.party_name, e.cash_account_id, 'draft', e.id)
  returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
  select new_id, line_no, account_id, description, credit, debit from public.journal_lines where entry_id = p_id;
  select coalesce(sum(debit),0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = p_id;
  perform set_config('sumou.internal', '', true);

  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'قيد عكسي', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', e.entry_no, 'reversal', new_id));
  return new_id;
end $$;

-- =====================================================================
--  أرصدة الحسابات (من القيود المرحّلة فقط)
-- =====================================================================
create or replace view public.account_balances with (security_invoker = true) as
select e.company_id, e.fiscal_year_id, l.account_id,
       sum(l.debit)  as debit,
       sum(l.credit) as credit
from public.journal_lines l
join public.journal_entries e on e.id = l.entry_id
where e.status in ('posted','reversed')
group by e.company_id, e.fiscal_year_id, l.account_id;

-- =====================================================================
--  دليل حسابات أردني جاهز
-- =====================================================================
create or replace function public.seed_default_accounts(p_company uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; pid uuid; cnt int := 0;
begin
  if not public.can(p_company, 'accounts', 'add') then raise exception 'ما عندك صلاحية'; end if;
  if exists (select 1 from public.accounts where company_id = p_company) then
    raise exception 'الشركة إلها دليل حسابات من قبل';
  end if;
  for r in
    select * from (values
      ('1','الموجودات','assets','debit',true,'general'),
      ('11','الموجودات المتداولة','assets','debit',true,'general'),
      ('1101','النقد في الصندوق','assets','debit',false,'cash'),
      ('1102','النقد لدى البنوك','assets','debit',false,'bank'),
      ('1103','الذمم المدينة (العملاء)','assets','debit',false,'customer'),
      ('1104','شيكات برسم التحصيل','assets','debit',false,'general'),
      ('1105','المخزون','assets','debit',false,'general'),
      ('1106','مصاريف مدفوعة مقدماً','assets','debit',false,'general'),
      ('1107','ذمم الموظفين','assets','debit',false,'employee'),
      ('1108','ضريبة المبيعات - مدخلات','assets','debit',false,'tax'),
      ('1109','ضريبة دخل مدفوعة مقدماً','assets','debit',false,'tax'),
      ('12','الموجودات غير المتداولة','assets','debit',true,'general'),
      ('1201','أراضي','assets','debit',false,'general'),
      ('1202','مباني','assets','debit',false,'general'),
      ('1203','أثاث ومفروشات','assets','debit',false,'general'),
      ('1204','أجهزة ومعدات','assets','debit',false,'general'),
      ('1205','سيارات','assets','debit',false,'general'),
      ('1206','أجهزة حاسوب وبرمجيات','assets','debit',false,'general'),
      ('1209','مجمع الاستهلاك','assets','credit',false,'general'),
      ('2','المطلوبات','liabilities','credit',true,'general'),
      ('21','المطلوبات المتداولة','liabilities','credit',true,'general'),
      ('2101','الذمم الدائنة (الموردين)','liabilities','credit',false,'supplier'),
      ('2102','شيكات آجلة الدفع','liabilities','credit',false,'general'),
      ('2103','ضريبة المبيعات - مخرجات','liabilities','credit',false,'tax'),
      ('2104','أمانات ضريبة الدخل','liabilities','credit',false,'tax'),
      ('2105','أمانات الضمان الاجتماعي','liabilities','credit',false,'general'),
      ('2106','رواتب مستحقة','liabilities','credit',false,'general'),
      ('2107','مصاريف مستحقة','liabilities','credit',false,'general'),
      ('2108','إيرادات مقبوضة مقدماً','liabilities','credit',false,'general'),
      ('2109','جاري الشركاء','liabilities','credit',false,'general'),
      ('22','المطلوبات طويلة الأجل','liabilities','credit',true,'general'),
      ('2201','قروض بنكية طويلة الأجل','liabilities','credit',false,'general'),
      ('2202','مخصص تعويض نهاية الخدمة','liabilities','credit',false,'general'),
      ('3','حقوق الملكية','equity','credit',true,'general'),
      ('31','رأس المال والاحتياطيات','equity','credit',true,'general'),
      ('3101','رأس المال','equity','credit',false,'general'),
      ('3102','الاحتياطي الإجباري','equity','credit',false,'general'),
      ('3103','الأرباح المدورة','equity','credit',false,'general'),
      ('3104','أرباح وخسائر السنة','equity','credit',false,'general'),
      ('3105','المسحوبات الشخصية','equity','debit',false,'general'),
      ('4','الإيرادات','revenue','credit',true,'general'),
      ('41','إيرادات النشاط','revenue','credit',true,'general'),
      ('4101','المبيعات','revenue','credit',false,'general'),
      ('4102','مردودات ومسموحات المبيعات','revenue','debit',false,'general'),
      ('4103','الخصم المسموح به','revenue','debit',false,'general'),
      ('4104','إيرادات الخدمات','revenue','credit',false,'general'),
      ('42','إيرادات أخرى','revenue','credit',true,'general'),
      ('4201','إيرادات متنوعة','revenue','credit',false,'general'),
      ('4202','الخصم المكتسب','revenue','credit',false,'general'),
      ('4203','أرباح بيع موجودات','revenue','credit',false,'general'),
      ('5','المصاريف','expenses','debit',true,'general'),
      ('51','تكلفة المبيعات','expenses','debit',true,'general'),
      ('5101','المشتريات','expenses','debit',false,'general'),
      ('5102','مردودات المشتريات','expenses','credit',false,'general'),
      ('5103','مصاريف نقل المشتريات','expenses','debit',false,'general'),
      ('5104','تكلفة البضاعة المباعة','expenses','debit',false,'general'),
      ('52','المصاريف الإدارية والعمومية','expenses','debit',true,'general'),
      ('5201','الرواتب والأجور','expenses','debit',false,'general'),
      ('5202','مساهمة المنشأة في الضمان الاجتماعي','expenses','debit',false,'general'),
      ('5203','الإيجار','expenses','debit',false,'general'),
      ('5204','الكهرباء والمياه','expenses','debit',false,'general'),
      ('5205','الهاتف والإنترنت','expenses','debit',false,'general'),
      ('5206','القرطاسية والمطبوعات','expenses','debit',false,'general'),
      ('5207','الصيانة','expenses','debit',false,'general'),
      ('5208','المحروقات','expenses','debit',false,'general'),
      ('5209','رسوم ورخص واشتراكات','expenses','debit',false,'general'),
      ('5210','أتعاب مهنية وتدقيق','expenses','debit',false,'general'),
      ('5211','الضيافة والنظافة','expenses','debit',false,'general'),
      ('5212','مصاريف وعمولات بنكية','expenses','debit',false,'general'),
      ('5213','الاستهلاكات','expenses','debit',false,'general'),
      ('5214','مصاريف متنوعة','expenses','debit',false,'general'),
      ('53','مصاريف البيع والتسويق','expenses','debit',true,'general'),
      ('5301','الدعاية والإعلان','expenses','debit',false,'general'),
      ('5302','عمولات المبيعات','expenses','debit',false,'general'),
      ('5303','مصاريف التوصيل','expenses','debit',false,'general'),
      ('54','مصاريف أخرى','expenses','debit',true,'general'),
      ('5401','فوائد بنكية','expenses','debit',false,'general'),
      ('5402','ضريبة الدخل','expenses','debit',false,'tax')
    ) as t(code, name, category, nature, is_group, account_type)
    order by length(code), code
  loop
    pid := null;
    if length(r.code) > 1 then
      select id into pid from public.accounts
       where company_id = p_company and code = case when length(r.code) = 2 then left(r.code, 1) else left(r.code, 2) end;
    end if;
    insert into public.accounts (company_id, code, name, parent_id, is_group, category, nature, account_type)
    values (p_company, r.code, r.name, pid, r.is_group, r.category, r.nature, r.account_type);
    cnt := cnt + 1;
  end loop;
  insert into public.activity_log (user_id, company_id, action, entity, details)
  values (auth.uid(), p_company, 'إضافة', 'accounts', jsonb_build_object('name', 'دليل الحسابات الجاهز', 'count', cnt));
  return cnt;
end $$;

-- =====================================================================
--  سياسات الحماية (RLS)
-- =====================================================================
alter table public.accounts        enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines   enable row level security;

drop policy if exists acc_select on public.accounts;
create policy acc_select on public.accounts for select to authenticated using (public.has_company(company_id));
drop policy if exists acc_insert on public.accounts;
create policy acc_insert on public.accounts for insert to authenticated with check (public.can(company_id, 'accounts', 'add'));
drop policy if exists acc_update on public.accounts;
create policy acc_update on public.accounts for update to authenticated
  using (public.can(company_id, 'accounts', 'edit')) with check (public.can(company_id, 'accounts', 'edit'));
drop policy if exists acc_delete on public.accounts;
create policy acc_delete on public.accounts for delete to authenticated using (public.can(company_id, 'accounts', 'delete'));

drop policy if exists je_select on public.journal_entries;
create policy je_select on public.journal_entries for select to authenticated
  using (public.can(company_id, public.entry_screen(entry_type), 'view'));
drop policy if exists je_insert on public.journal_entries;
create policy je_insert on public.journal_entries for insert to authenticated
  with check (public.can(company_id, public.entry_screen(entry_type), 'add'));
drop policy if exists je_update on public.journal_entries;
create policy je_update on public.journal_entries for update to authenticated
  using (public.can(company_id, public.entry_screen(entry_type), 'edit'))
  with check (public.can(company_id, public.entry_screen(entry_type), 'edit'));
drop policy if exists je_delete on public.journal_entries;
create policy je_delete on public.journal_entries for delete to authenticated
  using (public.can(company_id, public.entry_screen(entry_type), 'delete'));

drop policy if exists jl_select on public.journal_lines;
create policy jl_select on public.journal_lines for select to authenticated using (public.can_entry(entry_id, 'view'));
drop policy if exists jl_insert on public.journal_lines;
create policy jl_insert on public.journal_lines for insert to authenticated
  with check (public.can_entry(entry_id, 'add') or public.can_entry(entry_id, 'edit'));
drop policy if exists jl_update on public.journal_lines;
create policy jl_update on public.journal_lines for update to authenticated
  using (public.can_entry(entry_id, 'edit')) with check (public.can_entry(entry_id, 'edit'));
drop policy if exists jl_delete on public.journal_lines;
create policy jl_delete on public.journal_lines for delete to authenticated
  using (public.can_entry(entry_id, 'edit') or public.can_entry(entry_id, 'delete'));

grant select, insert, update, delete on public.accounts, public.journal_entries, public.journal_lines to authenticated;
grant select on public.account_balances to authenticated;
grant execute on function public.post_entry(uuid), public.reverse_entry(uuid, date, text),
  public.seed_default_accounts(uuid), public.entry_screen(text), public.can_entry(uuid, text) to authenticated;
revoke execute on function public.post_entry(uuid), public.reverse_entry(uuid, date, text), public.seed_default_accounts(uuid) from anon;

-- =====================================================================
--  إضافة صلاحيات المالية للمجموعات الجاهزة (بدون ما نلمس تعديلاتك)
-- =====================================================================
update public.user_groups set permissions = permissions
  || jsonb_build_object(
       'accounts',         coalesce(permissions -> 'accounts',         '{"view":true,"add":true,"edit":true,"print":true}'::jsonb),
       'journal_entries',  coalesce(permissions -> 'journal_entries',  '{"view":true,"add":true,"edit":true,"delete":true,"print":true}'::jsonb),
       'receipt_vouchers', coalesce(permissions -> 'receipt_vouchers', '{"view":true,"add":true,"edit":true,"delete":true,"print":true}'::jsonb),
       'payment_vouchers', coalesce(permissions -> 'payment_vouchers', '{"view":true,"add":true,"edit":true,"delete":true,"print":true}'::jsonb),
       'opening_balances', coalesce(permissions -> 'opening_balances', '{"view":true,"add":true,"edit":true,"print":true}'::jsonb))
 where name = 'محاسب' and not (permissions ? 'journal_entries');

update public.user_groups set permissions = permissions
  || jsonb_build_object(
       'accounts',         coalesce(permissions -> 'accounts',         '{"view":true}'::jsonb),
       'journal_entries',  coalesce(permissions -> 'journal_entries',  '{"view":true,"add":true,"edit":true}'::jsonb),
       'receipt_vouchers', coalesce(permissions -> 'receipt_vouchers', '{"view":true,"add":true,"edit":true}'::jsonb),
       'payment_vouchers', coalesce(permissions -> 'payment_vouchers', '{"view":true,"add":true,"edit":true}'::jsonb))
 where name = 'مدخل بيانات' and not (permissions ? 'journal_entries');

update public.user_groups set permissions = permissions
  || jsonb_build_object(
       'accounts',         coalesce(permissions -> 'accounts',         '{"view":true,"print":true}'::jsonb),
       'journal_entries',  coalesce(permissions -> 'journal_entries',  '{"view":true,"print":true}'::jsonb),
       'receipt_vouchers', coalesce(permissions -> 'receipt_vouchers', '{"view":true,"print":true}'::jsonb),
       'payment_vouchers', coalesce(permissions -> 'payment_vouchers', '{"view":true,"print":true}'::jsonb),
       'opening_balances', coalesce(permissions -> 'opening_balances', '{"view":true,"print":true}'::jsonb))
 where name = 'مشاهد' and not (permissions ? 'journal_entries');

-- انتهى ✅


-- #################### 03_phase3_reports.sql ####################
-- =====================================================================
--  نظام السمو ERP — المرحلة 3: التقارير المالية
--  كشف الحساب، اليومية العامة، ميزان المراجعة (وعليه قائمة الدخل والميزانية)
--  التقارير بتقرأ القيود المرحّلة فقط، وبتحتاج صلاحية «التقارير المالية ← عرض»
--  لازم ملفات المرحلة 1 و2 يكونوا مشغّلين قبله. آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- كشف حساب: حركات حساب (أو حساب رئيسي مع كل فروعه) بفترة جوّا سنة مالية
drop function if exists public.rep_ledger(uuid, uuid, uuid, date, date);
create or replace function public.rep_ledger(p_company uuid, p_fy uuid, p_account uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text,
               line_description text, reference text, account_code text, account_name text, debit numeric, credit numeric, doc_code text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  with recursive tree as (
    select a.id from public.accounts a where a.id = p_account and a.company_id = p_company
    union all
    select c.id from public.accounts c join tree t on c.parent_id = t.id
  )
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, l.description, e.reference,
         a.code, a.name, l.debit, l.credit, e.doc_code
  from public.journal_lines l
  join public.journal_entries e on e.id = l.entry_id
  join public.accounts a on a.id = l.account_id
  where l.account_id in (select id from tree)
    and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed')
    and e.entry_date between p_from and p_to
  order by e.entry_date, case e.entry_type when 'opening' then 0 else 1 end, e.created_at, l.line_no;
end $$;

-- الرصيد قبل تاريخ معيّن (جوّا نفس السنة المالية، شامل القيد الافتتاحي)
create or replace function public.rep_balance_before(p_company uuid, p_fy uuid, p_account uuid, p_date date)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare r numeric;
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  with recursive tree as (
    select a.id from public.accounts a where a.id = p_account and a.company_id = p_company
    union all
    select c.id from public.accounts c join tree t on c.parent_id = t.id
  )
  select coalesce(sum(l.debit - l.credit), 0) into r
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.account_id in (select id from tree)
    and e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date < p_date;
  return r;
end $$;

-- ميزان المراجعة: لكل حساب فرعي: رصيد أول المدة، حركة الفترة، (الإقفال بيتحسب بالواجهة)
create or replace function public.rep_trial_balance(p_company uuid, p_fy uuid, p_from date, p_to date)
returns table (account_id uuid, open_debit numeric, open_credit numeric, period_debit numeric, period_credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.account_id,
         coalesce(sum(l.debit)  filter (where e.entry_date < p_from or e.entry_type = 'opening'), 0),
         coalesce(sum(l.credit) filter (where e.entry_date < p_from or e.entry_type = 'opening'), 0),
         coalesce(sum(l.debit)  filter (where e.entry_date >= p_from and e.entry_type <> 'opening'), 0),
         coalesce(sum(l.credit) filter (where e.entry_date >= p_from and e.entry_type <> 'opening'), 0)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date <= p_to
    and e.entry_type <> 'closing'      -- قيد الإقفال ما بيدخل بالميزان (القوائم بتحسب الربح لحالها)
  group by l.account_id;
end $$;

-- اليومية العامة: كل القيود المرحّلة بالفترة مع سطورها
drop function if exists public.rep_journal(uuid, uuid, date, date, text);
create or replace function public.rep_journal(p_company uuid, p_fy uuid, p_from date, p_to date, p_type text default null)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text, reference text, party_name text,
               status text, line_no int, account_code text, account_name text, line_description text, debit numeric, credit numeric, doc_code text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, e.reference, e.party_name, e.status,
         l.line_no, a.code, a.name, l.description, l.debit, l.credit, e.doc_code
  from public.journal_entries e
  join public.journal_lines l on l.entry_id = e.id
  join public.accounts a on a.id = l.account_id
  where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed')
    and e.entry_date between p_from and p_to and (p_type is null or e.entry_type = p_type)
  order by e.entry_date, case e.entry_type when 'opening' then 0 else 1 end, e.entry_type, e.entry_no, l.line_no;
end $$;

grant execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_balance_before(uuid, uuid, uuid, date),
  public.rep_trial_balance(uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text) to authenticated;
revoke execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_balance_before(uuid, uuid, uuid, date),
  public.rep_trial_balance(uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text) from anon;

-- صلاحية التقارير للمجموعات الجاهزة
update public.user_groups set permissions = permissions || '{"reports":{"view":true,"print":true}}'::jsonb
 where name in ('محاسب', 'مشاهد') and not (permissions ? 'reports');

-- انتهى ✅


-- #################### 04_phase4_parties.sql ####################
-- =====================================================================
--  نظام السمو ERP — المرحلة 4: الزبائن والموردين
--  بطاقات العملاء والموردين، ربطهم بسطور القيود، كشف حساب الطرف، أعمار الذمم
--  لازم ملفات المراحل 1 و2 و3 يكونوا مشغّلين قبله. آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.parties (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete cascade,
  party_type         text not null check (party_type in ('customer','supplier')),
  code               text not null,
  name               text not null,
  trade_name         text,
  tax_no             text,              -- الرقم الضريبي
  national_no        text,              -- الرقم الوطني (منشأة أو شخص)
  contact_person     text,
  phone              text,
  mobile             text,
  email              text,
  city               text,
  address            text,
  account_id         uuid not null references public.accounts(id) on delete restrict,  -- الحساب الإجمالي (ذمم مدينة / دائنة)
  credit_limit       numeric(18,3) not null default 0,   -- سقف الائتمان (0 = بدون سقف)
  payment_terms_days int not null default 0,             -- مدة السداد بالأيام
  is_active          boolean not null default true,
  notes              text,
  created_at         timestamptz not null default now(),
  unique (company_id, party_type, code)
);
create index if not exists parties_company_idx on public.parties (company_id, party_type, code);

alter table public.journal_lines add column if not exists party_id uuid references public.parties(id) on delete restrict;
create index if not exists jl_party_idx on public.journal_lines (party_id);

-- رقم تلقائي للعميل/المورد + التحقق من الحساب
create or replace function public.parties_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.accounts; n int;
begin
  select * into a from public.accounts where id = new.account_id;
  if a.id is null or a.company_id <> new.company_id then raise exception 'الحساب مش لهالشركة'; end if;
  if a.is_group then raise exception 'حساب الطرف لازم يكون حساب فرعي'; end if;
  if tg_op = 'INSERT' and (new.code is null or new.code = '') then
    select coalesce(max(nullif(regexp_replace(code, '\D', '', 'g'), '')::int), 0) + 1 into n
      from public.parties where company_id = new.company_id and party_type = new.party_type;
    new.code := case new.party_type when 'customer' then 'C' else 'S' end || lpad(n::text, 4, '0');
  end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.party_type := old.party_type; end if;
  return new;
end $$;
drop trigger if exists parties_before on public.parties;
create trigger parties_before before insert or update on public.parties
  for each row execute function public.parties_before();

-- سطر القيد مع طرف: لازم الطرف من نفس الشركة
create or replace function public.lines_party_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.parties; e public.journal_entries;
begin
  if new.party_id is null then return new; end if;
  select * into p from public.parties where id = new.party_id;
  select * into e from public.journal_entries where id = new.entry_id;
  if p.id is null or p.company_id <> e.company_id then raise exception 'العميل/المورد مش لهالشركة'; end if;
  return new;
end $$;
drop trigger if exists lines_party_check on public.journal_lines;
create trigger lines_party_check before insert or update on public.journal_lines
  for each row execute function public.lines_party_check();

-- أرصدة الأطراف (مرحّل فقط)
create or replace view public.party_balances with (security_invoker = true) as
select e.company_id, e.fiscal_year_id, l.party_id, sum(l.debit) as debit, sum(l.credit) as credit
from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
where e.status in ('posted','reversed') and l.party_id is not null
group by e.company_id, e.fiscal_year_id, l.party_id;

-- كشف حساب عميل/مورد
drop function if exists public.rep_party_ledger(uuid, uuid, uuid, date, date);
create or replace function public.rep_party_ledger(p_company uuid, p_fy uuid, p_party uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text, line_description text,
               reference text, debit numeric, credit numeric, doc_code text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, l.description, e.reference, l.debit, l.credit, e.doc_code
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.party_id = p_party and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed') and e.entry_date between p_from and p_to
  order by e.entry_date, case e.entry_type when 'opening' then 0 else 1 end, e.created_at, l.line_no;
end $$;

create or replace function public.rep_party_balance_before(p_company uuid, p_fy uuid, p_party uuid, p_date date)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare r numeric;
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into r
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.party_id = p_party and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed') and e.entry_date < p_date;
  return r;
end $$;

-- حركات كل الأطراف من نوع معيّن لغاية تاريخ (لحساب أعمار الذمم بالواجهة)
create or replace function public.rep_party_movements(p_company uuid, p_fy uuid, p_type text, p_to date)
returns table (party_id uuid, entry_date date, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.party_id, e.entry_date, sum(l.debit), sum(l.credit)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  join public.parties p on p.id = l.party_id
  where p.party_type = p_type and e.company_id = p_company and e.fiscal_year_id = p_fy
    and e.status in ('posted','reversed') and e.entry_date <= p_to
  group by l.party_id, e.entry_date
  order by l.party_id, e.entry_date;
end $$;

-- القيد العكسي لازم ينسخ الطرف كمان
create or replace function public.reverse_entry(p_id uuid, p_date date default current_date, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; fy public.fiscal_years; new_id uuid; d numeric;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'post') then raise exception 'ما عندك صلاحية'; end if;
  if e.status <> 'posted' then raise exception 'بس القيود المرحّلة بتنعكس'; end if;
  if e.entry_type = 'opening' then raise exception 'القيد الافتتاحي ما بينعكس. عدّل الأرصدة بقيد يومية'; end if;
  if e.entry_type = 'invoice' then raise exception 'قيد الفاتورة بينلغى من الفاتورة نفسها (زر إلغاء الفاتورة)'; end if;
  if e.entry_type = 'closing' then raise exception 'قيد الإقفال بينلغى بإعادة فتح السنة'; end if;
  if e.entry_type = 'stock' then raise exception 'قيد المخزون مربوط بسند المخزون وما بينعكس لحاله'; end if;
  select * into fy from public.fiscal_years
   where company_id = e.company_id and p_date between start_date and end_date and not is_closed
   order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, reversal_of)
  values (e.company_id, fy.id, e.entry_type, p_date,
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || coalesce(e.doc_code, e.entry_no::text) || coalesce(' - ' || e.description, '')),
          e.reference, e.party_name, e.cash_account_id, 'draft', e.id)
  returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  select new_id, line_no, account_id, party_id, description, credit, debit from public.journal_lines where entry_id = p_id;
  select coalesce(sum(debit),0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = p_id;
  perform set_config('sumou.internal', '', true);

  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'قيد عكسي', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', e.entry_no, 'reversal', new_id));
  return new_id;
end $$;

-- الحماية
alter table public.parties enable row level security;
drop policy if exists parties_select on public.parties;
create policy parties_select on public.parties for select to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'view')
         or public.has_company(company_id));
drop policy if exists parties_insert on public.parties;
create policy parties_insert on public.parties for insert to authenticated
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'add'));
drop policy if exists parties_update on public.parties;
create policy parties_update on public.parties for update to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'))
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'));
drop policy if exists parties_delete on public.parties;
create policy parties_delete on public.parties for delete to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'delete'));

grant select, insert, update, delete on public.parties to authenticated;
grant select on public.party_balances to authenticated;
grant execute on function public.rep_party_ledger(uuid, uuid, uuid, date, date), public.rep_party_balance_before(uuid, uuid, uuid, date),
  public.rep_party_movements(uuid, uuid, text, date) to authenticated;

-- صلاحيات جاهزة
update public.user_groups set permissions = permissions
  || '{"customers":{"view":true,"add":true,"edit":true,"print":true},"suppliers":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb
 where name in ('محاسب', 'مدخل بيانات') and not (permissions ? 'customers');
update public.user_groups set permissions = permissions
  || '{"customers":{"view":true,"print":true},"suppliers":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'customers');

-- انتهى ✅


-- #################### 05_phase5_invoices.sql ####################
-- =====================================================================
--  نظام السمو ERP — المرحلة 5 و6: الفواتير وضريبة المبيعات
--  حسابات الربط، الأصناف والخدمات، فواتير البيع والشراء والمرتجعات،
--  قيد تلقائي عند الترحيل، إلغاء الفاتورة بقيد عكسي، تقرير إقرار ضريبة المبيعات
--  لازم ملفات المراحل 1-4 يكونوا مشغّلين قبله. آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- نوع قيد جديد للفواتير
alter table public.journal_entries drop constraint if exists journal_entries_entry_type_check;
alter table public.journal_entries add constraint journal_entries_entry_type_check
  check (entry_type in ('journal','receipt','payment','opening','invoice','closing','cheque','stock','payroll','depreciation'));

create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances'
                when 'invoice' then 'journal_entries' when 'closing' then 'journal_entries' when 'cheque' then 'journal_entries' when 'stock' then 'journal_entries' when 'payroll' then 'journal_entries' when 'depreciation' then 'journal_entries' end;
$$;

-- ---------------------------------------------------------------------
-- 1) حسابات الربط وإعدادات الضريبة لكل شركة
-- ---------------------------------------------------------------------
create table if not exists public.company_settings (
  company_id                  uuid primary key references public.companies(id) on delete cascade,
  default_tax_rate            numeric(6,3) not null default 16,
  sales_account_id            uuid references public.accounts(id) on delete set null,
  sales_return_account_id     uuid references public.accounts(id) on delete set null,
  purchase_account_id         uuid references public.accounts(id) on delete set null,
  purchase_return_account_id  uuid references public.accounts(id) on delete set null,
  output_tax_account_id       uuid references public.accounts(id) on delete set null,   -- ضريبة المبيعات - مخرجات
  input_tax_account_id        uuid references public.accounts(id) on delete set null,   -- ضريبة المبيعات - مدخلات
  cash_account_id             uuid references public.accounts(id) on delete set null,
  invoice_footer              text,
  updated_at                  timestamptz not null default now()
);

-- تعبئة تلقائية من أرقام الدليل الجاهز إذا موجودة
create or replace function public.ensure_company_settings(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  insert into public.company_settings (company_id) values (p_company) on conflict do nothing;
  update public.company_settings s set
    sales_account_id           = coalesce(s.sales_account_id,           (select id from public.accounts where company_id = p_company and code = '4101' and not is_group)),
    sales_return_account_id    = coalesce(s.sales_return_account_id,    (select id from public.accounts where company_id = p_company and code = '4102' and not is_group)),
    purchase_account_id        = coalesce(s.purchase_account_id,        (select id from public.accounts where company_id = p_company and code = '5101' and not is_group)),
    purchase_return_account_id = coalesce(s.purchase_return_account_id, (select id from public.accounts where company_id = p_company and code = '5102' and not is_group)),
    output_tax_account_id      = coalesce(s.output_tax_account_id,      (select id from public.accounts where company_id = p_company and code = '2103' and not is_group)),
    input_tax_account_id       = coalesce(s.input_tax_account_id,       (select id from public.accounts where company_id = p_company and code = '1108' and not is_group)),
    cash_account_id            = coalesce(s.cash_account_id,            (select id from public.accounts where company_id = p_company and code = '1101' and not is_group))
  where s.company_id = p_company;
end $$;

-- ---------------------------------------------------------------------
-- 2) الأصناف والخدمات
-- ---------------------------------------------------------------------
create table if not exists public.items (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete cascade,
  code                text not null,
  name                text not null,
  item_type           text not null default 'goods' check (item_type in ('goods','service')),
  unit                text default 'حبة',
  barcode             text,
  sale_price          numeric(18,3) not null default 0,
  purchase_price      numeric(18,3) not null default 0,
  tax_rate            numeric(6,3) not null default 16,
  sales_account_id    uuid references public.accounts(id) on delete set null,
  purchase_account_id uuid references public.accounts(id) on delete set null,
  is_active           boolean not null default true,
  notes               text,
  created_at          timestamptz not null default now(),
  unique (company_id, code)
);

-- ---------------------------------------------------------------------
-- 3) الفواتير
-- ---------------------------------------------------------------------
create table if not exists public.invoices (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete cascade,
  fiscal_year_id      uuid not null references public.fiscal_years(id) on delete restrict,
  inv_type            text not null check (inv_type in ('sale','sale_return','purchase','purchase_return')),
  inv_no              int,
  inv_date            date not null,
  due_date            date,
  payment_type        text not null default 'credit' check (payment_type in ('cash','credit')),
  party_id            uuid references public.parties(id) on delete restrict,
  party_name          text,             -- لبيع نقدي بدون بطاقة عميل
  cash_account_id     uuid references public.accounts(id) on delete restrict,
  reference           text,             -- رقم فاتورة المورد / رقم الطلب
  original_invoice_id uuid references public.invoices(id) on delete set null,   -- للمرتجعات
  prices_include_tax  boolean not null default false,
  notes               text,
  subtotal            numeric(18,3) not null default 0,
  discount_total      numeric(18,3) not null default 0,
  tax_total           numeric(18,3) not null default 0,
  total               numeric(18,3) not null default 0,
  status              text not null default 'draft' check (status in ('draft','posted','cancelled')),
  entry_id            uuid references public.journal_entries(id) on delete set null,
  cancel_entry_id     uuid references public.journal_entries(id) on delete set null,
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  posted_at           timestamptz,
  unique (company_id, fiscal_year_id, inv_type, inv_no)
);
create index if not exists invoices_company_idx on public.invoices (company_id, fiscal_year_id, inv_type, inv_no desc);

create table if not exists public.invoice_lines (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  line_no     int not null default 1,
  item_id     uuid references public.items(id) on delete set null,
  description text,
  qty         numeric(18,3) not null default 1 check (qty > 0),
  unit_price  numeric(18,3) not null default 0 check (unit_price >= 0),
  discount    numeric(18,3) not null default 0 check (discount >= 0),
  tax_rate    numeric(6,3) not null default 16 check (tax_rate >= 0),
  account_id  uuid references public.accounts(id) on delete restrict,
  subtotal    numeric(18,3) not null default 0,   -- قبل الضريبة
  tax_amount  numeric(18,3) not null default 0,
  line_total  numeric(18,3) not null default 0
);
create index if not exists invoice_lines_inv_idx on public.invoice_lines (invoice_id);

create or replace function public.invoice_screen(t text) returns text
language sql immutable as $$ select case when t in ('sale','sale_return') then 'sales_invoices' else 'purchase_invoices' end; $$;

create or replace function public.can_invoice(iid uuid, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.invoices i where i.id = iid and public.can(i.company_id, public.invoice_screen(i.inv_type), act));
$$;

-- حماية الفاتورة: الترقيم، السنة المالية، المرحّلة ما بتنعدّل
create or replace function public.invoices_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; p public.parties;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then raise exception 'الفاتورة مرحّلة، ما بتنحذف. ألغيها بدل الحذف'; end if;
    return old;
  end if;
  if not public.is_internal() then
    if tg_op = 'UPDATE' and old.status <> 'draft' then raise exception 'الفاتورة مرحّلة، ما بتنعدّل'; end if;
    if new.status <> 'draft' then raise exception 'الترحيل بس من زر «ترحيل»'; end if;
    if tg_op = 'UPDATE' then
      new.entry_id := old.entry_id; new.cancel_entry_id := old.cancel_entry_id; new.posted_at := old.posted_at;
    else
      new.entry_id := null; new.cancel_entry_id := null; new.posted_at := null;
    end if;
  end if;
  select * into fy from public.fiscal_years where id = new.fiscal_year_id;
  if fy.id is null or fy.company_id <> new.company_id then raise exception 'السنة المالية مش لهالشركة'; end if;
  if fy.is_closed and not public.is_internal() then raise exception 'السنة المالية مغلقة'; end if;
  if new.inv_date < fy.start_date or new.inv_date > fy.end_date then raise exception 'تاريخ الفاتورة لازم يكون جوّا السنة المالية'; end if;
  if new.party_id is not null then
    select * into p from public.parties where id = new.party_id;
    if p.company_id <> new.company_id then raise exception 'العميل/المورد مش لهالشركة'; end if;
    if new.inv_type in ('sale','sale_return') and p.party_type <> 'customer' then raise exception 'فاتورة البيع لازم تكون لعميل'; end if;
    if new.inv_type in ('purchase','purchase_return') and p.party_type <> 'supplier' then raise exception 'فاتورة الشراء لازم تكون لمورد'; end if;
  end if;
  if tg_op = 'INSERT' then
    if new.inv_no is null then
      select coalesce(max(inv_no), 0) + 1 into new.inv_no from public.invoices
       where company_id = new.company_id and fiscal_year_id = new.fiscal_year_id and inv_type = new.inv_type;
    end if;
  else
    new.company_id := old.company_id; new.inv_type := old.inv_type; new.created_by := old.created_by;
  end if;
  return new;
end $$;
drop trigger if exists invoices_before on public.invoices;
create trigger invoices_before before insert or update or delete on public.invoices
  for each row execute function public.invoices_before();

create or replace function public.invoice_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare i public.invoices; iid uuid;
begin
  if tg_op in ('UPDATE','DELETE') and not public.is_internal() then
    select * into i from public.invoices where id = old.invoice_id;
    if i.id is not null and i.status <> 'draft' then raise exception 'الفاتورة مرحّلة، ما بتنعدّل سطورها'; end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  select * into i from public.invoices where id = new.invoice_id;
  if i.id is not null and i.status <> 'draft' and not public.is_internal() then raise exception 'الفاتورة مرحّلة، ما بتنعدّل سطورها'; end if;
  return new;
end $$;
drop trigger if exists invoice_lines_before on public.invoice_lines;
create trigger invoice_lines_before before insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_lines_before();

-- =====================================================================
--  ترحيل الفاتورة: حساب المبالغ من جديد + إنشاء قيد مرحّل
-- =====================================================================
create or replace function public.post_invoice(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  i public.invoices; st public.company_settings; p public.parties; r record;
  eid uuid; ln int := 0; s_sub numeric := 0; s_tax numeric := 0; s_disc numeric := 0; gross numeric; sub numeric; tax numeric;
  is_sale boolean; is_return boolean; party_acc uuid; tax_acc uuid; acc uuid; sgn int; descr text;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'post') then raise exception 'ما عندك صلاحية ترحيل الفواتير'; end if;
  if i.status <> 'draft' then raise exception 'الفاتورة مرحّلة من قبل'; end if;
  perform public.ensure_company_settings(i.company_id);
  select * into st from public.company_settings where company_id = i.company_id;
  if i.original_invoice_id is not null then   -- المرتجع لازم يكون من فاتورة مرحّلة لنفس الطرف
    if not exists (select 1 from public.invoices o where o.id = i.original_invoice_id and o.company_id = i.company_id
                   and o.status = 'posted' and o.inv_type = replace(i.inv_type, '_return', '')
                   and o.party_id is not distinct from i.party_id) then
      raise exception 'الفاتورة الأصلية للمرتجع مش صحيحة (لازم تكون مرحّلة، ولنفس العميل/المورد)';
    end if;
  end if;
  is_sale := i.inv_type in ('sale','sale_return');
  is_return := i.inv_type in ('sale_return','purchase_return');
  sgn := case when is_return then -1 else 1 end;    -- البيع: الطرف مدين / الشراء: الطرف دائن (والمرتجع بالعكس)

  -- حساب الطرف
  if i.payment_type = 'credit' then
    if i.party_id is null then raise exception 'الفاتورة الآجلة لازم يكون إلها % ', case when is_sale then 'عميل' else 'مورد' end; end if;
    select * into p from public.parties where id = i.party_id;
    party_acc := p.account_id;
  else
    party_acc := coalesce(i.cash_account_id, st.cash_account_id);
    if party_acc is null then raise exception 'اختار حساب الصندوق/البنك للفاتورة النقدية'; end if;
  end if;
  tax_acc := case when is_sale then st.output_tax_account_id else st.input_tax_account_id end;

  -- إعادة حساب السطور
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.invoice_lines where invoice_id = p_id order by line_no loop
    gross := round(r.qty * r.unit_price - r.discount, 3);
    if gross < 0 then raise exception 'الخصم أكبر من قيمة السطر %', r.line_no; end if;
    if i.prices_include_tax then sub := round(gross / (1 + r.tax_rate / 100), 3); tax := gross - sub;
    else sub := gross; tax := round(sub * r.tax_rate / 100, 3); end if;
    update public.invoice_lines set subtotal = sub, tax_amount = tax, line_total = sub + tax where id = r.id;
    s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + r.discount;
  end loop;
  if s_sub + s_tax <= 0 then raise exception 'الفاتورة بدون مبالغ'; end if;

  -- المرتجع ما بيتجاوز الفاتورة الأصلية (بالكمية لكل صنف، وبالقيمة للسطور بدون صنف)
  if i.original_invoice_id is not null then
    for r in
      select g.k, g.nm, g.oq, g.os,
             coalesce((select sum(case when rl.item_id is not null then rl.qty else rl.subtotal end) from public.invoice_lines rl
                       join public.invoices ri on ri.id = rl.invoice_id
                       where ri.original_invoice_id = i.original_invoice_id and ri.status = 'posted' and ri.id <> i.id
                         and coalesce(rl.item_id::text, '') = g.k), 0) as prev
      from (select coalesce(o.item_id::text, '') as k, max(coalesce(it.name, 'السطور بدون صنف')) as nm,
                   sum(o.qty) as oq, sum(o.subtotal) as os
            from public.invoice_lines o left join public.items it on it.id = o.item_id
            where o.invoice_id = i.original_invoice_id group by 1) g
    loop
      if ((select coalesce(sum(case when r.k <> '' then l.qty else l.subtotal end), 0) from public.invoice_lines l
          where l.invoice_id = p_id and coalesce(l.item_id::text, '') = r.k) + r.prev
         > (case when r.k <> '' then r.oq else r.os end) + 0.0005) then
        raise exception 'المرتجع أكثر من الفاتورة الأصلية: «%»', r.nm;
      end if;
    end loop;
    if exists (select 1 from public.invoice_lines l where l.invoice_id = p_id and l.item_id is not null
               and not exists (select 1 from public.invoice_lines o where o.invoice_id = i.original_invoice_id and o.item_id = l.item_id)) then
      raise exception 'في صنف بالمرتجع مش موجود بالفاتورة الأصلية';
    end if;
  end if;
  if s_tax > 0 and tax_acc is null then raise exception 'حدّد حساب ضريبة المبيعات بشاشة «حسابات الربط»'; end if;

  descr := case i.inv_type when 'sale' then 'فاتورة بيع' when 'sale_return' then 'مرتجع بيع' when 'purchase' then 'فاتورة شراء' else 'مرتجع شراء' end
           || ' رقم ' || coalesce(i.doc_code, i.inv_no::text) || coalesce(' - ' || coalesce(p.name, i.party_name), '');

  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, status)
  values (i.company_id, i.fiscal_year_id, 'invoice', i.inv_date, descr, i.reference, coalesce(p.name, i.party_name), 'draft')
  returning id into eid;

  -- سطر الطرف (عميل/مورد/صندوق)
  ln := ln + 1;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  values (eid, ln, party_acc, case when i.payment_type = 'credit' then i.party_id end, descr,
          case when (is_sale and not is_return) or (not is_sale and is_return) then s_sub + s_tax else 0 end,
          case when (is_sale and is_return) or (not is_sale and not is_return) then s_sub + s_tax else 0 end);

  -- سطور الإيراد/المصروف (مجمّعة حسب الحساب)
  for r in
    select coalesce(case when is_return then coalesce(case when is_sale then st.sales_return_account_id else st.purchase_return_account_id end, l.account_id) else l.account_id end,
                    case when is_sale then st.sales_account_id else st.purchase_account_id end) as acc_id,
           sum(l.subtotal) as amt
    from public.invoice_lines l where l.invoice_id = p_id group by 1
  loop
    if r.acc_id is null then raise exception 'حدّد حساب % بشاشة «حسابات الربط»', case when is_sale then 'المبيعات' else 'المشتريات' end; end if;
    if r.amt = 0 then continue; end if;
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (eid, ln, r.acc_id, descr,
            case when (is_sale and is_return) or (not is_sale and not is_return) then r.amt else 0 end,
            case when (is_sale and not is_return) or (not is_sale and is_return) then r.amt else 0 end);
  end loop;

  -- سطر الضريبة
  if s_tax > 0 then
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (eid, ln, tax_acc, 'ضريبة المبيعات - ' || descr,
            case when (is_sale and is_return) or (not is_sale and not is_return) then s_tax else 0 end,
            case when (is_sale and not is_return) or (not is_sale and is_return) then s_tax else 0 end);
  end if;

  update public.journal_entries set status = 'posted', total = s_sub + s_tax, posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.invoices set status = 'posted', subtotal = s_sub, tax_total = s_tax, discount_total = s_disc, total = s_sub + s_tax,
         entry_id = eid, posted_at = now() where id = p_id;
  perform set_config('sumou.internal', '', true);

  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, 'ترحيل', public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', i.inv_no, 'total', s_sub + s_tax));
  return eid;
end $$;

-- إلغاء فاتورة مرحّلة (قيد عكسي بنفس تاريخ الإلغاء)
create or replace function public.cancel_invoice(p_id uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; fy public.fiscal_years; new_id uuid; d numeric;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'post') then raise exception 'ما عندك صلاحية'; end if;
  if i.status <> 'posted' then raise exception 'بس الفواتير المرحّلة بتنلغى'; end if;
  if not exists (select 1 from public.journal_entries where id = i.entry_id and company_id = i.company_id and status = 'posted') then
    raise exception 'قيد الفاتورة مش مرحّل أو انعكس من قبل';
  end if;
  select * into fy from public.fiscal_years where company_id = i.company_id and p_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status, reversal_of)
  select company_id, fy.id, 'invoice', p_date, 'إلغاء: ' || description, reference, 'draft', id from public.journal_entries where id = i.entry_id
  returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  select new_id, line_no, account_id, party_id, description, credit, debit from public.journal_lines where entry_id = i.entry_id;
  select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = i.entry_id;
  update public.invoices set status = 'cancelled', cancel_entry_id = new_id where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, 'إلغاء', public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', i.inv_no));
end $$;

-- =====================================================================
--  تقرير ضريبة المبيعات (للإقرار): المبيعات والمشتريات حسب النسبة
-- =====================================================================
create or replace function public.rep_sales_tax(p_company uuid, p_from date, p_to date)
returns table (inv_type text, tax_rate numeric, invoices bigint, subtotal numeric, tax numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select i.inv_type, l.tax_rate, count(distinct i.id), sum(l.subtotal), sum(l.tax_amount)
  from public.invoices i join public.invoice_lines l on l.invoice_id = i.id
  where i.company_id = p_company and i.status = 'posted' and i.inv_date between p_from and p_to
  group by i.inv_type, l.tax_rate order by i.inv_type, l.tax_rate desc;
end $$;

-- =====================================================================
--  الحماية
-- =====================================================================
alter table public.company_settings enable row level security;
alter table public.items enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;

drop policy if exists cs_select on public.company_settings;
create policy cs_select on public.company_settings for select to authenticated using (public.has_company(company_id));
drop policy if exists cs_write on public.company_settings;
create policy cs_write on public.company_settings for all to authenticated
  using (public.can(company_id, 'companies', 'edit')) with check (public.can(company_id, 'companies', 'edit'));

drop policy if exists items_select on public.items;
create policy items_select on public.items for select to authenticated using (public.has_company(company_id));
drop policy if exists items_insert on public.items;
create policy items_insert on public.items for insert to authenticated with check (public.can(company_id, 'items', 'add'));
drop policy if exists items_update on public.items;
create policy items_update on public.items for update to authenticated
  using (public.can(company_id, 'items', 'edit')) with check (public.can(company_id, 'items', 'edit'));
drop policy if exists items_delete on public.items;
create policy items_delete on public.items for delete to authenticated using (public.can(company_id, 'items', 'delete'));

drop policy if exists inv_select on public.invoices;
create policy inv_select on public.invoices for select to authenticated using (public.can(company_id, public.invoice_screen(inv_type), 'view'));
drop policy if exists inv_insert on public.invoices;
create policy inv_insert on public.invoices for insert to authenticated with check (public.can(company_id, public.invoice_screen(inv_type), 'add'));
drop policy if exists inv_update on public.invoices;
create policy inv_update on public.invoices for update to authenticated
  using (public.can(company_id, public.invoice_screen(inv_type), 'edit')) with check (public.can(company_id, public.invoice_screen(inv_type), 'edit'));
drop policy if exists inv_delete on public.invoices;
create policy inv_delete on public.invoices for delete to authenticated using (public.can(company_id, public.invoice_screen(inv_type), 'delete'));

drop policy if exists invl_select on public.invoice_lines;
create policy invl_select on public.invoice_lines for select to authenticated using (public.can_invoice(invoice_id, 'view'));
drop policy if exists invl_insert on public.invoice_lines;
create policy invl_insert on public.invoice_lines for insert to authenticated with check (public.can_invoice(invoice_id, 'add') or public.can_invoice(invoice_id, 'edit'));
drop policy if exists invl_update on public.invoice_lines;
create policy invl_update on public.invoice_lines for update to authenticated using (public.can_invoice(invoice_id, 'edit')) with check (public.can_invoice(invoice_id, 'edit'));
drop policy if exists invl_delete on public.invoice_lines;
create policy invl_delete on public.invoice_lines for delete to authenticated using (public.can_invoice(invoice_id, 'edit') or public.can_invoice(invoice_id, 'delete'));

grant select, insert, update, delete on public.company_settings, public.items, public.invoices, public.invoice_lines to authenticated;
grant execute on function public.post_invoice(uuid), public.cancel_invoice(uuid, date), public.rep_sales_tax(uuid, date, date),
  public.ensure_company_settings(uuid), public.invoice_screen(text), public.can_invoice(uuid, text) to authenticated;

-- صلاحيات جاهزة
update public.user_groups set permissions = permissions
  || '{"items":{"view":true,"add":true,"edit":true,"print":true},
       "sales_invoices":{"view":true,"add":true,"edit":true,"delete":true,"print":true},
       "purchase_invoices":{"view":true,"add":true,"edit":true,"delete":true,"print":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'sales_invoices');
update public.user_groups set permissions = permissions
  || '{"items":{"view":true},"sales_invoices":{"view":true,"add":true,"edit":true},"purchase_invoices":{"view":true,"add":true,"edit":true}}'::jsonb
 where name = 'مدخل بيانات' and not (permissions ? 'sales_invoices');
update public.user_groups set permissions = permissions
  || '{"items":{"view":true},"sales_invoices":{"view":true,"print":true},"purchase_invoices":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'sales_invoices');

-- انتهى ✅


-- #################### 06_phase9_obligations.sql ####################
-- =====================================================================
--  نظام السمو ERP — متابعة إقرارات العملاء ومواعيدها
--  التزامات كل شركة (ضريبة مبيعات، ضريبة دخل، اقتطاعات، ضمان اجتماعي، تجديدات...)
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.obligations (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  ob_type       text not null check (ob_type in ('sales_tax','income_tax','withholding','social_security','registration','license','audit','other')),
  title         text not null,
  period_label  text,                -- مثل: كانون الثاني - شباط 2026
  period_start  date,
  period_end    date,
  due_date      date not null,
  status        text not null default 'pending' check (status in ('pending','done','not_required')),
  done_date     date,
  amount        numeric(18,3),
  reference     text,                -- رقم الإقرار / رقم الإيصال
  assigned_to   uuid references public.profiles(id) on delete set null,
  notes         text,
  auto_key      text,                -- لمنع التكرار عند التوليد التلقائي
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, auto_key)
);
create index if not exists obligations_due_idx on public.obligations (due_date);

-- توليد الالتزامات السنوية لشركة حسب بياناتها (المواعيد افتراضية وبتنعدّل)
create or replace function public.generate_obligations(p_company uuid, p_year int, p_social boolean default true, p_withholding boolean default true)
returns int
language plpgsql security definer set search_path = public as $$
declare c public.companies; n int := 0; i int; ps date; pe date; months text[] :=
  array['كانون الثاني','شباط','آذار','نيسان','أيار','حزيران','تموز','آب','أيلول','تشرين الأول','تشرين الثاني','كانون الأول'];
begin
  if not public.can(p_company, 'obligations', 'add') then raise exception 'ما عندك صلاحية'; end if;
  select * into c from public.companies where id = p_company;
  select count(*) into n from public.obligations where company_id = p_company;

  -- إقرار ضريبة الدخل السنوي عن السنة السابقة: آخر موعد 30 نيسان
  insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
  values (p_company, 'income_tax', 'إقرار ضريبة الدخل السنوي', 'السنة المالية ' || (p_year - 1),
          make_date(p_year - 1, 1, 1), make_date(p_year - 1, 12, 31), make_date(p_year, 4, 30), 'IT-' || (p_year - 1))
  on conflict (company_id, auto_key) do nothing;

  -- ضريبة المبيعات: خلال 30 يوم من نهاية الفترة
  if c.subject_to_sales_tax then
    if c.sales_tax_period = 'monthly' then
      for i in 1..12 loop
        ps := make_date(p_year, i, 1); pe := (ps + interval '1 month - 1 day')::date;
        insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
        values (p_company, 'sales_tax', 'إقرار ضريبة المبيعات', months[i] || ' ' || p_year, ps, pe, pe + 30, 'ST-' || p_year || '-' || i)
        on conflict (company_id, auto_key) do nothing;
      end loop;
    else
      for i in 1..6 loop
        ps := make_date(p_year, i * 2 - 1, 1); pe := (ps + interval '2 month - 1 day')::date;
        insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
        values (p_company, 'sales_tax', 'إقرار ضريبة المبيعات', months[i * 2 - 1] || ' - ' || months[i * 2] || ' ' || p_year, ps, pe, pe + 30, 'ST-' || p_year || '-B' || i)
        on conflict (company_id, auto_key) do nothing;
      end loop;
    end if;
  end if;

  for i in 1..12 loop
    ps := make_date(p_year, i, 1); pe := (ps + interval '1 month - 1 day')::date;
    if p_withholding then   -- الاقتطاعات (رواتب/خدمات): خلال 30 يوم
      insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
      values (p_company, 'withholding', 'كشف الاقتطاعات الشهري', months[i] || ' ' || p_year, ps, pe, pe + 30, 'WH-' || p_year || '-' || i)
      on conflict (company_id, auto_key) do nothing;
    end if;
    if p_social then        -- الضمان الاجتماعي: لغاية 15 من الشهر اللي بعده
      insert into public.obligations (company_id, ob_type, title, period_label, period_start, period_end, due_date, auto_key)
      values (p_company, 'social_security', 'اشتراكات الضمان الاجتماعي', months[i] || ' ' || p_year, ps, pe, (pe + 15), 'SS-' || p_year || '-' || i)
      on conflict (company_id, auto_key) do nothing;
    end if;
  end loop;

  n := (select count(*) from public.obligations where company_id = p_company) - n;
  insert into public.activity_log (user_id, company_id, action, entity, details)
  values (auth.uid(), p_company, 'توليد', 'obligations', jsonb_build_object('year', p_year));
  return n;
end $$;

alter table public.obligations enable row level security;
drop policy if exists ob_select on public.obligations;
create policy ob_select on public.obligations for select to authenticated using (public.can(company_id, 'obligations', 'view'));
drop policy if exists ob_insert on public.obligations;
create policy ob_insert on public.obligations for insert to authenticated with check (public.can(company_id, 'obligations', 'add'));
drop policy if exists ob_update on public.obligations;
create policy ob_update on public.obligations for update to authenticated
  using (public.can(company_id, 'obligations', 'edit')) with check (public.can(company_id, 'obligations', 'edit'));
drop policy if exists ob_delete on public.obligations;
create policy ob_delete on public.obligations for delete to authenticated using (public.can(company_id, 'obligations', 'delete'));

grant select, insert, update, delete on public.obligations to authenticated;
grant execute on function public.generate_obligations(uuid, int, boolean, boolean) to authenticated;

update public.user_groups set permissions = permissions || '{"obligations":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'obligations');
update public.user_groups set permissions = permissions || '{"obligations":{"view":true,"print":true}}'::jsonb
 where name in ('مدخل بيانات', 'مشاهد') and not (permissions ? 'obligations');

-- انتهى ✅


-- #################### 07_fixes_permissions.sql ####################
-- =====================================================================
--  نظام السمو ERP — إضافة صلاحية «ترحيل» لمجموعة المحاسب الجاهزة
--  (بس إذا ما انحددت من قبل). مدير النظام إله كل الصلاحيات دائماً.
-- =====================================================================
update public.user_groups g set permissions = (
  select jsonb_object_agg(k, case when k in ('journal_entries','receipt_vouchers','payment_vouchers','opening_balances','sales_invoices','purchase_invoices')
                                   and not (v ? 'post') then v || '{"post":true}'::jsonb else v end)
  from jsonb_each(g.permissions) as t(k, v))
where g.name = 'محاسب' and g.permissions <> '{}'::jsonb;

-- انتهى ✅


-- #################### 08_year_end.sql ####################
-- =====================================================================
--  نظام السمو ERP — إغلاق السنة المالية وتدوير الأرصدة
--  قيد إقفال الإيرادات والمصاريف للأرباح المدورة + قيد افتتاحي تلقائي للسنة الجديدة
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.journal_entries drop constraint if exists journal_entries_entry_type_check;
alter table public.journal_entries add constraint journal_entries_entry_type_check
  check (entry_type in ('journal','receipt','payment','opening','invoice','closing','cheque','stock','payroll','depreciation'));

create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances'
                when 'invoice' then 'journal_entries' when 'closing' then 'journal_entries' when 'cheque' then 'journal_entries' when 'stock' then 'journal_entries' when 'payroll' then 'journal_entries' when 'depreciation' then 'journal_entries' end;
$$;

-- منع إنشاء قيد إقفال من برّا (بس من دالة الإغلاق)
create or replace function public.entries_type_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.entry_type = 'closing' and not public.is_internal() then raise exception 'قيد الإقفال بينعمل من زر «إغلاق السنة» بس'; end if;
  if new.entry_type = 'stock' and not public.is_internal() then raise exception 'قيد المخزون بينعمل من سند المخزون بس'; end if;
  if new.entry_type in ('payroll','depreciation') and not public.is_internal() then raise exception 'هالقيد بينعمل من شاشته (الرواتب أو الأصول) بس'; end if;
  return new;
end $$;
drop trigger if exists entries_type_guard on public.journal_entries;
create trigger entries_type_guard before insert or update on public.journal_entries
  for each row execute function public.entries_type_guard();

-- ---------------------------------------------------------------------
--  إغلاق السنة
-- ---------------------------------------------------------------------
create or replace function public.close_fiscal_year(p_fy uuid, p_next_fy uuid, p_retained uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; nfy public.fiscal_years; ra public.accounts; drafts int; cid uuid; nid uuid; oid uuid;
  ln int := 0; net numeric := 0; r record; old_open public.journal_entries; d numeric;
begin
  if not public.is_admin() then raise exception 'إغلاق السنة لمدير النظام بس'; end if;
  select * into fy from public.fiscal_years where id = p_fy;
  select * into nfy from public.fiscal_years where id = p_next_fy;
  if fy.id is null or nfy.id is null or nfy.company_id <> fy.company_id then raise exception 'اختار السنة الجديدة لنفس الشركة'; end if;
  if fy.is_closed then raise exception 'السنة مغلقة من قبل'; end if;
  if nfy.is_closed then raise exception 'السنة الجديدة مغلقة'; end if;
  if nfy.start_date <= fy.end_date then raise exception 'السنة الجديدة لازم تبلّش بعد نهاية السنة اللي بتنغلق'; end if;
  select * into ra from public.accounts where id = p_retained;
  if ra.id is null or ra.company_id <> fy.company_id or ra.is_group or ra.category <> 'equity' then
    raise exception 'حساب الأرباح المدورة لازم يكون حساب فرعي من حقوق الملكية';
  end if;
  select count(*) into drafts from public.journal_entries where fiscal_year_id = p_fy and status = 'draft';
  if drafts > 0 then raise exception 'في % قيد/سند مسودة بهالسنة. رحّلهم أو احذفهم قبل الإغلاق', drafts; end if;
  if to_regclass('public.invoices') is not null then
    select count(*) into drafts from public.invoices where fiscal_year_id = p_fy and status = 'draft';
    if drafts > 0 then raise exception 'في % فاتورة مسودة بهالسنة. رحّلها أو احذفها قبل الإغلاق', drafts; end if;
  end if;

  -- القيد الافتتاحي بالسنة الجديدة: إذا انعمل تلقائياً من قبل بنستبدله، وإذا يدوي ومرحّل بنوقف
  select * into old_open from public.journal_entries where fiscal_year_id = p_next_fy and entry_type = 'opening' and status <> 'reversed' order by created_at desc limit 1;
  if old_open.id is not null and old_open.status = 'posted' and coalesce(old_open.reference, '') <> 'AUTO-CLOSE' then
    raise exception 'السنة الجديدة إلها أرصدة افتتاحية مرحّلة (مدخلة يدوياً). احذفها أو اعكسها قبل التدوير';
  end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  if old_open.id is not null then delete from public.journal_entries where id = old_open.id; end if;

  -- 1) قيد الإقفال: تصفير الإيرادات والمصاريف على الأرباح المدورة
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (fy.company_id, p_fy, 'closing', fy.end_date, 'قيد إقفال ' || coalesce(fy.name, fy.code), 'AUTO-CLOSE', 'draft')
  returning id into cid;
  for r in
    select l.account_id, l.party_id, sum(l.debit - l.credit) as bal
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    where e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and e.id <> cid and a.category in ('revenue','expenses')
    group by l.account_id, l.party_id having abs(sum(l.debit - l.credit)) > 0.0005
  loop
    ln := ln + 1; net := net + r.bal;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (cid, ln, r.account_id, r.party_id, 'إقفال', case when r.bal < 0 then -r.bal else 0 end, case when r.bal > 0 then r.bal else 0 end);
  end loop;
  if ln > 0 and abs(net) > 0.0005 then
    ln := ln + 1;   -- net موجب = مصاريف أكثر = خسارة
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (cid, ln, p_retained, case when net > 0 then 'خسارة السنة' else 'ربح السنة' end,
            case when net > 0 then net else 0 end, case when net < 0 then -net else 0 end);
  end if;
  if ln = 0 then delete from public.journal_entries where id = cid; cid := null;
  else
    select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = cid;
    update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = cid;
  end if;

  -- 2) القيد الافتتاحي للسنة الجديدة: أرصدة الموجودات والمطلوبات وحقوق الملكية (مع العملاء والموردين)
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (fy.company_id, p_next_fy, 'opening', nfy.start_date, 'أرصدة مدوّرة من ' || coalesce(fy.name, fy.code), 'AUTO-CLOSE', 'draft')
  returning id into oid;
  ln := 0;
  for r in
    select l.account_id, l.party_id, sum(l.debit - l.credit) as bal
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
    where e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.category in ('assets','liabilities','equity')
    group by l.account_id, l.party_id having abs(sum(l.debit - l.credit)) > 0.0005
    order by 1
  loop
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (oid, ln, r.account_id, r.party_id, 'رصيد مدوّر', case when r.bal > 0 then r.bal else 0 end, case when r.bal < 0 then -r.bal else 0 end);
  end loop;
  if ln = 0 then delete from public.journal_entries where id = oid; oid := null;
  else
    select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = oid;
    if abs(d - (select coalesce(sum(credit), 0) from public.journal_lines where entry_id = oid)) > 0.0005 then
      raise exception 'الأرصدة المدوّرة مش متوازنة. راجع ميزان المراجعة للسنة';
    end if;
    update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = oid;
  end if;

  update public.fiscal_years set is_closed = true where id = p_fy;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), fy.company_id, 'إغلاق السنة', 'fiscal_years', p_fy::text, jsonb_build_object('next', p_next_fy, 'net', -net));
  return jsonb_build_object('closing_entry', cid, 'opening_entry', oid, 'profit', -net);
end $$;

-- إعادة فتح سنة: بيحذف قيد الإقفال والأرصدة المدوّرة التلقائية بالسنة اللي بعدها
create or replace function public.reopen_fiscal_year(p_fy uuid) returns void
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years;
begin
  if not public.is_admin() then raise exception 'إعادة فتح السنة لمدير النظام بس'; end if;
  select * into fy from public.fiscal_years where id = p_fy;
  if fy.id is null then raise exception 'السنة غير موجودة'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  delete from public.journal_entries where fiscal_year_id = p_fy and entry_type = 'closing';
  delete from public.journal_entries e using public.fiscal_years n
   where e.fiscal_year_id = n.id and n.company_id = fy.company_id and n.start_date > fy.end_date
     and e.entry_type = 'opening' and e.reference = 'AUTO-CLOSE' and e.description = 'أرصدة مدوّرة من ' || coalesce(fy.name, fy.code);
  update public.fiscal_years set is_closed = false where id = p_fy;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id)
  values (auth.uid(), fy.company_id, 'إعادة فتح السنة', 'fiscal_years', p_fy::text);
end $$;

grant execute on function public.close_fiscal_year(uuid, uuid, uuid), public.reopen_fiscal_year(uuid) to authenticated;

-- انتهى ✅


-- #################### 09_cheques.sql ####################
-- =====================================================================
--  نظام السمو ERP — محفظة الشيكات
--  شيكات واردة (من العملاء) وصادرة (للموردين)، وكل حركة بتعمل قيد مرحّل تلقائياً
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists cheques_in_account_id  uuid references public.accounts(id) on delete set null;  -- شيكات برسم التحصيل
alter table public.company_settings add column if not exists cheques_out_account_id uuid references public.accounts(id) on delete set null;  -- شيكات آجلة الدفع

create table if not exists public.cheques (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  direction     text not null check (direction in ('in','out')),
  cheque_no     text not null,
  bank_name     text,
  branch        text,
  issue_date    date not null default current_date,
  due_date      date not null,
  amount        numeric(18,3) not null check (amount > 0),
  party_id      uuid references public.parties(id) on delete restrict,
  account_id    uuid references public.accounts(id) on delete restrict,   -- الحساب المقابل إذا بدون عميل/مورد
  drawer_name   text,             -- اسم الساحب/المستفيد
  bank_account_id uuid references public.accounts(id) on delete set null,  -- البنك اللي انصرف/انحصّل عليه
  status        text not null default 'portfolio'
                check (status in ('portfolio','collected','returned','issued','paid','cancelled')),
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists cheques_due_idx on public.cheques (company_id, status, due_date);

create table if not exists public.cheque_events (
  id         uuid primary key default gen_random_uuid(),
  cheque_id  uuid not null references public.cheques(id) on delete cascade,
  action     text not null,
  event_date date not null,
  entry_id   uuid references public.journal_entries(id) on delete set null,
  note       text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- الشيك ما بيتعدّل مبلغه أو طرفه بعد ما ينسجّل (حالته بتتغير بس من الدالة)
create or replace function public.cheques_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'INSERT' then raise exception 'الشيك بينسجّل من شاشة الشيكات'; end if;
  if tg_op = 'DELETE' then raise exception 'الشيك المسجّل ما بينحذف. ألغيه أو رجّعه'; end if;
  if new.amount <> old.amount or new.party_id is distinct from old.party_id or new.account_id is distinct from old.account_id
     or new.status <> old.status or new.direction <> old.direction or new.company_id <> old.company_id or new.bank_account_id is distinct from old.bank_account_id then
    raise exception 'ما بيصير تعديل المبلغ أو الطرف أو الحالة مباشرة';
  end if;
  return new;
end $$;
drop trigger if exists cheques_guard on public.cheques;
create trigger cheques_guard before insert or update or delete on public.cheques
  for each row execute function public.cheques_guard();

-- قيد داخلي من سطرين
create or replace function public.post_two_line(p_company uuid, p_date date, p_desc text, p_ref text,
  p_dr uuid, p_dr_party uuid, p_cr uuid, p_cr_party uuid, p_amount numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; eid uuid;
begin
  select * into fy from public.fiscal_years where company_id = p_company and p_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;
  if p_dr is null or p_cr is null then raise exception 'حدّد حسابات الشيكات والبنك بشاشة «حسابات الربط»'; end if;
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (p_company, fy.id, 'cheque', p_date, p_desc, p_ref, 'draft') returning id into eid;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
  values (eid, 1, p_dr, p_dr_party, p_desc, p_amount, 0), (eid, 2, p_cr, p_cr_party, p_desc, 0, p_amount);
  update public.journal_entries set status = 'posted', total = p_amount, posted_by = auth.uid(), posted_at = now() where id = eid;
  return eid;
end $$;
revoke execute on function public.post_two_line(uuid, date, text, text, uuid, uuid, uuid, uuid, numeric) from public, anon, authenticated;

-- تسجيل شيك جديد (وارد: من حـ/ شيكات برسم التحصيل إلى حـ/ العميل — صادر: من حـ/ المورد إلى حـ/ شيكات آجلة)
create or replace function public.register_cheque(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; cid uuid; pa public.parties; other uuid; ch uuid; eid uuid; dir text; amt numeric; d date; descr text;
begin
  cid := (p ->> 'company_id')::uuid; dir := p ->> 'direction'; amt := (p ->> 'amount')::numeric;
  d := coalesce((p ->> 'issue_date')::date, current_date);
  if not public.can(cid, 'cheques', 'add') then raise exception 'ما عندك صلاحية'; end if;
  if dir not in ('in','out') then raise exception 'نوع الشيك غلط'; end if;
  if amt is null or amt <= 0 then raise exception 'المبلغ لازم يكون أكبر من صفر'; end if;
  perform public.ensure_company_settings(cid);
  update public.company_settings s set
    cheques_in_account_id  = coalesce(s.cheques_in_account_id,  (select id from public.accounts where company_id = cid and code = '1104' and not is_group)),
    cheques_out_account_id = coalesce(s.cheques_out_account_id, (select id from public.accounts where company_id = cid and code = '2102' and not is_group))
  where s.company_id = cid;
  select * into st from public.company_settings where company_id = cid;
  if nullif(p ->> 'party_id', '') is not null then
    select * into pa from public.parties where id = (p ->> 'party_id')::uuid and company_id = cid;
    if pa.id is null then raise exception 'العميل/المورد مش لهالشركة'; end if;
    other := pa.account_id;
  else
    other := nullif(p ->> 'account_id', '')::uuid;
    if other is null or not exists (select 1 from public.accounts where id = other and company_id = cid and not is_group) then
      raise exception 'اختار العميل/المورد أو الحساب المقابل';
    end if;
  end if;
  descr := case dir when 'in' then 'شيك وارد رقم ' else 'شيك صادر رقم ' end || (p ->> 'cheque_no') || coalesce(' - ' || coalesce(pa.name, p ->> 'drawer_name'), '');

  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.cheques (company_id, direction, cheque_no, bank_name, branch, issue_date, due_date, amount, party_id, account_id, drawer_name, status, notes)
  values (cid, dir, p ->> 'cheque_no', p ->> 'bank_name', p ->> 'branch', d, (p ->> 'due_date')::date, amt, pa.id,
          case when pa.id is null then other end, coalesce(p ->> 'drawer_name', pa.name), case dir when 'in' then 'portfolio' else 'issued' end, p ->> 'notes')
  returning id into ch;
  if dir = 'in' then eid := public.post_two_line(cid, d, descr, p ->> 'cheque_no', st.cheques_in_account_id, null, other, pa.id, amt);
  else eid := public.post_two_line(cid, d, descr, p ->> 'cheque_no', other, pa.id, st.cheques_out_account_id, null, amt); end if;
  insert into public.cheque_events (cheque_id, action, event_date, entry_id) values (ch, case dir when 'in' then 'استلام' else 'إصدار' end, d, eid);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), cid, 'إضافة', 'cheques', ch::text, jsonb_build_object('no', p ->> 'cheque_no', 'amount', amt));
  return ch;
end $$;

-- حركات الشيك: collect (تحصيل) / return (راجع) / pay (صرف من البنك) / cancel (إلغاء صادر)
create or replace function public.cheque_action(p_id uuid, p_action text, p_date date, p_bank uuid default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c public.cheques; st public.company_settings; other uuid; eid uuid; descr text; newst text; pa public.parties;
begin
  select * into c from public.cheques where id = p_id for update;
  if c.id is null then raise exception 'الشيك غير موجود'; end if;
  if not public.can(c.company_id, 'cheques', 'post') then raise exception 'ما عندك صلاحية على حركات الشيكات'; end if;
  select * into st from public.company_settings where company_id = c.company_id;
  if c.party_id is not null then select * into pa from public.parties where id = c.party_id; other := pa.account_id; else other := c.account_id; end if;
  if p_bank is not null and not exists (select 1 from public.accounts where id = p_bank and company_id = c.company_id and not is_group) then raise exception 'حساب البنك غلط'; end if;
  descr := case p_action when 'collect' then 'تحصيل' when 'return' then 'إرجاع' when 'pay' then 'صرف' else 'إلغاء' end
           || ' شيك رقم ' || c.cheque_no || coalesce(' - ' || c.drawer_name, '');
  perform set_config('sumou.internal', public.internal_token(), true);
  if c.direction = 'in' and c.status = 'portfolio' and p_action = 'collect' then
    if p_bank is null then raise exception 'اختار البنك اللي انحصّل عليه الشيك'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, p_bank, null, st.cheques_in_account_id, null, c.amount); newst := 'collected';
  elsif c.direction = 'in' and c.status in ('portfolio','collected') and p_action = 'return' then
    -- الشيك الراجع: العميل بيرجع مديون. إذا كان محصّل، بنعكس من البنك
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, other, c.party_id,
             case when c.status = 'collected' then coalesce(p_bank, c.bank_account_id) else st.cheques_in_account_id end, null, c.amount);
    newst := 'returned';
  elsif c.direction = 'out' and c.status = 'issued' and p_action = 'pay' then
    if p_bank is null then raise exception 'اختار البنك اللي انصرف منه الشيك'; end if;
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_out_account_id, null, p_bank, null, c.amount); newst := 'paid';
  elsif c.direction = 'out' and c.status = 'issued' and p_action in ('cancel','return') then
    eid := public.post_two_line(c.company_id, p_date, descr, c.cheque_no, st.cheques_out_account_id, null, other, c.party_id, c.amount); newst := 'cancelled';
  else
    raise exception 'الحركة مش مسموحة لشيك حالته الحالية';
  end if;
  update public.cheques set status = newst, bank_account_id = coalesce(p_bank, bank_account_id) where id = p_id;
  insert into public.cheque_events (cheque_id, action, event_date, entry_id, note) values (p_id, descr, p_date, eid, p_note);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), c.company_id, descr, 'cheques', p_id::text, jsonb_build_object('amount', c.amount));
end $$;

alter table public.cheques enable row level security;
alter table public.cheque_events enable row level security;
drop policy if exists ch_select on public.cheques;
create policy ch_select on public.cheques for select to authenticated using (public.can(company_id, 'cheques', 'view'));
drop policy if exists ch_update on public.cheques;
create policy ch_update on public.cheques for update to authenticated
  using (public.can(company_id, 'cheques', 'edit')) with check (public.can(company_id, 'cheques', 'edit'));
drop policy if exists che_select on public.cheque_events;
create policy che_select on public.cheque_events for select to authenticated
  using (exists (select 1 from public.cheques c where c.id = cheque_id and public.can(c.company_id, 'cheques', 'view')));

grant select, update on public.cheques to authenticated;
grant select on public.cheque_events to authenticated;
grant execute on function public.register_cheque(jsonb), public.cheque_action(uuid, text, date, uuid, text) to authenticated;

update public.user_groups set permissions = permissions || '{"cheques":{"view":true,"add":true,"edit":true,"print":true,"post":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'cheques');
update public.user_groups set permissions = permissions || '{"cheques":{"view":true,"add":true}}'::jsonb
 where name = 'مدخل بيانات' and not (permissions ? 'cheques');
update public.user_groups set permissions = permissions || '{"cheques":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'cheques');

-- انتهى ✅


-- #################### 10_inventory.sql ####################
-- =====================================================================
--  نظام السمو ERP — المخزون والجرد (كميات)
--  مستودعات، حركات تلقائية من الفواتير المرحّلة، سندات إدخال/إخراج/تحويل/جرد،
--  رصيد الأصناف ومتوسط الكلفة. (المحاسبة على المخزون بطريقة الجرد الدوري:
--  المشتريات بتنقيّد مصروف، وقيمة المخزون آخر المدة من تقرير الجرد.)
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.warehouses (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);

alter table public.items add column if not exists track_stock boolean not null default true;
alter table public.invoices add column if not exists warehouse_id uuid references public.warehouses(id) on delete set null;

create table if not exists public.stock_docs (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  doc_type        text not null check (doc_type in ('in','out','transfer','count')),
  doc_no          int,
  doc_date        date not null default current_date,
  warehouse_id    uuid not null references public.warehouses(id) on delete restrict,
  to_warehouse_id uuid references public.warehouses(id) on delete restrict,
  status          text not null default 'draft' check (status in ('draft','posted')),
  notes           text,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (company_id, doc_type, doc_no)
);

create table if not exists public.stock_doc_lines (
  id         uuid primary key default gen_random_uuid(),
  doc_id     uuid not null references public.stock_docs(id) on delete cascade,
  line_no    int not null default 1,
  item_id    uuid not null references public.items(id) on delete restrict,
  qty        numeric(18,3) not null default 0,        -- للإدخال/الإخراج/التحويل
  counted_qty numeric(18,3),                          -- للجرد: الكمية الفعلية
  unit_cost  numeric(18,3) not null default 0,
  note       text
);

create table if not exists public.stock_moves (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  item_id      uuid not null references public.items(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  move_date    date not null,
  qty          numeric(18,3) not null,              -- موجب = داخل، سالب = خارج
  unit_cost    numeric(18,3) not null default 0,
  source_type  text not null,                       -- invoice, stock_doc
  source_id    uuid not null,
  description  text,
  created_at   timestamptz not null default now()
);
create index if not exists stock_moves_item_idx on public.stock_moves (company_id, item_id, warehouse_id, move_date);

-- مستودع رئيسي تلقائي لكل شركة
create or replace function public.default_warehouse(p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare w uuid;
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  select id into w from public.warehouses where company_id = p_company and is_active order by code limit 1;
  if w is null then
    insert into public.warehouses (company_id, code, name) values (p_company, '1', 'المستودع الرئيسي') returning id into w;
  end if;
  return w;
end $$;

-- حركات المخزون من الفاتورة لما تترحّل أو تنلغى
create or replace function public.invoice_stock_moves() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; sgn int;
begin
  if not (old.status = 'draft' and new.status = 'posted') and not (old.status = 'posted' and new.status = 'cancelled') then return null; end if;
  sgn := case when new.inv_type in ('purchase','sale_return') then 1 else -1 end;
  if new.status = 'cancelled' then
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
    select company_id, item_id, warehouse_id, current_date, -qty, unit_cost, 'invoice_cancel', source_id, 'إلغاء: ' || coalesce(description, '')
    from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    return null;
  end if;
  w := coalesce(new.warehouse_id, public.default_warehouse(new.company_id));
  insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
  select new.company_id, l.item_id, w, new.inv_date, sgn * l.qty,
         case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end, 'invoice', new.id,
         case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || coalesce(new.doc_code, new.inv_no::text)
  from public.invoice_lines l join public.items it on it.id = l.item_id
  where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock;
  return null;
end $$;
drop trigger if exists invoice_stock_moves on public.invoices;
create trigger invoice_stock_moves after update of status on public.invoices
  for each row execute function public.invoice_stock_moves();

-- ترقيم وحماية سندات المخزون
create or replace function public.stock_docs_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'posted' then raise exception 'السند مرحّل، ما بينحذف'; end if; return old;
  end if;
  if not public.is_internal() then
    if tg_op = 'UPDATE' and old.status = 'posted' then raise exception 'السند مرحّل، ما بينعدّل'; end if;
    if new.status <> 'draft' then raise exception 'الترحيل من زر «ترحيل» بس'; end if;
  end if;
  if not exists (select 1 from public.warehouses where id = new.warehouse_id and company_id = new.company_id) then raise exception 'المستودع مش لهالشركة'; end if;
  if new.doc_type = 'transfer' then
    if new.to_warehouse_id is null or new.to_warehouse_id = new.warehouse_id
       or not exists (select 1 from public.warehouses where id = new.to_warehouse_id and company_id = new.company_id) then
      raise exception 'اختار مستودع التحويل (غير المستودع الأصلي)';
    end if;
  end if;
  if tg_op = 'INSERT' and new.doc_no is null then
    select coalesce(max(doc_no), 0) + 1 into new.doc_no from public.stock_docs where company_id = new.company_id and doc_type = new.doc_type;
  end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.doc_type := old.doc_type; end if;
  return new;
end $$;
drop trigger if exists stock_docs_before on public.stock_docs;
create trigger stock_docs_before before insert or update or delete on public.stock_docs
  for each row execute function public.stock_docs_before();

create or replace function public.stock_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs;
begin
  if tg_op in ('UPDATE','DELETE') then
    select * into d from public.stock_docs where id = old.doc_id;
    if d.status = 'posted' and not public.is_internal() then raise exception 'السند مرحّل'; end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  select * into d from public.stock_docs where id = new.doc_id;
  if d.status = 'posted' and not public.is_internal() then raise exception 'السند مرحّل'; end if;
  if not exists (select 1 from public.items where id = new.item_id and company_id = d.company_id) then raise exception 'الصنف مش لهالشركة'; end if;
  return new;
end $$;
drop trigger if exists stock_lines_before on public.stock_doc_lines;
create trigger stock_lines_before before insert or update or delete on public.stock_doc_lines
  for each row execute function public.stock_lines_before();

-- رصيد صنف بمستودع لتاريخ
create or replace function public.stock_qty(p_item uuid, p_wh uuid, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(m.qty), 0) from public.stock_moves m
  where m.item_id = p_item and m.warehouse_id = p_wh and m.move_date <= p_date and public.has_company(m.company_id);
$$;

-- ترحيل سند مخزون
create or replace function public.post_stock_doc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; r record; n int; diff numeric; descr text;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if d.status <> 'draft' then raise exception 'السند مرحّل من قبل'; end if;
  select count(*) into n from public.stock_doc_lines where doc_id = p_id;
  if n = 0 then raise exception 'السند بدون أصناف'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || coalesce(d.doc_code, d.doc_no::text);
  for r in select * from public.stock_doc_lines where doc_id = p_id loop
    if d.doc_type = 'in' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, r.qty, r.unit_cost, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'out' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, r.unit_cost, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'transfer' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, r.unit_cost, 'stock_doc', p_id, descr),
             (d.company_id, r.item_id, d.to_warehouse_id, d.doc_date, r.qty, r.unit_cost, 'stock_doc', p_id, descr);
    else   -- جرد: الفرق بين الفعلي والدفتري
      if r.counted_qty is null then continue; end if;
      diff := r.counted_qty - public.stock_qty(r.item_id, d.warehouse_id, d.doc_date);
      if abs(diff) > 0.0005 then
        insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
        values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, diff, r.unit_cost, 'stock_doc', p_id, descr || ' (تسوية)');
      end if;
      perform set_config('sumou.internal', public.internal_token(), true);
      update public.stock_doc_lines set qty = diff where id = r.id;
    end if;
  end loop;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.stock_docs set status = 'posted' where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل', 'inventory', p_id::text, jsonb_build_object('doc', descr));
end $$;

-- رصيد المخزون: الكمية ومتوسط كلفة الوارد والقيمة
create or replace function public.rep_stock_balance(p_company uuid, p_date date, p_wh uuid default null)
returns table (item_id uuid, warehouse_id uuid, qty numeric, avg_cost numeric, value numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'inventory', 'view') then raise exception 'ما عندك صلاحية على المخزون'; end if;
  return query
  with m as (select sm.* from public.stock_moves sm where sm.company_id = p_company and sm.move_date <= p_date and (p_wh is null or sm.warehouse_id = p_wh)),
  c as (select m2.item_id, case when sum(m2.qty) filter (where m2.qty > 0 and m2.unit_cost > 0) > 0
                             then sum(m2.qty * m2.unit_cost) filter (where m2.qty > 0 and m2.unit_cost > 0) / sum(m2.qty) filter (where m2.qty > 0 and m2.unit_cost > 0)
                             else 0 end as ac
        from public.stock_moves m2 where m2.company_id = p_company and m2.move_date <= p_date group by m2.item_id)
  select m.item_id, m.warehouse_id, sum(m.qty), round(coalesce(max(c.ac), 0), 3), round(sum(m.qty) * coalesce(max(c.ac), 0), 3)
  from m left join c on c.item_id = m.item_id
  group by m.item_id, m.warehouse_id having abs(sum(m.qty)) > 0.0005;
end $$;

-- بطاقة صنف
create or replace function public.rep_item_card(p_company uuid, p_item uuid, p_from date, p_to date, p_wh uuid default null)
returns table (move_date date, warehouse_id uuid, qty numeric, unit_cost numeric, description text, opening numeric)
language plpgsql stable security definer set search_path = public as $$
declare ob numeric;
begin
  if not public.can(p_company, 'inventory', 'view') then raise exception 'ما عندك صلاحية على المخزون'; end if;
  select coalesce(sum(m.qty), 0) into ob from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.move_date < p_from and (p_wh is null or m.warehouse_id = p_wh);
  return query select null::date, null::uuid, 0::numeric, null::numeric, 'رصيد أول المدة'::text, ob;
  return query
  select m.move_date, m.warehouse_id, m.qty, m.unit_cost, m.description, ob
  from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.move_date between p_from and p_to and (p_wh is null or m.warehouse_id = p_wh)
  order by m.move_date, m.created_at;
end $$;

alter table public.warehouses enable row level security;
alter table public.stock_docs enable row level security;
alter table public.stock_doc_lines enable row level security;
alter table public.stock_moves enable row level security;

drop policy if exists wh_select on public.warehouses;
create policy wh_select on public.warehouses for select to authenticated using (public.has_company(company_id));
drop policy if exists wh_write on public.warehouses;
create policy wh_write on public.warehouses for all to authenticated
  using (public.can(company_id, 'inventory', 'edit')) with check (public.can(company_id, 'inventory', 'edit'));

drop policy if exists sd_select on public.stock_docs;
create policy sd_select on public.stock_docs for select to authenticated using (public.can(company_id, 'inventory', 'view'));
drop policy if exists sd_insert on public.stock_docs;
create policy sd_insert on public.stock_docs for insert to authenticated with check (public.can(company_id, 'inventory', 'add'));
drop policy if exists sd_update on public.stock_docs;
create policy sd_update on public.stock_docs for update to authenticated
  using (public.can(company_id, 'inventory', 'edit')) with check (public.can(company_id, 'inventory', 'edit'));
drop policy if exists sd_delete on public.stock_docs;
create policy sd_delete on public.stock_docs for delete to authenticated using (public.can(company_id, 'inventory', 'delete'));

drop policy if exists sdl_all on public.stock_doc_lines;
create policy sdl_all on public.stock_doc_lines for all to authenticated
  using (exists (select 1 from public.stock_docs d where d.id = doc_id and public.can(d.company_id, 'inventory', 'view')))
  with check (exists (select 1 from public.stock_docs d where d.id = doc_id and (public.can(d.company_id, 'inventory', 'add') or public.can(d.company_id, 'inventory', 'edit'))));

drop policy if exists sm_select on public.stock_moves;
create policy sm_select on public.stock_moves for select to authenticated using (public.can(company_id, 'inventory', 'view'));

grant select, insert, update, delete on public.warehouses, public.stock_docs, public.stock_doc_lines to authenticated;
grant select on public.stock_moves to authenticated;
grant execute on function public.post_stock_doc(uuid), public.rep_stock_balance(uuid, date, uuid), public.rep_item_card(uuid, uuid, date, date, uuid),
  public.default_warehouse(uuid), public.stock_qty(uuid, uuid, date) to authenticated;

update public.user_groups set permissions = permissions || '{"inventory":{"view":true,"add":true,"edit":true,"print":true,"post":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'inventory');
update public.user_groups set permissions = permissions || '{"inventory":{"view":true,"add":true,"edit":true}}'::jsonb
 where name = 'مدخل بيانات' and not (permissions ? 'inventory');
update public.user_groups set permissions = permissions || '{"inventory":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'inventory');

-- انتهى ✅


-- #################### 11_users.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 11: إدارة المستخدمين من جوّا البرنامج
--  المدير بيعمل مستخدم باسم مستخدم + كلمة سر، وبيحدد الشاشات المسموحة
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists permissions jsonb not null default '{}'::jsonb;  -- {"sales_invoices": true} = كل شي، أو {"customers": {"view": true, "print": true}}
create unique index if not exists profiles_username_uq on public.profiles (lower(username)) where username is not null;

-- الموظف ما بيقدر يغيّر صلاحياته أو اسم المستخدم
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.is_admin    := old.is_admin;
    new.is_active   := old.is_active;
    new.email       := old.email;
    new.username    := old.username;
    new.permissions := old.permissions;
  end if;
  return new;
end $$;

-- الصلاحية: مدير، أو الشاشة مأشّرة للمستخدم (true = كل العمليات، أو عمليات محددة)، أو من مجموعته بالشركة
create or replace function public.can(cid uuid, screen text, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    public.is_active_user() and exists (
      select 1 from public.user_companies uc
      left join public.user_groups g on g.id = uc.group_id
      join public.profiles p on p.id = uc.user_id
      where uc.user_id = auth.uid() and uc.company_id = cid
        and ((case jsonb_typeof(p.permissions -> screen)
                when 'boolean' then (p.permissions ->> screen)::boolean
                when 'object'  then coalesce((p.permissions -> screen ->> act)::boolean, false)
                else false end)
             or coalesce((g.permissions -> screen ->> act)::boolean, false))
    )
  );
$$;

create or replace function public.username_email(p_username text) returns text
language sql immutable as $$ select lower(trim(p_username)) || '@sumou.local' $$;

-- إنشاء مستخدم (للمدير بس)
create or replace function public.admin_create_user(p_username text, p_full_name text, p_password text,
  p_permissions jsonb default '{}'::jsonb, p_companies uuid[] default '{}', p_is_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); em text; c uuid;
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يضيف مستخدمين'; end if;
  p_username := lower(trim(p_username));
  if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
  if coalesce(length(p_password), 0) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
  em := public.username_email(p_username);
  if exists (select 1 from auth.users where lower(email) = em) or exists (select 1 from public.profiles where lower(username) = p_username) then
    raise exception 'اسم المستخدم «%» موجود من قبل', p_username;
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', coalesce(nullif(trim(p_full_name), ''), p_username)),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  -- الملف الشخصي بينعمل من الـ trigger
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), p_username),
         is_active = true, is_admin = coalesce(p_is_admin, false), permissions = coalesce(p_permissions, '{}'::jsonb)
   where id = uid;
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (uid, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'إضافة', 'users', uid, jsonb_build_object('username', p_username));
  return uid;
end $$;

-- تعديل مستخدم: الاسم، اسم المستخدم، كلمة السر (فاضية = بدون تغيير)، الصلاحيات، الشركات
create or replace function public.admin_update_user(p_id uuid, p_username text, p_full_name text, p_password text,
  p_permissions jsonb, p_companies uuid[], p_is_admin boolean, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare em text; c uuid; self boolean := (p_id = auth.uid());
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يعدّل المستخدمين'; end if;
  if not exists (select 1 from public.profiles where id = p_id) then raise exception 'المستخدم مش موجود'; end if;
  p_username := nullif(lower(trim(coalesce(p_username, ''))), '');
  if p_username is not null then
    if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
    if exists (select 1 from public.profiles where lower(username) = p_username and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
    -- المستخدمين اللي انعملوا من البرنامج بيتغيّر إيميلهم الداخلي مع الاسم
    if (select email from auth.users where id = p_id) like '%@sumou.local' then
      em := public.username_email(p_username);
      if exists (select 1 from auth.users where lower(email) = em and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
      update auth.users set email = em, updated_at = now() where id = p_id;
      update auth.identities set identity_data = identity_data || jsonb_build_object('email', em) where user_id = p_id and provider = 'email';
      update public.profiles set email = em where id = p_id;
    end if;
  end if;
  if coalesce(p_password, '') <> '' then
    if length(p_password) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
    update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_id;
  end if;
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
         permissions = coalesce(p_permissions, '{}'::jsonb),
         is_admin = case when self then is_admin else coalesce(p_is_admin, is_admin) end,
         is_active = case when self then is_active else coalesce(p_is_active, is_active) end
   where id = p_id;
  -- الشركات: نحافظ على مجموعة الشركة الموجودة إذا ضلت مأشّرة
  delete from public.user_companies where user_id = p_id and not (company_id = any (coalesce(p_companies, '{}')));
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (p_id, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'تعديل', 'users', p_id, jsonb_build_object('username', p_username, 'password_changed', coalesce(p_password, '') <> ''));
end $$;

-- حذف مستخدم نهائياً
create or replace function public.admin_delete_user(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يحذف المستخدمين'; end if;
  if p_id = auth.uid() then raise exception 'ما بتقدر تحذف حالك'; end if;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  select auth.uid(), 'حذف', 'users', p_id, jsonb_build_object('username', username, 'email', email) from public.profiles where id = p_id;
  delete from auth.users where id = p_id;
  delete from public.profiles where id = p_id;
end $$;

revoke execute on function public.admin_create_user(text, text, text, jsonb, uuid[], boolean) from public, anon;
revoke execute on function public.admin_update_user(uuid, text, text, text, jsonb, uuid[], boolean, boolean) from public, anon;
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_create_user(text, text, text, jsonb, uuid[], boolean) to authenticated;
grant execute on function public.admin_update_user(uuid, text, text, text, jsonb, uuid[], boolean, boolean) to authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;


-- #################### 12_perpetual.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 12: الجرد المستمر (قيد كلفة البضاعة تلقائي)
--  اختياري لكل شركة من «حسابات الربط». لما يكون مفعّل:
--   • فاتورة الشراء: البضاعة بتروح لحساب المخزون بدل المشتريات
--   • فاتورة البيع: قيد كلفة البضاعة المباعة / المخزون بمتوسط الكلفة
--   • المرتجعات بالعكس، وسندات المخزون والجرد بتعمل قيد بقيمتها
-- =====================================================================

alter table public.company_settings add column if not exists perpetual_inventory boolean not null default false;
alter table public.company_settings add column if not exists inventory_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists cogs_account_id uuid references public.accounts(id) on delete set null;
alter table public.stock_docs add column if not exists account_id uuid references public.accounts(id) on delete set null;   -- الحساب المقابل
alter table public.stock_docs add column if not exists entry_id uuid references public.journal_entries(id) on delete set null;
alter table public.stock_moves add column if not exists is_cost boolean not null default false;  -- بيدخل بحساب متوسط الكلفة

-- الحركات القديمة: الشراء وسندات الإدخال هي اللي بتحدد الكلفة
update public.stock_moves m set is_cost = true
 where not m.is_cost and m.qty > 0 and m.unit_cost > 0 and (
   (m.source_type = 'invoice' and exists (select 1 from public.invoices i where i.id = m.source_id and i.inv_type = 'purchase'))
   or (m.source_type = 'stock_doc' and exists (select 1 from public.stock_docs d where d.id = m.source_id and d.doc_type = 'in')));
update public.stock_moves m set is_cost = true
 where not m.is_cost and m.source_type = 'invoice_cancel' and m.qty < 0
   and exists (select 1 from public.invoices i where i.id = m.source_id and i.inv_type = 'purchase');

-- متوسط الكلفة المتحرك لصنف لحد تاريخ: قيمة المخزون (مجموع الكمية × كلفة كل حركة) ÷ الكمية.
-- كل حركة صادرة بتنسجّل بالمتوسط وقتها، فالقيمة بالدفاتر = قيمة تقرير المخزون.
-- إذا الرصيد صفر: آخر كلفة شراء، وبعدين سعر الشراء بالصنف.
create or replace function public.item_avg_cost(p_company uuid, p_item uuid, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select case when not public.has_company(p_company) then 0 else round(coalesce(
    (select case when sum(m.qty) > 0.0005 then greatest(sum(m.qty * m.unit_cost), 0) / sum(m.qty) end
       from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.move_date <= p_date),
    (select m.unit_cost from public.stock_moves m where m.company_id = p_company and m.item_id = p_item and m.is_cost and m.move_date <= p_date
      order by m.move_date desc, m.created_at desc limit 1),
    (select nullif(purchase_price, 0) from public.items where id = p_item), 0), 3) end;
$$;

create or replace function public.ensure_company_settings(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  insert into public.company_settings (company_id) values (p_company) on conflict do nothing;
  update public.company_settings s set
    sales_account_id           = coalesce(s.sales_account_id,           (select id from public.accounts where company_id = p_company and code = '4101' and not is_group)),
    sales_return_account_id    = coalesce(s.sales_return_account_id,    (select id from public.accounts where company_id = p_company and code = '4102' and not is_group)),
    purchase_account_id        = coalesce(s.purchase_account_id,        (select id from public.accounts where company_id = p_company and code = '5101' and not is_group)),
    purchase_return_account_id = coalesce(s.purchase_return_account_id, (select id from public.accounts where company_id = p_company and code = '5102' and not is_group)),
    output_tax_account_id      = coalesce(s.output_tax_account_id,      (select id from public.accounts where company_id = p_company and code = '2103' and not is_group)),
    input_tax_account_id       = coalesce(s.input_tax_account_id,       (select id from public.accounts where company_id = p_company and code = '1108' and not is_group)),
    cash_account_id            = coalesce(s.cash_account_id,            (select id from public.accounts where company_id = p_company and code = '1101' and not is_group)),
    inventory_account_id       = coalesce(s.inventory_account_id,       (select id from public.accounts where company_id = p_company and code = '1105' and not is_group)),
    cogs_account_id            = coalesce(s.cogs_account_id,            (select id from public.accounts where company_id = p_company and code = '5104' and not is_group))
  where s.company_id = p_company;
end $$;

-- سطر قيد داخلي (على قيد مرحّل، والمتغير الداخلي مفعّل من اللي استدعى)
create or replace function public.add_entry_pair(p_entry uuid, p_dr uuid, p_cr uuid, p_amt numeric, p_desc text) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_amt is null or abs(p_amt) < 0.0005 then return; end if;
  if p_amt < 0 then perform public.add_entry_pair(p_entry, p_cr, p_dr, -p_amt, p_desc); return; end if;
  select coalesce(max(line_no), 0) into n from public.journal_lines where entry_id = p_entry;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
  values (p_entry, n + 1, p_dr, p_desc, round(p_amt, 3), 0), (p_entry, n + 2, p_cr, p_desc, 0, round(p_amt, 3));
  update public.journal_entries set total = total + round(p_amt, 3) where id = p_entry;
end $$;
revoke execute on function public.add_entry_pair(uuid, uuid, uuid, numeric, text) from public, anon, authenticated;

-- حركات المخزون من الفاتورة (+ قيد الكلفة إذا الجرد المستمر مفعّل)
create or replace function public.invoice_stock_moves() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; sgn int; st public.company_settings; v numeric; r record; descr text;
begin
  if not (old.status = 'draft' and new.status = 'posted') and not (old.status = 'posted' and new.status = 'cancelled') then return null; end if;
  sgn := case when new.inv_type in ('purchase','sale_return') then 1 else -1 end;
  if new.status = 'cancelled' then   -- قيد الإلغاء العكسي بيعكس سطور الكلفة كمان لأنها بنفس قيد الفاتورة
    insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
    select company_id, item_id, warehouse_id, current_date, -qty, unit_cost, 'invoice_cancel', source_id, 'إلغاء: ' || coalesce(description, ''), is_cost
    from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    return null;
  end if;
  w := coalesce(new.warehouse_id, public.default_warehouse(new.company_id));
  descr := case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || coalesce(new.doc_code, new.inv_no::text);
  -- الشراء بكلفته، والباقي بمتوسط الكلفة قبل الحركة
  insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
  select new.company_id, l.item_id, w, new.inv_date, sgn * l.qty,
         case when new.inv_type in ('purchase','purchase_return') then case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end
              else public.item_avg_cost(new.company_id, l.item_id, new.inv_date) end,
         'invoice', new.id, descr, new.inv_type in ('purchase','purchase_return') and l.qty > 0 and l.subtotal > 0
  from public.invoice_lines l join public.items it on it.id = l.item_id
  where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock;

  select * into st from public.company_settings where company_id = new.company_id;
  if not coalesce(st.perpetual_inventory, false) or new.entry_id is null then return null; end if;
  if st.inventory_account_id is null or st.cogs_account_id is null then
    raise exception 'الجرد المستمر مفعّل: حدّد حساب المخزون وحساب كلفة البضاعة المباعة بشاشة «حسابات الربط»';
  end if;
  if new.inv_type in ('sale','sale_return') then
    select coalesce(sum(abs(qty) * unit_cost), 0) into v from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    if new.inv_type = 'sale' then perform public.add_entry_pair(new.entry_id, st.cogs_account_id, st.inventory_account_id, v, 'كلفة البضاعة - ' || descr);
    else perform public.add_entry_pair(new.entry_id, st.inventory_account_id, st.cogs_account_id, v, 'كلفة البضاعة - ' || descr); end if;
  else
    -- إعادة تصنيف قيمة البضاعة من المشتريات/مردوداتها للمخزون
    -- القيمة نفسها اللي دخلت/طلعت من المخزون (الكمية × كلفة الحركة)
    for r in
      select coalesce(case when new.inv_type = 'purchase_return' then coalesce(st.purchase_return_account_id, l.account_id) else l.account_id end, st.purchase_account_id) as acc,
             sum(l.qty * case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end) as amt
      from public.invoice_lines l join public.items it on it.id = l.item_id
      where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock group by 1
    loop
      if new.inv_type = 'purchase' then perform public.add_entry_pair(new.entry_id, st.inventory_account_id, r.acc, r.amt, 'للمخزون - ' || descr);
      else perform public.add_entry_pair(new.entry_id, r.acc, st.inventory_account_id, r.amt, 'من المخزون - ' || descr); end if;
    end loop;
  end if;
  return null;
end $$;

-- ترحيل سند مخزون (+ قيد بقيمته إذا الجرد المستمر مفعّل)
create or replace function public.post_stock_doc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; r record; n int; diff numeric; descr text; cst numeric; st public.company_settings;
        v numeric; eid uuid; fy uuid; contra uuid;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if d.status <> 'draft' then raise exception 'السند مرحّل من قبل'; end if;
  select count(*) into n from public.stock_doc_lines where doc_id = p_id;
  if n = 0 then raise exception 'السند بدون أصناف'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || coalesce(d.doc_code, d.doc_no::text);
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.stock_doc_lines where doc_id = p_id order by line_no loop
    cst := public.item_avg_cost(d.company_id, r.item_id, d.doc_date);
    if d.doc_type = 'in' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      cst := coalesce(nullif(r.unit_cost, 0), cst);
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, r.qty, cst, 'stock_doc', p_id, descr, cst > 0);
    elsif d.doc_type = 'out' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, cst, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'transfer' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, cst, 'stock_doc', p_id, descr),
             (d.company_id, r.item_id, d.to_warehouse_id, d.doc_date, r.qty, cst, 'stock_doc', p_id, descr);
    else   -- جرد: الفرق بين الفعلي والدفتري، بمتوسط الكلفة
      if r.counted_qty is null then continue; end if;
      diff := r.counted_qty - public.stock_qty(r.item_id, d.warehouse_id, d.doc_date);
      if abs(diff) > 0.0005 then
        insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
        values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, diff, cst, 'stock_doc', p_id, descr || ' (تسوية)');
      end if;
      update public.stock_doc_lines set qty = diff, unit_cost = cst where id = r.id;
    end if;
  end loop;

  -- القيد المحاسبي
  select * into st from public.company_settings where company_id = d.company_id;
  if coalesce(st.perpetual_inventory, false) and d.doc_type <> 'transfer' then
    select coalesce(sum(qty * unit_cost), 0) into v from public.stock_moves where source_type = 'stock_doc' and source_id = p_id;
    if abs(v) >= 0.0005 then
      contra := coalesce(d.account_id, st.cogs_account_id);
      if st.inventory_account_id is null or contra is null then raise exception 'حدّد حساب المخزون والحساب المقابل بشاشة «حسابات الربط»'; end if;
      select id into fy from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date and not is_closed order by start_date desc limit 1;
      if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ السند'; end if;
      insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
      values (d.company_id, fy, 'stock', d.doc_date, descr || coalesce(' - ' || nullif(d.notes, ''), ''), 'مخزون ' || coalesce(d.doc_code, d.doc_no::text), 'draft') returning id into eid;
      perform public.add_entry_pair(eid, st.inventory_account_id, contra, v, descr);
      update public.journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = eid;
    end if;
  end if;
  update public.stock_docs set status = 'posted', entry_id = eid where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل', 'inventory', p_id::text, jsonb_build_object('doc', descr, 'value', v));
end $$;

-- رصيد المخزون: الكمية ومتوسط الكلفة والقيمة
create or replace function public.rep_stock_balance(p_company uuid, p_date date, p_wh uuid default null)
returns table (item_id uuid, warehouse_id uuid, qty numeric, avg_cost numeric, value numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'inventory', 'view') then raise exception 'ما عندك صلاحية على المخزون'; end if;
  return query
  select m.item_id, m.warehouse_id, sum(m.qty), public.item_avg_cost(p_company, m.item_id, p_date),
         round(sum(m.qty) * public.item_avg_cost(p_company, m.item_id, p_date), 3)
  from public.stock_moves m
  where m.company_id = p_company and m.move_date <= p_date and (p_wh is null or m.warehouse_id = p_wh)
  group by m.item_id, m.warehouse_id having abs(sum(m.qty)) > 0.0005;
end $$;

grant execute on function public.item_avg_cost(uuid, uuid, date) to authenticated;


-- #################### 13_extras.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 13: الطباعة، لوحة الأرقام، القيود المتكررة، الرواتب،
--  الأصول الثابتة، التسوية البنكية، المرفقات، مراكز الكلفة، العملات
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) أعمدة عامة
-- ---------------------------------------------------------------------
alter table public.company_settings add column if not exists print_settings jsonb not null default '{}'::jsonb;

create table if not exists public.cost_centers (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);
create table if not exists public.currencies (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,          -- USD, EUR...
  name       text not null,
  rate       numeric(18,6) not null default 1 check (rate > 0),   -- كم دينار للوحدة
  is_active  boolean not null default true,
  unique (company_id, code)
);
alter table public.journal_lines add column if not exists cost_center_id uuid references public.cost_centers(id) on delete set null;
alter table public.journal_lines add column if not exists currency text;
alter table public.journal_lines add column if not exists fx_rate numeric(18,6);
alter table public.journal_lines add column if not exists fx_amount numeric(18,3);
alter table public.invoices add column if not exists cost_center_id uuid references public.cost_centers(id) on delete set null;
create index if not exists jl_cc_idx on public.journal_lines (cost_center_id) where cost_center_id is not null;

-- مركز الكلفة لازم يكون لنفس الشركة
create or replace function public.lines_cc_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.cost_center_id is not null and not exists (
     select 1 from public.cost_centers c join public.journal_entries e on e.company_id = c.company_id
     where c.id = new.cost_center_id and e.id = new.entry_id) then
    raise exception 'مركز الكلفة مش لهالشركة';
  end if;
  if new.fx_amount is not null and (new.currency is null or coalesce(new.fx_rate, 0) <= 0) then
    raise exception 'سطر العملة الأجنبية لازم يكون إله عملة وسعر صرف';
  end if;
  return new;
end $$;
drop trigger if exists lines_cc_check on public.journal_lines;
create trigger lines_cc_check before insert or update on public.journal_lines for each row execute function public.lines_cc_check();

-- القيد العكسي بينسخ كل تفاصيل السطر
create or replace function public.reverse_entry(p_id uuid, p_date date default current_date, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; fy public.fiscal_years; new_id uuid; d numeric;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'post') then raise exception 'ما عندك صلاحية'; end if;
  if e.status <> 'posted' then raise exception 'بس القيود المرحّلة بتنعكس'; end if;
  if e.entry_type = 'opening' then raise exception 'القيد الافتتاحي ما بينعكس. عدّل الأرصدة بقيد يومية'; end if;
  if e.entry_type = 'invoice' then raise exception 'قيد الفاتورة بينلغى من الفاتورة نفسها (زر إلغاء الفاتورة)'; end if;
  if e.entry_type = 'closing' then raise exception 'قيد الإقفال بينلغى بإعادة فتح السنة'; end if;
  if e.entry_type = 'stock' then raise exception 'قيد المخزون مربوط بسند المخزون وما بينعكس لحاله'; end if;
  if e.entry_type = 'payroll' then raise exception 'قيد الرواتب بينلغى من شاشة الرواتب'; end if;
  if e.entry_type = 'depreciation' then raise exception 'قيد الاستهلاك بينلغى من شاشة الأصول الثابتة'; end if;
  select * into fy from public.fiscal_years
   where company_id = e.company_id and p_date between start_date and end_date and not is_closed
   order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, reversal_of)
  values (e.company_id, fy.id, e.entry_type, p_date,
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || coalesce(e.doc_code, e.entry_no::text) || coalesce(' - ' || e.description, '')),
          e.reference, e.party_name, e.cash_account_id, 'draft', e.id)
  returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount)
  select new_id, line_no, account_id, party_id, description, credit, debit, cost_center_id, currency, fx_rate, fx_amount from public.journal_lines where entry_id = p_id;
  select coalesce(sum(debit),0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'قيد عكسي', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', e.entry_no, 'reversal', new_id));
  return new_id;
end $$;

-- قيد عكسي داخلي عام (للرواتب والاستهلاك): بدون فحص نوع
create or replace function public.reverse_internal(p_id uuid, p_date date, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries; fy uuid; new_id uuid; d numeric;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.status <> 'posted' then raise exception 'القيد مش مرحّل أو انعكس من قبل'; end if;
  select id into fy from public.fiscal_years where company_id = e.company_id and p_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status, reversal_of)
  values (e.company_id, fy, e.entry_type, p_date, p_note, e.reference, 'draft', e.id) returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount)
  select new_id, line_no, account_id, party_id, description, credit, debit, cost_center_id, currency, fx_rate, fx_amount from public.journal_lines where entry_id = p_id;
  select coalesce(sum(debit),0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = p_id;
  return new_id;
end $$;
revoke execute on function public.reverse_internal(uuid, date, text) from public, anon, authenticated;

-- إلغاء الفاتورة بينسخ مراكز الكلفة كمان
create or replace function public.cancel_invoice(p_id uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; fy public.fiscal_years; new_id uuid; d numeric;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'post') then raise exception 'ما عندك صلاحية'; end if;
  if i.status <> 'posted' then raise exception 'بس الفواتير المرحّلة بتنلغى'; end if;
  if not exists (select 1 from public.journal_entries where id = i.entry_id and company_id = i.company_id and status = 'posted') then
    raise exception 'قيد الفاتورة مش مرحّل أو انعكس من قبل';
  end if;
  select * into fy from public.fiscal_years where company_id = i.company_id and p_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status, reversal_of)
  select company_id, fy.id, 'invoice', p_date, 'إلغاء: ' || description, reference, 'draft', id from public.journal_entries where id = i.entry_id
  returning id into new_id;
  insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount)
  select new_id, line_no, account_id, party_id, description, credit, debit, cost_center_id, currency, fx_rate, fx_amount from public.journal_lines where entry_id = i.entry_id;
  select coalesce(sum(debit), 0) into d from public.journal_lines where entry_id = new_id;
  update public.journal_entries set status = 'posted', total = d, posted_by = auth.uid(), posted_at = now() where id = new_id;
  update public.journal_entries set status = 'reversed', reversed_by = new_id where id = i.entry_id;
  update public.invoices set status = 'cancelled', cancel_entry_id = new_id where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, 'إلغاء', public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', i.inv_no));
end $$;

-- مركز كلفة الفاتورة بينطبق على سطور الإيراد والمصروف بقيدها لما تترحّل
create or replace function public.invoice_cost_center() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' and new.cost_center_id is not null and new.entry_id is not null then
    update public.journal_lines l set cost_center_id = new.cost_center_id
      from public.accounts a where a.id = l.account_id and l.entry_id = new.entry_id and a.category in ('revenue','expenses');
  end if;
  return null;
end $$;
drop trigger if exists invoice_cost_center on public.invoices;   -- الاسم القديم
drop trigger if exists zz_invoice_cost_center on public.invoices;
-- اسمه zz عشان يشتغل بعد trigger المخزون وقيد الكلفة (الـ triggers بتشتغل بترتيب الأسماء)
create trigger zz_invoice_cost_center after update of status on public.invoices for each row execute function public.invoice_cost_center();

-- تقرير مراكز الكلفة
create or replace function public.rep_cost_centers(p_company uuid, p_from date, p_to date)
returns table (cost_center_id uuid, revenue numeric, expenses numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.cost_center_id,
         coalesce(sum(l.credit - l.debit) filter (where a.category = 'revenue'), 0),
         coalesce(sum(l.debit - l.credit) filter (where a.category = 'expenses'), 0)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
  where e.company_id = p_company and e.status in ('posted','reversed') and e.entry_type <> 'closing'
    and e.entry_date between p_from and p_to and a.category in ('revenue','expenses')
  group by l.cost_center_id;
end $$;

-- أرصدة العملات الأجنبية حسب الحساب
create or replace function public.rep_fx_balances(p_company uuid, p_date date)
returns table (account_id uuid, currency text, fx_balance numeric, jod_balance numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select l.account_id, l.currency,
         sum(case when l.debit > 0 then l.fx_amount else -l.fx_amount end),
         sum(l.debit - l.credit)
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where e.company_id = p_company and e.status in ('posted','reversed') and e.entry_type <> 'closing'
    and e.entry_date <= p_date and l.currency is not null and l.fx_amount is not null
  group by l.account_id, l.currency;
end $$;

-- ---------------------------------------------------------------------
-- 1) لوحة الأرقام لكل شركة
-- ---------------------------------------------------------------------
create or replace function public.dash_kpis(p_company uuid, p_fy uuid, p_date date default current_date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; m0 date := date_trunc('month', p_date)::date;
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  if not public.can(p_company, 'reports', 'view') then   -- بدون صلاحية التقارير: المسودات بس
    return jsonb_build_object(
      'drafts_entries', (select count(*) from public.journal_entries where company_id = p_company and status = 'draft'),
      'drafts_invoices', (select count(*) from public.invoices where company_id = p_company and status = 'draft'),
      'drafts_stock', (select count(*) from public.stock_docs where company_id = p_company and status = 'draft'),
      'cheques_in_7', case when public.can(p_company, 'cheques', 'view') then coalesce((select sum(amount) from public.cheques where company_id = p_company and direction = 'in' and status = 'portfolio' and due_date <= p_date + 7), 0) end,
      'cheques_out_7', case when public.can(p_company, 'cheques', 'view') then coalesce((select sum(amount) from public.cheques where company_id = p_company and direction = 'out' and status = 'issued' and due_date <= p_date + 7), 0) end,
      'month_sales', '[]'::jsonb);
  end if;
  select jsonb_build_object(
    'sales_month', coalesce((select sum(case when inv_type = 'sale' then subtotal else -subtotal end) from public.invoices
                     where company_id = p_company and status = 'posted' and inv_type in ('sale','sale_return') and inv_date between m0 and p_date), 0),
    'purchases_month', coalesce((select sum(case when inv_type = 'purchase' then subtotal else -subtotal end) from public.invoices
                     where company_id = p_company and status = 'posted' and inv_type in ('purchase','purchase_return') and inv_date between m0 and p_date), 0),
    'sales_year', coalesce((select sum(case when inv_type = 'sale' then subtotal else -subtotal end) from public.invoices
                     where company_id = p_company and fiscal_year_id = p_fy and status = 'posted' and inv_type in ('sale','sale_return')), 0),
    'cash', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.account_type = 'cash' and e.entry_date <= p_date), 0),
    'bank', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.account_type = 'bank' and e.entry_date <= p_date), 0),
    'receivables', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.account_type = 'customer' and e.entry_date <= p_date), 0),
    'payables', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and a.account_type = 'supplier' and e.entry_date <= p_date), 0),
    'profit_year', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                     where e.company_id = p_company and e.fiscal_year_id = p_fy and e.status in ('posted','reversed') and e.entry_type <> 'closing' and a.category in ('revenue','expenses')), 0),
    'cheques_in_7', coalesce((select sum(amount) from public.cheques where company_id = p_company and direction = 'in' and status = 'portfolio' and due_date <= p_date + 7), 0),
    'cheques_out_7', coalesce((select sum(amount) from public.cheques where company_id = p_company and direction = 'out' and status = 'issued' and due_date <= p_date + 7), 0),
    'drafts_entries', (select count(*) from public.journal_entries where company_id = p_company and status = 'draft'),
    'drafts_invoices', (select count(*) from public.invoices where company_id = p_company and status = 'draft'),
    'drafts_stock', (select count(*) from public.stock_docs where company_id = p_company and status = 'draft'),
    'month_sales', coalesce((select jsonb_agg(jsonb_build_object('m', m, 'v', v) order by m) from (
        select to_char(inv_date, 'YYYY-MM') m, sum(case when inv_type = 'sale' then subtotal else -subtotal end) v from public.invoices
        where company_id = p_company and fiscal_year_id = p_fy and status = 'posted' and inv_type in ('sale','sale_return') group by 1) x), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- قائمة المسودات بانتظار الترحيل (للمحاسب/المدير)
drop function if exists public.pending_posts(uuid);
create or replace function public.pending_posts(p_company uuid)
returns table (kind text, id uuid, doc_type text, doc_no int, doc_date date, description text, amount numeric, created_by uuid, created_at timestamptz, doc_code text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select 'entry', e.id, e.entry_type, e.entry_no, e.entry_date, e.description,
         (select coalesce(sum(jl.debit), 0) from public.journal_lines jl where jl.entry_id = e.id), e.created_by, e.created_at, e.doc_code
  from public.journal_entries e where e.company_id = p_company and e.status = 'draft' and public.can(p_company, public.entry_screen(e.entry_type), 'view')
  union all
  select 'invoice', i.id, i.inv_type, i.inv_no, i.inv_date, coalesce(i.party_name, (select pp.name from public.parties pp where pp.id = i.party_id)), i.total, i.created_by, i.created_at, i.doc_code
  from public.invoices i where i.company_id = p_company and i.status = 'draft' and public.can(p_company, public.invoice_screen(i.inv_type), 'view')
  union all
  select 'stock', d.id, d.doc_type, d.doc_no, d.doc_date, d.notes, null::numeric, d.created_by, d.created_at, d.doc_code
  from public.stock_docs d where d.company_id = p_company and d.status = 'draft' and public.can(p_company, 'inventory', 'view')
  order by 9 desc;
end $$;

-- ---------------------------------------------------------------------
-- 2) القيود المتكررة (بتنعمل مسودة لحالها كل شهر)
-- ---------------------------------------------------------------------
create table if not exists public.recurring_entries (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  source_entry_id uuid not null references public.journal_entries(id) on delete cascade,
  title           text not null,
  every_months    int not null default 1 check (every_months between 1 and 12),
  day_of_month    int not null default 1 check (day_of_month between 1 and 28),
  next_date       date not null,
  end_date        date,
  is_active       boolean not null default true,
  last_run        date,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now()
);
create or replace function public.recurring_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.journal_entries where id = new.source_entry_id and company_id = new.company_id and entry_type in ('journal','receipt','payment')) then
    raise exception 'القيد المصدر لازم يكون سند قيد أو قبض أو صرف لنفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists recurring_before on public.recurring_entries;
create trigger recurring_before before insert or update on public.recurring_entries for each row execute function public.recurring_before();

-- بيولّد المسودات المستحقة لحد اليوم (بيرجع عددها)
create or replace function public.run_recurring(p_company uuid, p_until date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare r record; s public.journal_entries; fy uuid; nid uuid; n int := 0; guard int;
begin
  if not public.can(p_company, 'journal_entries', 'add') then return 0; end if;
  for r in select * from public.recurring_entries where company_id = p_company and is_active and next_date <= p_until for update loop
    select * into s from public.journal_entries where id = r.source_entry_id;
    guard := 0;
    while r.next_date <= p_until and (r.end_date is null or r.next_date <= r.end_date) and guard < 24 loop
      guard := guard + 1;
      select id into fy from public.fiscal_years where company_id = p_company and r.next_date between start_date and end_date and not is_closed order by start_date desc limit 1;
      exit when fy is null;
      insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status)
      values (p_company, fy, s.entry_type, r.next_date, coalesce(s.description, r.title) || ' (متكرر ' || to_char(r.next_date, 'MM/YYYY') || ')', s.reference, s.party_name, s.cash_account_id, 'draft')
      returning id into nid;
      insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount)
      select nid, line_no, account_id, party_id, description, debit, credit, cost_center_id, currency, fx_rate, fx_amount from public.journal_lines where entry_id = s.id;
      n := n + 1;
      r.next_date := (date_trunc('month', r.next_date) + make_interval(months => r.every_months))::date + (r.day_of_month - 1);
    end loop;
    update public.recurring_entries set next_date = r.next_date, last_run = current_date,
           is_active = (r.end_date is null or r.next_date <= r.end_date) where id = r.id;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 3) الرواتب والضمان الاجتماعي
-- ---------------------------------------------------------------------
alter table public.company_settings add column if not exists ss_employee_rate numeric(6,3) not null default 7.5;
alter table public.company_settings add column if not exists ss_employer_rate numeric(6,3) not null default 14.25;
alter table public.company_settings add column if not exists ss_ceiling numeric(18,3) not null default 0;   -- 0 = بدون سقف
alter table public.company_settings add column if not exists salaries_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists ss_expense_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists ss_payable_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists wht_payable_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists salaries_payable_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists advances_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists depreciation_account_id uuid references public.accounts(id) on delete set null;
alter table public.company_settings add column if not exists accum_dep_account_id uuid references public.accounts(id) on delete set null;

create or replace function public.ensure_payroll_settings(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ensure_company_settings(p_company);
  update public.company_settings s set
    salaries_account_id         = coalesce(s.salaries_account_id,         (select id from public.accounts where company_id = p_company and code = '5201' and not is_group)),
    ss_expense_account_id       = coalesce(s.ss_expense_account_id,       (select id from public.accounts where company_id = p_company and code = '5202' and not is_group)),
    ss_payable_account_id       = coalesce(s.ss_payable_account_id,       (select id from public.accounts where company_id = p_company and code = '2105' and not is_group)),
    wht_payable_account_id      = coalesce(s.wht_payable_account_id,      (select id from public.accounts where company_id = p_company and code = '2104' and not is_group)),
    salaries_payable_account_id = coalesce(s.salaries_payable_account_id, (select id from public.accounts where company_id = p_company and code = '2106' and not is_group)),
    advances_account_id         = coalesce(s.advances_account_id,         (select id from public.accounts where company_id = p_company and code = '1107' and not is_group)),
    depreciation_account_id     = coalesce(s.depreciation_account_id,     (select id from public.accounts where company_id = p_company and code = '5213' and not is_group)),
    accum_dep_account_id        = coalesce(s.accum_dep_account_id,        (select id from public.accounts where company_id = p_company and code = '1209' and not is_group))
  where s.company_id = p_company;
end $$;

create table if not exists public.employees (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete cascade,
  code            text not null,
  name            text not null,
  national_id     text,
  ss_no           text,             -- رقم الضمان
  job_title       text,
  department      text,
  hire_date       date,
  end_date        date,
  basic_salary    numeric(18,3) not null default 0,
  allowances      numeric(18,3) not null default 0,   -- علاوات ثابتة شهرية
  ss_subject      boolean not null default true,      -- مشمول بالضمان
  ss_wage         numeric(18,3),                      -- الأجر الخاضع (فاضي = الأساسي + العلاوات)
  income_tax      numeric(18,3) not null default 0,   -- ضريبة دخل شهرية مقتطعة
  bank_name       text,
  iban            text,
  mobile          text,
  cost_center_id  uuid references public.cost_centers(id) on delete set null,
  is_active       boolean not null default true,
  notes           text,
  created_at      timestamptz not null default now(),
  unique (company_id, code)
);

create table if not exists public.payroll_runs (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  period      text not null,       -- YYYY-MM
  run_date    date not null,
  status      text not null default 'draft' check (status in ('draft','posted','cancelled')),
  entry_id    uuid references public.journal_entries(id) on delete set null,
  cancel_entry_id uuid references public.journal_entries(id) on delete set null,
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  unique (company_id, period)
);
create table if not exists public.payroll_lines (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id   uuid not null references public.employees(id) on delete restrict,
  basic         numeric(18,3) not null default 0,
  allowances    numeric(18,3) not null default 0,
  overtime      numeric(18,3) not null default 0,
  other_add     numeric(18,3) not null default 0,
  ss_wage       numeric(18,3) not null default 0,
  ss_employee   numeric(18,3) not null default 0,
  ss_employer   numeric(18,3) not null default 0,
  income_tax    numeric(18,3) not null default 0,
  advances      numeric(18,3) not null default 0,   -- خصم سلف
  other_ded     numeric(18,3) not null default 0,
  gross         numeric(18,3) not null default 0,
  net           numeric(18,3) not null default 0,
  notes         text,
  unique (run_id, employee_id)
);

create or replace function public.payroll_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs;
begin
  if tg_table_name = 'payroll_runs' then
    if tg_op = 'DELETE' then if old.status <> 'draft' then raise exception 'مسيّر الرواتب مرحّل، ما بينحذف'; end if; return old; end if;
    if not public.is_internal() then
      if tg_op = 'UPDATE' and old.status <> 'draft' then raise exception 'مسيّر الرواتب مرحّل، ما بينعدّل'; end if;
      if new.status <> 'draft' then raise exception 'الترحيل من زر «ترحيل» بس'; end if;
      new.entry_id := case when tg_op = 'UPDATE' then old.entry_id end; new.cancel_entry_id := case when tg_op = 'UPDATE' then old.cancel_entry_id end;
    end if;
    if new.period !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'الشهر لازم يكون بصيغة سنة-شهر'; end if;
    return new;
  end if;
  select * into r from public.payroll_runs where id = coalesce(new.run_id, old.run_id);
  if r.status <> 'draft' and not public.is_internal() then raise exception 'مسيّر الرواتب مرحّل'; end if;
  if tg_op = 'DELETE' then return old; end if;
  if not exists (select 1 from public.employees where id = new.employee_id and company_id = r.company_id) then raise exception 'الموظف مش لهالشركة'; end if;
  new.gross := new.basic + new.allowances + new.overtime + new.other_add;
  new.net := new.gross - new.ss_employee - new.income_tax - new.advances - new.other_ded;
  return new;
end $$;
drop trigger if exists payroll_runs_guard on public.payroll_runs;
create trigger payroll_runs_guard before insert or update or delete on public.payroll_runs for each row execute function public.payroll_guard();
drop trigger if exists payroll_lines_guard on public.payroll_lines;
create trigger payroll_lines_guard before insert or update or delete on public.payroll_lines for each row execute function public.payroll_guard();

-- تعبئة المسيّر من الموظفين الفعّالين (بيمسح السطور الحالية)
create or replace function public.payroll_fill(p_run uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings; n int;
begin
  select * into r from public.payroll_runs where id = p_run;
  if r.id is null then raise exception 'المسيّر مش موجود'; end if;
  if not public.can(r.company_id, 'payroll', 'edit') then raise exception 'ما عندك صلاحية على الرواتب'; end if;
  if r.status <> 'draft' then raise exception 'مسيّر الرواتب مرحّل'; end if;
  perform public.ensure_payroll_settings(r.company_id);
  select * into st from public.company_settings where company_id = r.company_id;
  delete from public.payroll_lines where run_id = p_run;
  insert into public.payroll_lines (run_id, employee_id, basic, allowances, ss_wage, ss_employee, ss_employer, income_tax)
  select p_run, e.id, e.basic_salary, e.allowances, w.wage,
         case when e.ss_subject then round(w.wage * st.ss_employee_rate / 100, 3) else 0 end,
         case when e.ss_subject then round(w.wage * st.ss_employer_rate / 100, 3) else 0 end,
         e.income_tax
  from public.employees e
  cross join lateral (select case when not e.ss_subject then 0
                                  when st.ss_ceiling > 0 then least(coalesce(e.ss_wage, e.basic_salary + e.allowances), st.ss_ceiling)
                                  else coalesce(e.ss_wage, e.basic_salary + e.allowances) end as wage) w
  where e.company_id = r.company_id and e.is_active
    and (e.hire_date is null or e.hire_date <= (r.period || '-01')::date + interval '1 month' - interval '1 day')
    and (e.end_date is null or e.end_date >= (r.period || '-01')::date);
  get diagnostics n = row_count;
  return n;
end $$;

-- إعادة حساب الضمان لسطر بعد تعديل الأجر الخاضع (من الشاشة)
create or replace function public.payroll_recalc_ss(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings;
begin
  select * into r from public.payroll_runs where id = p_run;
  if not public.can(r.company_id, 'payroll', 'edit') then raise exception 'ما عندك صلاحية على الرواتب'; end if;
  select * into st from public.company_settings where company_id = r.company_id;
  if r.status <> 'draft' then raise exception 'مسيّر الرواتب مرحّل'; end if;
  update public.payroll_lines l set ss_wage = case when st.ss_ceiling > 0 then least(l.ss_wage, st.ss_ceiling) else l.ss_wage end where l.run_id = p_run;
  update public.payroll_lines l set ss_employee = round(l.ss_wage * st.ss_employee_rate / 100, 3), ss_employer = round(l.ss_wage * st.ss_employer_rate / 100, 3)
   where l.run_id = p_run;
end $$;

-- ترحيل الرواتب: قيد واحد
create or replace function public.post_payroll(p_run uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; st public.company_settings; fy uuid; eid uuid; ln int := 0; s record; descr text; d date;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if r.id is null then raise exception 'المسيّر مش موجود'; end if;
  if not public.can(r.company_id, 'payroll', 'post') then raise exception 'ما عندك صلاحية ترحيل الرواتب'; end if;
  if r.status <> 'draft' then raise exception 'المسيّر مرحّل من قبل'; end if;
  perform public.ensure_payroll_settings(r.company_id);
  select * into st from public.company_settings where company_id = r.company_id;
  if st.salaries_account_id is null or st.salaries_payable_account_id is null or st.ss_payable_account_id is null or st.ss_expense_account_id is null then
    raise exception 'حدّد حسابات الرواتب بشاشة «حسابات الربط»';
  end if;
  select coalesce(sum(gross),0) g, coalesce(sum(ss_employee),0) se, coalesce(sum(ss_employer),0) sr, coalesce(sum(income_tax),0) t,
         coalesce(sum(advances),0) a, coalesce(sum(other_ded),0) o, coalesce(sum(net),0) n, count(*) c into s
    from public.payroll_lines where run_id = p_run;
  if s.c = 0 or s.g <= 0 then raise exception 'المسيّر فاضي'; end if;
  if s.t > 0 and st.wht_payable_account_id is null then raise exception 'حدّد حساب أمانات ضريبة الدخل'; end if;
  if s.a > 0 and st.advances_account_id is null then raise exception 'حدّد حساب ذمم/سلف الموظفين'; end if;
  d := r.run_date;
  select id into fy from public.fiscal_years where company_id = r.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ المسيّر'; end if;
  descr := 'رواتب شهر ' || r.period;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (r.company_id, fy, 'payroll', d, descr, 'رواتب ' || r.period, 'draft') returning id into eid;
  -- المصروف (حسب مركز كلفة الموظف)
  for s in select e.cost_center_id cc, sum(l.gross) g, sum(l.ss_employer) sr from public.payroll_lines l join public.employees e on e.id = l.employee_id
           where l.run_id = p_run group by 1 loop
    if s.g > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, st.salaries_account_id, descr, s.g, 0, s.cc); end if;
    if s.sr > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, st.ss_expense_account_id, 'حصة المنشأة بالضمان - ' || descr, s.sr, 0, s.cc); end if;
  end loop;
  select coalesce(sum(ss_employee),0) se, coalesce(sum(ss_employer),0) sr, coalesce(sum(income_tax),0) t, coalesce(sum(advances),0) a,
         coalesce(sum(other_ded),0) o, coalesce(sum(net),0) n into s from public.payroll_lines where run_id = p_run;
  if s.se + s.sr > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.ss_payable_account_id, 'اشتراكات الضمان - ' || descr, 0, s.se + s.sr); end if;
  if s.t > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.wht_payable_account_id, 'ضريبة دخل مقتطعة - ' || descr, 0, s.t); end if;
  if s.a > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.advances_account_id, 'خصم سلف - ' || descr, 0, s.a); end if;
  -- الخصومات الأخرى (جزاءات/غياب) بتخفّض مصروف الرواتب
  if s.o > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.salaries_account_id, 'خصومات أخرى - ' || descr, 0, s.o); end if;
  if s.n > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.salaries_payable_account_id, 'صافي الرواتب المستحقة - ' || descr, 0, s.n); end if;
  if (select sum(debit) - sum(credit) from public.journal_lines where entry_id = eid) <> 0 then raise exception 'قيد الرواتب مش متوازن'; end if;
  update public.journal_entries set status = 'posted', total = (select sum(debit) from public.journal_lines where entry_id = eid), posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.payroll_runs set status = 'posted', entry_id = eid where id = p_run;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), r.company_id, 'ترحيل', 'payroll', p_run::text, jsonb_build_object('period', r.period));
  return eid;
end $$;

create or replace function public.cancel_payroll(p_run uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare r public.payroll_runs; nid uuid;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if not public.can(r.company_id, 'payroll', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.status <> 'posted' then raise exception 'بس المسيّر المرحّل بينلغى'; end if;
  nid := public.reverse_internal(r.entry_id, p_date, 'إلغاء رواتب شهر ' || r.period);
  update public.payroll_runs set status = 'cancelled', cancel_entry_id = nid where id = p_run;
  perform set_config('sumou.internal', '', true);
end $$;

-- ---------------------------------------------------------------------
-- 4) الأصول الثابتة والاستهلاك (القسط الثابت شهرياً)
-- ---------------------------------------------------------------------
create table if not exists public.fixed_assets (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete cascade,
  code               text not null,
  name               text not null,
  category           text,
  purchase_date      date not null,
  dep_start          date not null,            -- بداية الاستهلاك
  cost               numeric(18,3) not null check (cost > 0),
  salvage            numeric(18,3) not null default 0 check (salvage >= 0),
  life_months        int not null check (life_months > 0),
  opening_accum      numeric(18,3) not null default 0,   -- مجمع استهلاك سابق (للأصول القديمة)
  asset_account_id   uuid references public.accounts(id) on delete set null,
  accum_account_id   uuid references public.accounts(id) on delete set null,
  expense_account_id uuid references public.accounts(id) on delete set null,
  cost_center_id     uuid references public.cost_centers(id) on delete set null,
  location           text,
  serial_no          text,
  status             text not null default 'active' check (status in ('active','disposed')),
  disposed_date      date,
  notes              text,
  created_at         timestamptz not null default now(),
  unique (company_id, code)
);
create table if not exists public.depreciation_runs (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  period_to   date not null,
  entry_id    uuid references public.journal_entries(id) on delete set null,
  status      text not null default 'posted' check (status in ('posted','cancelled')),
  cancel_entry_id uuid references public.journal_entries(id) on delete set null,
  total       numeric(18,3) not null default 0,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create table if not exists public.depreciation_lines (
  id        uuid primary key default gen_random_uuid(),
  run_id    uuid not null references public.depreciation_runs(id) on delete cascade,
  asset_id  uuid not null references public.fixed_assets(id) on delete restrict,
  from_date date not null,
  to_date   date not null,
  months    int not null,
  amount    numeric(18,3) not null
);

-- مجمع الاستهلاك لأصل (السابق + الدورات المرحّلة)
create or replace function public.asset_accum(p_asset uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.fixed_assets f where f.id = p_asset and public.has_company(f.company_id)) then
    coalesce((select opening_accum from public.fixed_assets where id = p_asset), 0)
       + coalesce((select sum(l.amount) from public.depreciation_lines l join public.depreciation_runs r on r.id = l.run_id
                   where l.asset_id = p_asset and r.status = 'posted'), 0) end;
$$;
create or replace function public.asset_last_dep(p_asset uuid) returns date
language sql stable security definer set search_path = public as $$
  select max(l.to_date) from public.depreciation_lines l join public.depreciation_runs r on r.id = l.run_id
   where l.asset_id = p_asset and r.status = 'posted' and public.has_company(r.company_id);
$$;

create or replace function public.assets_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.depreciation_lines l join public.depreciation_runs r on r.id = l.run_id where l.asset_id = old.id and r.status = 'posted') then
      raise exception 'الأصل إله استهلاك مرحّل، ما بينحذف. علّمه «مستبعد» بدل الحذف';
    end if;
    return old;
  end if;
  if new.salvage >= new.cost then raise exception 'قيمة الخردة لازم تكون أقل من الكلفة'; end if;
  if tg_op = 'UPDATE' and (new.cost <> old.cost or new.life_months <> old.life_months or new.dep_start <> old.dep_start or new.salvage <> old.salvage or new.opening_accum <> old.opening_accum)
     and exists (select 1 from public.depreciation_lines l join public.depreciation_runs r on r.id = l.run_id where l.asset_id = old.id and r.status = 'posted') then
    raise exception 'الأصل إله استهلاك مرحّل: ما بتقدر تغيّر الكلفة أو العمر أو تاريخ البداية';
  end if;
  return new;
end $$;
drop trigger if exists assets_guard on public.fixed_assets;
create trigger assets_guard before insert or update or delete on public.fixed_assets for each row execute function public.assets_guard();

-- احتساب الاستهلاك (معاينة بدون ترحيل)
create or replace function public.depreciation_preview(p_company uuid, p_to date)
returns table (asset_id uuid, from_date date, to_date date, months int, amount numeric)
language plpgsql stable security definer set search_path = public as $$
declare a record; last date; f date; t date; m int; monthly numeric; remain numeric; amt numeric;
begin
  if not public.can(p_company, 'fixed_assets', 'view') then raise exception 'ما عندك صلاحية على الأصول'; end if;
  t := (date_trunc('month', p_to) + interval '1 month' - interval '1 day')::date;
  for a in select * from public.fixed_assets where company_id = p_company and status = 'active' and dep_start <= t order by code loop
    last := public.asset_last_dep(a.id);
    f := coalesce(last + 1, date_trunc('month', a.dep_start)::date);
    if f > t then continue; end if;
    m := (extract(year from age(t + 1, f)) * 12 + extract(month from age(t + 1, f)))::int;
    if m <= 0 then continue; end if;
    monthly := round((a.cost - a.salvage) / a.life_months, 3);
    remain := (a.cost - a.salvage) - public.asset_accum(a.id);
    amt := least(remain, monthly * m);
    if amt <= 0.0005 then continue; end if;
    asset_id := a.id; from_date := f; to_date := t; months := m; amount := amt; return next;
  end loop;
end $$;

create or replace function public.post_depreciation(p_company uuid, p_to date) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; fy uuid; eid uuid; rid uuid; ln int := 0; r record; tot numeric := 0; t date; descr text;
begin
  if not public.can(p_company, 'fixed_assets', 'post') then raise exception 'ما عندك صلاحية ترحيل الاستهلاك'; end if;
  perform public.ensure_payroll_settings(p_company);
  select * into st from public.company_settings where company_id = p_company;
  t := (date_trunc('month', p_to) + interval '1 month' - interval '1 day')::date;
  select id into fy from public.fiscal_years where company_id = p_company and t between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', t; end if;
  if not exists (select 1 from public.depreciation_preview(p_company, p_to)) then raise exception 'ما في استهلاك مستحق لهالتاريخ'; end if;
  descr := 'استهلاك الأصول لغاية ' || to_char(t, 'DD/MM/YYYY');
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.depreciation_runs (company_id, period_to) values (p_company, t) returning id into rid;
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (p_company, fy, 'depreciation', t, descr, 'استهلاك ' || to_char(t, 'MM/YYYY'), 'draft') returning id into eid;
  for r in select p.*, a.name, a.code, coalesce(a.expense_account_id, st.depreciation_account_id) ex, coalesce(a.accum_account_id, st.accum_dep_account_id) ac, a.cost_center_id cc
           from public.depreciation_preview(p_company, p_to) p join public.fixed_assets a on a.id = p.asset_id loop
    if r.ex is null or r.ac is null then raise exception 'حدّد حساب مصروف الاستهلاك ومجمع الاستهلاك للأصل «%»', r.name; end if;
    insert into public.depreciation_lines (run_id, asset_id, from_date, to_date, months, amount) values (rid, r.asset_id, r.from_date, r.to_date, r.months, r.amount);
    ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, r.ex, 'استهلاك ' || r.code || ' ' || r.name, r.amount, 0, r.cc);
    ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, r.ac, 'مجمع استهلاك ' || r.code || ' ' || r.name, 0, r.amount);
    tot := tot + r.amount;
  end loop;
  update public.journal_entries set status = 'posted', total = tot, posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.depreciation_runs set entry_id = eid, total = tot where id = rid;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details) values (auth.uid(), p_company, 'ترحيل', 'fixed_assets', rid::text, jsonb_build_object('to', t, 'total', tot));
  return rid;
end $$;

create or replace function public.cancel_depreciation(p_run uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare r public.depreciation_runs; nid uuid;
begin
  select * into r from public.depreciation_runs where id = p_run for update;
  if not public.can(r.company_id, 'fixed_assets', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.status <> 'posted' then raise exception 'الدورة ملغاة من قبل'; end if;
  if exists (select 1 from public.depreciation_runs x where x.company_id = r.company_id and x.status = 'posted' and x.created_at > r.created_at) then
    raise exception 'ألغِ دورات الاستهلاك الأحدث أول';
  end if;
  nid := public.reverse_internal(r.entry_id, greatest(p_date, r.period_to), 'إلغاء استهلاك لغاية ' || to_char(r.period_to, 'DD/MM/YYYY'));
  update public.depreciation_runs set status = 'cancelled', cancel_entry_id = nid where id = p_run;
  perform set_config('sumou.internal', '', true);
end $$;

-- ---------------------------------------------------------------------
-- 5) التسوية البنكية
-- ---------------------------------------------------------------------
create table if not exists public.bank_recons (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id) on delete cascade,
  account_id        uuid not null references public.accounts(id) on delete restrict,
  statement_date    date not null,
  statement_balance numeric(18,3) not null,
  status            text not null default 'open' check (status in ('open','done')),
  notes             text,
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now()
);
create table if not exists public.bank_cleared (
  line_id   uuid primary key references public.journal_lines(id) on delete cascade,
  recon_id  uuid not null references public.bank_recons(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade
);
create or replace function public.bank_cleared_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare rc public.bank_recons;
begin
  select * into rc from public.bank_recons where id = coalesce(new.recon_id, old.recon_id);
  if rc.status = 'done' then raise exception 'التسوية مقفلة'; end if;
  if tg_op = 'DELETE' then return old; end if;
  new.company_id := rc.company_id;
  if not exists (select 1 from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                 where l.id = new.line_id and l.account_id = rc.account_id and e.company_id = rc.company_id and e.status in ('posted','reversed')) then
    raise exception 'الحركة مش على حساب البنك هاد';
  end if;
  return new;
end $$;
drop trigger if exists bank_cleared_check on public.bank_cleared;
create trigger bank_cleared_check before insert or update or delete on public.bank_cleared for each row execute function public.bank_cleared_check();

-- حركات البنك لغاية تاريخ الكشف: اللي مش مسوّاة بتسوية سابقة مقفلة
drop function if exists public.rep_bank_lines(uuid);
create or replace function public.rep_bank_lines(p_recon uuid)
returns table (line_id uuid, entry_type text, entry_no int, entry_date date, description text, reference text, debit numeric, credit numeric, cleared boolean, doc_code text)
language plpgsql stable security definer set search_path = public as $$
declare rc public.bank_recons;
begin
  select * into rc from public.bank_recons where id = p_recon;
  if not public.can(rc.company_id, 'bank_recon', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query
  select l.id, e.entry_type, e.entry_no, e.entry_date, coalesce(l.description, e.description), e.reference, l.debit, l.credit,
         exists (select 1 from public.bank_cleared c where c.line_id = l.id and c.recon_id = p_recon), e.doc_code
  from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.account_id = rc.account_id and e.company_id = rc.company_id and e.status in ('posted','reversed') and e.entry_type <> 'closing'
    and e.entry_date <= rc.statement_date
    and e.fiscal_year_id = (select id from public.fiscal_years where company_id = rc.company_id and rc.statement_date between start_date and end_date order by start_date desc limit 1)
    and not exists (select 1 from public.bank_cleared c join public.bank_recons r2 on r2.id = c.recon_id where c.line_id = l.id and c.recon_id <> p_recon)
  order by e.entry_date, e.entry_no;
end $$;
-- رصيد الدفاتر لحساب لتاريخ (ضمن السنة المالية تبعت التاريخ، مع الافتتاحي وبدون الإقفال)
create or replace function public.account_book_balance(p_company uuid, p_account uuid, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.debit - l.credit), 0) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
  where l.account_id = p_account and e.company_id = p_company and e.status in ('posted','reversed') and e.entry_type <> 'closing'
    and e.entry_date <= p_date and public.has_company(p_company)
    and e.fiscal_year_id = (select id from public.fiscal_years where company_id = p_company and p_date between start_date and end_date order by start_date desc limit 1);
$$;
-- رصيد مسوّى سابقاً (من تسويات مقفلة)
create or replace function public.bank_prior_cleared(p_recon uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.debit - l.credit), 0) from public.bank_cleared c join public.bank_recons r on r.id = c.recon_id
  join public.journal_lines l on l.id = c.line_id
  where c.recon_id <> p_recon and r.status = 'done' and public.can(r.company_id, 'bank_recon', 'view') and r.account_id = (select account_id from public.bank_recons where id = p_recon)
    and r.company_id = (select company_id from public.bank_recons where id = p_recon);
$$;

-- ---------------------------------------------------------------------
-- 6) المرفقات (الملفات بالتخزين، والبيانات بجدول)
-- ---------------------------------------------------------------------
create table if not exists public.attachments (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  entity      text not null,         -- entry | invoice | cheque | stock_doc | asset | employee | payroll
  entity_id   uuid not null,
  path        text not null,
  file_name   text not null,
  mime        text,
  size        bigint,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists attachments_entity_idx on public.attachments (entity, entity_id);

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public) values ('attachments', 'attachments', false) on conflict (id) do nothing;
    insert into storage.buckets (id, name, public) values ('backups', 'backups', false) on conflict (id) do nothing;
    execute 'drop policy if exists sumou_att_select on storage.objects';
    execute 'drop policy if exists sumou_att_insert on storage.objects';
    execute 'drop policy if exists sumou_att_delete on storage.objects';
    execute 'drop policy if exists sumou_bak_all on storage.objects';
    execute $p$create policy sumou_att_select on storage.objects for select to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy sumou_att_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy sumou_att_delete on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy sumou_bak_all on storage.objects for all to authenticated
      using (bucket_id = 'backups' and public.is_admin()) with check (bucket_id = 'backups' and public.is_admin())$p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 7) الحماية والصلاحيات
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['cost_centers','currencies','recurring_entries','employees','payroll_runs','fixed_assets','depreciation_runs','bank_recons','attachments'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
alter table public.payroll_lines enable row level security;
alter table public.depreciation_lines enable row level security;
alter table public.bank_cleared enable row level security;

drop policy if exists cc_select on public.cost_centers;
create policy cc_select on public.cost_centers for select to authenticated using (public.has_company(company_id));
drop policy if exists cc_write on public.cost_centers;
create policy cc_write on public.cost_centers for all to authenticated using (public.can(company_id, 'accounts', 'edit')) with check (public.can(company_id, 'accounts', 'edit'));
drop policy if exists cur_select on public.currencies;
create policy cur_select on public.currencies for select to authenticated using (public.has_company(company_id));
drop policy if exists cur_write on public.currencies;
create policy cur_write on public.currencies for all to authenticated using (public.can(company_id, 'accounts', 'edit')) with check (public.can(company_id, 'accounts', 'edit'));

drop policy if exists rec_select on public.recurring_entries;
create policy rec_select on public.recurring_entries for select to authenticated using (public.can(company_id, 'journal_entries', 'view'));
drop policy if exists rec_write on public.recurring_entries;
create policy rec_write on public.recurring_entries for all to authenticated using (public.can(company_id, 'journal_entries', 'add')) with check (public.can(company_id, 'journal_entries', 'add'));

drop policy if exists emp_select on public.employees;
create policy emp_select on public.employees for select to authenticated using (public.can(company_id, 'payroll', 'view'));
drop policy if exists emp_write on public.employees;
create policy emp_write on public.employees for all to authenticated using (public.can(company_id, 'payroll', 'edit')) with check (public.can(company_id, 'payroll', 'edit'));
drop policy if exists pr_select on public.payroll_runs;
create policy pr_select on public.payroll_runs for select to authenticated using (public.can(company_id, 'payroll', 'view'));
drop policy if exists pr_write on public.payroll_runs;
create policy pr_write on public.payroll_runs for all to authenticated using (public.can(company_id, 'payroll', 'edit')) with check (public.can(company_id, 'payroll', 'edit'));
drop policy if exists pl_all on public.payroll_lines;
create policy pl_all on public.payroll_lines for all to authenticated
  using (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'view')))
  with check (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'edit')));

drop policy if exists fa_select on public.fixed_assets;
create policy fa_select on public.fixed_assets for select to authenticated using (public.can(company_id, 'fixed_assets', 'view'));
drop policy if exists fa_write on public.fixed_assets;
create policy fa_write on public.fixed_assets for all to authenticated using (public.can(company_id, 'fixed_assets', 'edit')) with check (public.can(company_id, 'fixed_assets', 'edit'));
drop policy if exists dr_select on public.depreciation_runs;
create policy dr_select on public.depreciation_runs for select to authenticated using (public.can(company_id, 'fixed_assets', 'view'));
drop policy if exists dl_select on public.depreciation_lines;
create policy dl_select on public.depreciation_lines for select to authenticated
  using (exists (select 1 from public.depreciation_runs r where r.id = run_id and public.can(r.company_id, 'fixed_assets', 'view')));

drop policy if exists br_select on public.bank_recons;
create policy br_select on public.bank_recons for select to authenticated using (public.can(company_id, 'bank_recon', 'view'));
drop policy if exists br_write on public.bank_recons;
create policy br_write on public.bank_recons for all to authenticated using (public.can(company_id, 'bank_recon', 'edit')) with check (public.can(company_id, 'bank_recon', 'edit'));
drop policy if exists bc_all on public.bank_cleared;
create policy bc_all on public.bank_cleared for all to authenticated
  using (public.can(company_id, 'bank_recon', 'view'))
  with check (exists (select 1 from public.bank_recons r where r.id = recon_id and public.can(r.company_id, 'bank_recon', 'edit')));

drop policy if exists att_select on public.attachments;
create policy att_select on public.attachments for select to authenticated using (public.has_company(company_id));
drop policy if exists att_insert on public.attachments;
create policy att_insert on public.attachments for insert to authenticated with check (public.has_company(company_id));
drop policy if exists att_delete on public.attachments;
create policy att_delete on public.attachments for delete to authenticated using (public.has_company(company_id) and (created_by = auth.uid() or public.is_admin()));

grant select, insert, update, delete on public.cost_centers, public.currencies, public.recurring_entries, public.employees, public.payroll_runs,
  public.payroll_lines, public.fixed_assets, public.bank_recons, public.bank_cleared, public.attachments to authenticated;
grant select on public.depreciation_runs, public.depreciation_lines to authenticated;
grant execute on function public.dash_kpis(uuid, uuid, date), public.pending_posts(uuid), public.run_recurring(uuid, date),
  public.payroll_fill(uuid), public.payroll_recalc_ss(uuid), public.post_payroll(uuid), public.cancel_payroll(uuid, date), public.ensure_payroll_settings(uuid),
  public.depreciation_preview(uuid, date), public.post_depreciation(uuid, date), public.cancel_depreciation(uuid, date), public.asset_accum(uuid),
  public.rep_bank_lines(uuid), public.account_book_balance(uuid, uuid, date), public.bank_prior_cleared(uuid),
  public.rep_cost_centers(uuid, date, date), public.rep_fx_balances(uuid, date) to authenticated;

-- صلاحيات المجموعات الافتراضية للشاشات الجديدة
update public.user_groups set permissions = permissions || '{"payroll":{"view":true,"add":true,"edit":true,"print":true,"post":true},"fixed_assets":{"view":true,"add":true,"edit":true,"print":true,"post":true},"bank_recon":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb
 where name = 'محاسب' and not (permissions ? 'payroll');
update public.user_groups set permissions = permissions || '{"payroll":{"view":true,"add":true,"edit":true},"fixed_assets":{"view":true,"add":true,"edit":true},"bank_recon":{"view":true}}'::jsonb
 where name = 'مدخل بيانات' and not (permissions ? 'payroll');
update public.user_groups set permissions = permissions || '{"payroll":{"view":true,"print":true},"fixed_assets":{"view":true,"print":true},"bank_recon":{"view":true,"print":true}}'::jsonb
 where name = 'مشاهد' and not (permissions ? 'payroll');


-- #################### 14_backup.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 14: النسخ الاحتياطي والاسترجاع لكل شركة
--  النسخة = ملف JSON فيه كل جداول الشركة. الاسترجاع بيرجّع الشركة كاملة
--  بنفس أرقامها (لما تكون الشركة مش موجودة: قاعدة جديدة أو شركة انحذفت)
-- =====================================================================

-- ترتيب الجداول مهم للاسترجاع (الأب قبل الابن)
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'party_categories',   'company_id = $1', 'party_type, code'),
   (8,  'parties',            'company_id = $1', 'code'),
   (9,  'item_categories',    'company_id = $1', 'code'),
   (10,  'items',              'company_id = $1', 'code'),
   (11,  'warehouses',         'company_id = $1', 'code'),
   (12,  'journal_entries',    'company_id = $1', 'created_at'),
   (13,  'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (14,  'invoices',           'company_id = $1', 'created_at'),
   (15,  'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (16,  'cheques',            'company_id = $1', 'created_at'),
   (17,  'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (18,  'stock_docs',         'company_id = $1', 'created_at'),
   (19,  'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (20,  'stock_moves',        'company_id = $1', 'created_at'),
   (21,  'obligations',        'company_id = $1', 'due_date'),
   (22,  'recurring_entries',  'company_id = $1', 'created_at'),
   (23,  'employees',          'company_id = $1', 'code'),
   (24,  'payroll_runs',       'company_id = $1', 'period'),
   (25,  'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (26,  'fixed_assets',       'company_id = $1', 'code'),
   (27,  'depreciation_runs',  'company_id = $1', 'created_at'),
   (28,  'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (29,  'bank_recons',        'company_id = $1', 'created_at'),
   (30,  'bank_cleared',       'company_id = $1', 'line_id'),
   (31,  'attachments',        'company_id = $1', 'created_at');
$$;

create or replace function public.backup_company(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; out jsonb := '{}'::jsonb; part jsonb; c public.companies;
begin
  if not public.is_admin() then raise exception 'النسخ الاحتياطي لمدير النظام بس'; end if;
  select * into c from public.companies where id = p_company;
  if c.id is null then raise exception 'الشركة مش موجودة'; end if;
  for r in select * from public.backup_tables() order by ord loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by %s), ''[]''::jsonb) from public.%I t where %s', r.ordby, r.tbl, r.cond)
      into part using p_company;
    out := out || jsonb_build_object(r.tbl, part);
  end loop;
  return jsonb_build_object('app', 'sumou-erp', 'version', 1, 'company_id', p_company, 'company_name', c.name,
                            'created_at', now(), 'created_by', auth.uid(), 'tables', out);
end $$;

create or replace function public.restore_company(p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare r record; cid uuid; rows jsonb; n int; cols text;
begin
  if not public.is_admin() then raise exception 'الاسترجاع لمدير النظام بس'; end if;
  if p_data ->> 'app' <> 'sumou-erp' or p_data -> 'tables' is null then raise exception 'الملف مش نسخة احتياطية من السمو ERP'; end if;
  cid := (p_data ->> 'company_id')::uuid;
  if exists (select 1 from public.companies where id = cid) then
    raise exception 'الشركة «%» موجودة. الاسترجاع بيرجّع شركة انحذفت أو لقاعدة جديدة بس', p_data ->> 'company_name';
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.backup_tables() order by ord loop
    rows := coalesce(p_data -> 'tables' -> r.tbl, '[]'::jsonb);
    if jsonb_array_length(rows) = 0 then continue; end if;
    -- الروابط الذاتية والحالات اللي بتمنع الإدخال بتنحط بعدين
    if r.tbl = 'journal_entries' then
      rows := (select jsonb_agg(x - 'reversal_of' - 'reversed_by') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'invoices' then
      rows := (select jsonb_agg(x - 'original_invoice_id') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'bank_recons' then
      rows := (select jsonb_agg(jsonb_set(x, '{status}', '"open"')) from jsonb_array_elements(rows) x);
    elsif r.tbl = 'companies' then   -- المستخدم اللي أنشأها ممكن ما يكون موجود بقاعدة جديدة
      rows := (select jsonb_agg(case when exists (select 1 from auth.users u where u.id::text = x ->> 'created_by') then x else jsonb_set(x, '{created_by}', 'null') end) from jsonb_array_elements(rows) x);
    elsif r.tbl = 'obligations' then
      rows := (select jsonb_agg(case when exists (select 1 from public.profiles u where u.id::text = x ->> 'assigned_to') then x else jsonb_set(x, '{assigned_to}', 'null') end) from jsonb_array_elements(rows) x);
    elsif r.tbl = 'accounts' then
      rows := (select jsonb_agg(x order by (x ->> 'level')::int) from jsonb_array_elements(rows) x);
    end if;
    -- الأعمدة الموجودة بالنسخة بس (عشان نسخة قديمة تنفع على إصدار أحدث)
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into cols
      from pg_attribute a where a.attrelid = ('public.' || r.tbl)::regclass and a.attnum > 0 and not a.attisdropped
       and exists (select 1 from jsonb_array_elements(rows) x where x ? a.attname);
    execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1)', r.tbl, cols, cols, r.tbl) using rows;
  end loop;
  -- إرجاع الروابط
  update public.journal_entries e set reversal_of = (x ->> 'reversal_of')::uuid, reversed_by = (x ->> 'reversed_by')::uuid
    from jsonb_array_elements(p_data -> 'tables' -> 'journal_entries') x
   where e.id = (x ->> 'id')::uuid and (x ->> 'reversal_of' is not null or x ->> 'reversed_by' is not null);
  update public.invoices i set original_invoice_id = (x ->> 'original_invoice_id')::uuid
    from jsonb_array_elements(p_data -> 'tables' -> 'invoices') x
   where i.id = (x ->> 'id')::uuid and x ->> 'original_invoice_id' is not null;
  update public.bank_recons b set status = x ->> 'status'
    from jsonb_array_elements(coalesce(p_data -> 'tables' -> 'bank_recons', '[]'::jsonb)) x where b.id = (x ->> 'id')::uuid;
  -- المدير بيوصل للشركة المسترجعة
  insert into public.user_companies (user_id, company_id) values (auth.uid(), cid) on conflict do nothing;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, 'استرجاع', 'backup', cid::text, jsonb_build_object('from', p_data ->> 'created_at'));
  return cid;
end $$;

revoke execute on function public.backup_company(uuid), public.restore_company(jsonb) from public, anon;
grant execute on function public.backup_company(uuid), public.restore_company(jsonb) to authenticated;


-- #################### 15_fixes.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 15: تصليحات المراجعة
-- =====================================================================

-- حذف مستخدم أنشأ شركة: الشركة بتضل وبينفضى «أنشأها»
alter table public.companies drop constraint if exists companies_created_by_fkey;
alter table public.companies add constraint companies_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null;

-- المسيّر الملغى ما بيقفل الشهر: بتقدر تعمل مسيّر جديد لنفس الشهر
alter table public.payroll_runs drop constraint if exists payroll_runs_company_id_period_key;
create unique index if not exists payroll_runs_period_uq on public.payroll_runs (company_id, period) where status <> 'cancelled';

-- سطور التسوية البنكية والرواتب: العرض بصلاحية «عرض»، والتعديل والحذف بصلاحية «تعديل»
drop policy if exists bc_all on public.bank_cleared;
drop policy if exists bc_select on public.bank_cleared;
drop policy if exists bc_write on public.bank_cleared;
create policy bc_select on public.bank_cleared for select to authenticated using (public.can(company_id, 'bank_recon', 'view'));
create policy bc_write on public.bank_cleared for all to authenticated
  using (public.can(company_id, 'bank_recon', 'edit'))
  with check (exists (select 1 from public.bank_recons r where r.id = recon_id and public.can(r.company_id, 'bank_recon', 'edit')));

drop policy if exists pl_all on public.payroll_lines;
drop policy if exists pl_select on public.payroll_lines;
drop policy if exists pl_write on public.payroll_lines;
create policy pl_select on public.payroll_lines for select to authenticated
  using (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'view')));
create policy pl_write on public.payroll_lines for all to authenticated
  using (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'edit')))
  with check (exists (select 1 from public.payroll_runs r where r.id = run_id and public.can(r.company_id, 'payroll', 'edit')));

-- المرفقات: مرفقات الموظفين والرواتب والأصول لأصحاب صلاحيتها بس، والحذف لصاحب الملف أو المدير
create or replace function public.attachment_visible(p_company uuid, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_entity when 'employee' then public.can(p_company, 'payroll', 'view')
                       when 'payroll'  then public.can(p_company, 'payroll', 'view')
                       when 'asset'    then public.can(p_company, 'fixed_assets', 'view')
                       else public.has_company(p_company) end;
$$;
drop policy if exists att_select on public.attachments;
create policy att_select on public.attachments for select to authenticated using (public.attachment_visible(company_id, entity));

do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists sumou_att_select on storage.objects';
    execute 'drop policy if exists sumou_att_delete on storage.objects';
    execute $p$create policy sumou_att_select on storage.objects for select to authenticated
      using (bucket_id = 'attachments' and exists (select 1 from public.attachments a where a.path = name and public.attachment_visible(a.company_id, a.entity)))$p$;
    execute $p$create policy sumou_att_delete on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid)
             and not exists (select 1 from public.attachments a where a.path = name and not (a.created_by = auth.uid() or public.is_admin())))$p$;
  end if;
end $$;


-- #################### 16_numbering.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 16: طريقة الترقيم (تنسيق أرقام المستندات)
--  لكل شركة ولكل نوع مستند: يدوي/تلقائي، يبدأ من جديد كل سنة أو كل شهر أو ما بيبدأ،
--  تسلسل منفصل لكل مركز كلفة أو مستودع، وشكل الرقم: عدد الخانات، حرف التنقيع، الفاصل،
--  نص سابق ولاحق، وإضافة رمز السنة/الشهر/الفرع للرقم.
--  الإعدادات بـ company_settings.numbering (jsonb)، والرقم المنسّق بعمود doc_code.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists numbering jsonb not null default '{}'::jsonb;

alter table public.journal_entries add column if not exists seq_key text;
alter table public.journal_entries add column if not exists doc_code text;
alter table public.invoices        add column if not exists seq_key text;
alter table public.invoices        add column if not exists doc_code text;
alter table public.stock_docs      add column if not exists seq_key text;
alter table public.stock_docs      add column if not exists doc_code text;

-- تعبئة المستندات القديمة بنفس ترقيمها الحالي (القيود والفواتير لكل سنة، والمخزون مستمر)
do $$
begin
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set seq_key = 'Y' || fiscal_year_id, doc_code = coalesce(doc_code, entry_no::text) where seq_key is null;
  update public.invoices        set seq_key = 'Y' || fiscal_year_id, doc_code = coalesce(doc_code, inv_no::text)   where seq_key is null;
  update public.stock_docs      set seq_key = '',                    doc_code = coalesce(doc_code, doc_no::text)   where seq_key is null;
  perform set_config('sumou.internal', '', true);
end $$;

alter table public.journal_entries alter column seq_key set default '';
alter table public.invoices        alter column seq_key set default '';
alter table public.stock_docs      alter column seq_key set default '';
alter table public.journal_entries alter column seq_key set not null;
alter table public.invoices        alter column seq_key set not null;
alter table public.stock_docs      alter column seq_key set not null;

-- القيد الفريد القديم (لكل سنة) بيتبدّل بقيد على مفتاح التسلسل
do $$
declare c record;
begin
  for c in
    select con.conname, rel.relname from pg_constraint con join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'public' and con.contype = 'u'
      and ((rel.relname = 'journal_entries' and pg_get_constraintdef(con.oid) = 'UNIQUE (company_id, fiscal_year_id, entry_type, entry_no)')
        or (rel.relname = 'invoices'        and pg_get_constraintdef(con.oid) = 'UNIQUE (company_id, fiscal_year_id, inv_type, inv_no)')
        or (rel.relname = 'stock_docs'      and pg_get_constraintdef(con.oid) = 'UNIQUE (company_id, doc_type, doc_no)'))
  loop
    execute format('alter table public.%I drop constraint %I', c.relname, c.conname);
  end loop;
end $$;
create unique index if not exists je_seq_uq  on public.journal_entries (company_id, entry_type, seq_key, entry_no);
create unique index if not exists inv_seq_uq on public.invoices (company_id, inv_type, seq_key, inv_no);
create unique index if not exists sd_seq_uq  on public.stock_docs (company_id, doc_type, seq_key, doc_no);

-- ---------------------------------------------------------------------
-- القاعدة: الافتراضي + المحفوظ للشركة، بعد التنظيف
-- ---------------------------------------------------------------------
create or replace function public.numbering_rule(p_company uuid, p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d jsonb; u jsonb; r jsonb;
begin
  d := jsonb_build_object('mode', 'auto', 'reset', case when p_key like 'stock_%' then 'none' else 'year' end, 'split', 'none',
         'digits', 0, 'pad', '0', 'sep', '-', 'prefix', '', 'suffix', '',
         'add_year', false, 'year_digits', 4, 'add_month', false, 'add_split', false);
  if p_key is null then return d; end if;
  select s.numbering -> p_key into u from public.company_settings s where s.company_id = p_company;
  if u is null or jsonb_typeof(u) <> 'object' then return d; end if;
  r := d || u;
  -- تنظيف القيم
  if r->>'mode'  not in ('auto','manual') then r := r || '{"mode":"auto"}'; end if;
  if r->>'reset' not in ('none','year','month') then r := r || jsonb_build_object('reset', d->>'reset'); end if;
  if not ((p_key in ('sale','sale_return','purchase','purchase_return') and r->>'split' in ('none','cost_center','warehouse'))
       or (p_key like 'stock_%' and r->>'split' in ('none','warehouse'))) then r := r || '{"split":"none"}'; end if;
  r := r || jsonb_build_object(
    'digits', least(greatest(coalesce(case when (r->>'digits') ~ '^\d{1,3}$' then (r->>'digits')::int end, 0), 0), 12),
    'pad', left(regexp_replace(coalesce(r->>'pad', '0'), '[<>"''&\s]', '', 'g'), 1),
    'sep', left(regexp_replace(coalesce(r->>'sep', ''), '[<>"''&]', '', 'g'), 3),
    'prefix', left(regexp_replace(coalesce(r->>'prefix', ''), '[<>"''&]', '', 'g'), 15),
    'suffix', left(regexp_replace(coalesce(r->>'suffix', ''), '[<>"''&]', '', 'g'), 15),
    'year_digits', case when r->>'year_digits' = '2' then 2 else 4 end,
    'add_year',  coalesce(case when jsonb_typeof(r->'add_year')  = 'boolean' then (r->>'add_year')::boolean end, false),
    'add_month', coalesce(case when jsonb_typeof(r->'add_month') = 'boolean' then (r->>'add_month')::boolean end, false),
    'add_split', coalesce(case when jsonb_typeof(r->'add_split') = 'boolean' then (r->>'add_split')::boolean end, false));
  return r;
end $$;

-- مفتاح التسلسل حسب القاعدة
create or replace function public.numbering_key(r jsonb, p_date date, p_fy uuid, p_split uuid) returns text
language sql immutable as $$
  select concat_ws('|',
    case r->>'reset' when 'year'  then 'Y' || coalesce(p_fy::text, extract(year from p_date)::text)
                     when 'month' then 'Y' || coalesce(p_fy::text, extract(year from p_date)::text) || 'M' || to_char(p_date, 'YYYY-MM') end,
    case when r->>'split' <> 'none' then 'S' || coalesce(p_split::text, '-') end)
$$;

-- الرقم المنسّق: النص السابق + رمز الفرع + السنة + الشهر + الرقم + النص اللاحق
create or replace function public.numbering_format(r jsonb, p_no int, p_date date, p_fy uuid, p_split_code text) returns text
language plpgsql stable security definer set search_path = public as $$
declare parts text[] := '{}'; y int; n text; dg int := (r->>'digits')::int;
begin
  if p_no is null then return null; end if;
  if (r->>'add_split')::boolean and r->>'split' <> 'none' and nullif(regexp_replace(coalesce(p_split_code, ''), '[<>"''&]', '', 'g'), '') is not null then
    parts := parts || left(regexp_replace(p_split_code, '[<>"''&]', '', 'g'), 15);
  end if;
  if (r->>'add_year')::boolean then
    select extract(year from start_date)::int into y from public.fiscal_years where id = p_fy;
    y := coalesce(y, extract(year from p_date)::int);
    parts := parts || case when (r->>'year_digits')::int = 2 then lpad((y % 100)::text, 2, '0') else y::text end;
  end if;
  if (r->>'add_month')::boolean then parts := parts || to_char(p_date, 'MM'); end if;
  n := p_no::text;
  if dg > length(n) then n := lpad(n, dg, coalesce(nullif(r->>'pad', ''), '0')); end if;
  parts := parts || n;
  return coalesce(r->>'prefix', '') || array_to_string(parts, coalesce(r->>'sep', '')) || coalesce(r->>'suffix', '');
end $$;

-- ---------------------------------------------------------------------
-- الـ triggers: اسمها بيبدأ بـ aa_ عشان تشتغل قبل باقي الـ triggers
-- ---------------------------------------------------------------------
create or replace function public.aa_number_entries() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.entry_type; else co := new.company_id; ty := new.entry_type; end if;
  r := public.numbering_rule(co, case when ty in ('journal','receipt','payment') then ty end);
  fy := new.fiscal_year_id;
  k := public.numbering_key(r, new.entry_date, fy, sp);
  if tg_op = 'INSERT' then
    -- الاسترجاع من نسخة احتياطية: الرقم والتسلسل بيرجعوا مثل ما كانوا
    if intl and new.doc_code is not null and new.entry_no is not null then
      new.seq_key := coalesce(new.seq_key, k); return new;
    end if;
    if not intl and r->>'mode' = 'auto' then new.entry_no := null; end if;   -- التلقائي: الرقم من البرنامج بس
    new.seq_key := k; chg := true;
  else
    new.seq_key := coalesce(old.seq_key, new.seq_key);
    if new.entry_no is null then new.entry_no := old.entry_no; end if;
    if old.doc_code is null then return new; end if;   -- تعبئة المستندات القديمة
    if old.status = 'draft' and (new.entry_date is distinct from old.entry_date or new.fiscal_year_id is distinct from old.fiscal_year_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.entry_no = old.entry_no or (not intl and r->>'mode' = 'auto') then new.entry_no := null; end if; chg := true;
    elsif new.entry_no <> old.entry_no then
      if not intl and r->>'mode' = 'auto' then new.entry_no := old.entry_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.entry_date is distinct from old.entry_date or new.fiscal_year_id is distinct from old.fiscal_year_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.entry_no is not null and (new.entry_no <= 0 or new.entry_no > 999999999) then raise exception 'رقم المستند لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('je|' || co || '|' || ty || '|' || new.seq_key));
  if new.entry_no is null then
    select coalesce(max(x.entry_no), 0) + 1 into new.entry_no from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.seq_key = new.seq_key;
    loop   -- بعد تغيير القاعدة: نتخطى أي رقم بيطلع شكله مكرر
      new.doc_code := public.numbering_format(r, new.entry_no, new.entry_date, fy, spc);
      exit when not exists (select 1 from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id);
      new.entry_no := new.entry_no + 1;
    end loop;
  else
    if exists (select 1 from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.seq_key = new.seq_key and x.entry_no = new.entry_no and x.id <> new.id) then
      raise exception 'رقم المستند % مستعمل من قبل بنفس التسلسل', new.entry_no;
    end if;
    new.doc_code := public.numbering_format(r, new.entry_no, new.entry_date, fy, spc);
    if exists (select 1 from public.journal_entries x where x.company_id = co and x.entry_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id) then
      raise exception 'الرقم % موجود على مستند ثاني بنفس السنة', new.doc_code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_number_entries on public.journal_entries;
create trigger aa_number_entries before insert or update on public.journal_entries
  for each row execute function public.aa_number_entries();
create index if not exists je_code_idx on public.journal_entries (company_id, entry_type, doc_code);

create or replace function public.aa_number_invoices() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.inv_type; else co := new.company_id; ty := new.inv_type; end if;
  r := public.numbering_rule(co, ty);
  fy := new.fiscal_year_id;
  sp := case r->>'split' when 'cost_center' then new.cost_center_id when 'warehouse' then new.warehouse_id end;
  if sp is not null then
    if r->>'split' = 'cost_center' then select code into spc from public.cost_centers where id = sp and company_id = co;
    else select code into spc from public.warehouses where id = sp and company_id = co; end if;
  end if;
  k := public.numbering_key(r, new.inv_date, fy, sp);
  if tg_op = 'INSERT' then
    -- الاسترجاع من نسخة احتياطية: الرقم والتسلسل بيرجعوا مثل ما كانوا
    if intl and new.doc_code is not null and new.inv_no is not null then
      new.seq_key := coalesce(new.seq_key, k); return new;
    end if;
    if not intl and r->>'mode' = 'auto' then new.inv_no := null; end if;   -- التلقائي: الرقم من البرنامج بس
    new.seq_key := k; chg := true;
  else
    new.seq_key := coalesce(old.seq_key, new.seq_key);
    if new.inv_no is null then new.inv_no := old.inv_no; end if;
    if old.doc_code is null then return new; end if;   -- تعبئة المستندات القديمة
    if old.status = 'draft' and (new.inv_date is distinct from old.inv_date or new.fiscal_year_id is distinct from old.fiscal_year_id or new.cost_center_id is distinct from old.cost_center_id or new.warehouse_id is distinct from old.warehouse_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.inv_no = old.inv_no or (not intl and r->>'mode' = 'auto') then new.inv_no := null; end if; chg := true;
    elsif new.inv_no <> old.inv_no then
      if not intl and r->>'mode' = 'auto' then new.inv_no := old.inv_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.inv_date is distinct from old.inv_date or new.fiscal_year_id is distinct from old.fiscal_year_id or new.cost_center_id is distinct from old.cost_center_id or new.warehouse_id is distinct from old.warehouse_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.inv_no is not null and (new.inv_no <= 0 or new.inv_no > 999999999) then raise exception 'رقم الفاتورة لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('inv|' || co || '|' || ty || '|' || new.seq_key));
  if new.inv_no is null then
    select coalesce(max(x.inv_no), 0) + 1 into new.inv_no from public.invoices x where x.company_id = co and x.inv_type = ty and x.seq_key = new.seq_key;
    loop   -- بعد تغيير القاعدة: نتخطى أي رقم بيطلع شكله مكرر
      new.doc_code := public.numbering_format(r, new.inv_no, new.inv_date, fy, spc);
      exit when not exists (select 1 from public.invoices x where x.company_id = co and x.inv_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id);
      new.inv_no := new.inv_no + 1;
    end loop;
  else
    if exists (select 1 from public.invoices x where x.company_id = co and x.inv_type = ty and x.seq_key = new.seq_key and x.inv_no = new.inv_no and x.id <> new.id) then
      raise exception 'رقم الفاتورة % مستعمل من قبل بنفس التسلسل', new.inv_no;
    end if;
    new.doc_code := public.numbering_format(r, new.inv_no, new.inv_date, fy, spc);
    if exists (select 1 from public.invoices x where x.company_id = co and x.inv_type = ty and x.doc_code = new.doc_code and x.fiscal_year_id = new.fiscal_year_id and x.id <> new.id) then
      raise exception 'الرقم % موجود على مستند ثاني بنفس السنة', new.doc_code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_number_invoices on public.invoices;
create trigger aa_number_invoices before insert or update on public.invoices
  for each row execute function public.aa_number_invoices();
create index if not exists inv_code_idx on public.invoices (company_id, inv_type, doc_code);

create or replace function public.aa_number_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; sp uuid; spc text; fy uuid; k text; co uuid; ty text; chg boolean := false; intl boolean := public.is_internal();
begin
  if tg_op = 'UPDATE' then co := old.company_id; ty := old.doc_type; else co := new.company_id; ty := new.doc_type; end if;
  r := public.numbering_rule(co, 'stock_' || ty);
  sp := case when r->>'split' = 'warehouse' then new.warehouse_id end;
  if sp is not null then select code into spc from public.warehouses where id = sp and company_id = co; end if;
  select id into fy from public.fiscal_years where company_id = co and new.doc_date between start_date and end_date order by start_date desc limit 1;
  if fy is null and r->>'reset' <> 'none' and not public.is_internal() then raise exception 'ما في سنة مالية بتاريخ السند، والترقيم بيبدأ من جديد كل سنة/شهر'; end if;
  k := public.numbering_key(r, new.doc_date, fy, sp);
  if tg_op = 'INSERT' then
    -- الاسترجاع من نسخة احتياطية: الرقم والتسلسل بيرجعوا مثل ما كانوا
    if intl and new.doc_code is not null and new.doc_no is not null then
      new.seq_key := coalesce(new.seq_key, k); return new;
    end if;
    if not intl and r->>'mode' = 'auto' then new.doc_no := null; end if;   -- التلقائي: الرقم من البرنامج بس
    new.seq_key := k; chg := true;
  else
    new.seq_key := coalesce(old.seq_key, new.seq_key);
    if new.doc_no is null then new.doc_no := old.doc_no; end if;
    if old.doc_code is null then return new; end if;   -- تعبئة المستندات القديمة
    if old.status = 'draft' and (new.doc_date is distinct from old.doc_date or new.warehouse_id is distinct from old.warehouse_id) and k is distinct from old.seq_key then
      -- المسودة انتقلت لشهر/سنة/فرع ثاني: بتاخذ رقم من التسلسل الجديد
      new.seq_key := k; if new.doc_no = old.doc_no or (not intl and r->>'mode' = 'auto') then new.doc_no := null; end if; chg := true;
    elsif new.doc_no <> old.doc_no then
      if not intl and r->>'mode' = 'auto' then new.doc_no := old.doc_no; else chg := true; end if;
    elsif old.status = 'draft' and (new.doc_date is distinct from old.doc_date or new.warehouse_id is distinct from old.warehouse_id) then chg := true;
    end if;
    if not chg then new.doc_code := old.doc_code; return new; end if;
  end if;
  if new.doc_no is not null and (new.doc_no <= 0 or new.doc_no > 999999999) then raise exception 'رقم السند لازم يكون بين 1 و 999999999'; end if;
  perform pg_advisory_xact_lock(hashtext('sd|' || co || '|' || ty || '|' || new.seq_key));
  if new.doc_no is null then
    select coalesce(max(x.doc_no), 0) + 1 into new.doc_no from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.seq_key = new.seq_key;
    loop   -- بعد تغيير القاعدة: نتخطى أي رقم بيطلع شكله مكرر
      new.doc_code := public.numbering_format(r, new.doc_no, new.doc_date, fy, spc);
      exit when not exists (select 1 from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.doc_code = new.doc_code and extract(year from x.doc_date) = extract(year from new.doc_date) and x.id <> new.id);
      new.doc_no := new.doc_no + 1;
    end loop;
  else
    if exists (select 1 from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.seq_key = new.seq_key and x.doc_no = new.doc_no and x.id <> new.id) then
      raise exception 'رقم السند % مستعمل من قبل بنفس التسلسل', new.doc_no;
    end if;
    new.doc_code := public.numbering_format(r, new.doc_no, new.doc_date, fy, spc);
    if exists (select 1 from public.stock_docs x where x.company_id = co and x.doc_type = ty and x.doc_code = new.doc_code and extract(year from x.doc_date) = extract(year from new.doc_date) and x.id <> new.id) then
      raise exception 'الرقم % موجود على مستند ثاني بنفس السنة', new.doc_code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_number_stock on public.stock_docs;
create trigger aa_number_stock before insert or update on public.stock_docs
  for each row execute function public.aa_number_stock();
create index if not exists sd_code_idx on public.stock_docs (company_id, doc_type, doc_code);

-- الصلاحيات
revoke execute on function public.numbering_rule(uuid, text), public.numbering_key(jsonb, date, uuid, uuid),
  public.numbering_format(jsonb, int, date, uuid, text) from public, anon, authenticated;
revoke execute on function public.aa_number_entries(), public.aa_number_invoices(), public.aa_number_stock() from public, anon, authenticated;
-- دوال التقارير انعملت من جديد بالمراحل 3 و4 و13: صلاحية التنفيذ للمستخدمين المسجلين بس
revoke execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text),
  public.rep_party_ledger(uuid, uuid, uuid, date, date), public.pending_posts(uuid), public.rep_bank_lines(uuid) from public, anon;
grant execute on function public.rep_ledger(uuid, uuid, uuid, date, date), public.rep_journal(uuid, uuid, date, date, text),
  public.rep_party_ledger(uuid, uuid, uuid, date, date), public.pending_posts(uuid), public.rep_bank_lines(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- فئات المواد (الأصناف)
-- ---------------------------------------------------------------------
create table if not exists public.item_categories (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);
alter table public.items add column if not exists category_id uuid references public.item_categories(id) on delete restrict;
create index if not exists items_cat_idx on public.items (category_id) where category_id is not null;

-- الصنف وفئته لازم يكونوا بنفس الشركة
create or replace function public.items_category_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists (select 1 from public.item_categories c where c.id = new.category_id and c.company_id = new.company_id) then
    raise exception 'الفئة مش لهالشركة';
  end if;
  return new;
end $$;
drop trigger if exists items_category_check on public.items;
create trigger items_category_check before insert or update of category_id, company_id on public.items
  for each row execute function public.items_category_check();
revoke execute on function public.items_category_check() from public, anon, authenticated;

create or replace function public.item_categories_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  new.code := btrim(new.code); new.name := btrim(new.name);
  if new.code = '' or new.name = '' then raise exception 'رمز الفئة واسمها مطلوبين'; end if;
  return new;
end $$;
drop trigger if exists item_categories_before on public.item_categories;
create trigger item_categories_before before insert or update on public.item_categories
  for each row execute function public.item_categories_before();
revoke execute on function public.item_categories_before() from public, anon, authenticated;

alter table public.item_categories enable row level security;
drop policy if exists icat_select on public.item_categories;
create policy icat_select on public.item_categories for select to authenticated using (public.has_company(company_id));
drop policy if exists icat_insert on public.item_categories;
create policy icat_insert on public.item_categories for insert to authenticated with check (public.can(company_id, 'items', 'add'));
drop policy if exists icat_update on public.item_categories;
create policy icat_update on public.item_categories for update to authenticated
  using (public.can(company_id, 'items', 'edit')) with check (public.can(company_id, 'items', 'edit'));
drop policy if exists icat_delete on public.item_categories;
create policy icat_delete on public.item_categories for delete to authenticated using (public.can(company_id, 'items', 'delete'));
grant select, insert, update, delete on public.item_categories to authenticated;
revoke all on public.item_categories from anon;


-- #################### 17_party_categories.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 17: فئات العملاء وفئات الموردين
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.party_categories (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  party_type text not null check (party_type in ('customer','supplier')),
  code       text not null,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, party_type, code)
);
alter table public.parties add column if not exists category_id uuid references public.party_categories(id) on delete restrict;
create index if not exists parties_cat_idx on public.parties (category_id) where category_id is not null;

-- الفئة لازم تكون لنفس الشركة ونفس النوع (فئة عملاء للعميل، وفئة موردين للمورد)
create or replace function public.parties_category_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists (select 1 from public.party_categories c
      where c.id = new.category_id and c.company_id = new.company_id and c.party_type = new.party_type) then
    raise exception 'الفئة مش لهالشركة أو مش من نفس النوع';
  end if;
  return new;
end $$;
drop trigger if exists parties_category_check on public.parties;
create trigger parties_category_check before insert or update of category_id, company_id, party_type on public.parties
  for each row execute function public.parties_category_check();
revoke execute on function public.parties_category_check() from public, anon, authenticated;

create or replace function public.party_categories_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.party_type := old.party_type; end if;
  new.code := btrim(new.code); new.name := btrim(new.name);
  if new.code = '' or new.name = '' then raise exception 'رمز الفئة واسمها مطلوبين'; end if;
  return new;
end $$;
drop trigger if exists party_categories_before on public.party_categories;
create trigger party_categories_before before insert or update on public.party_categories
  for each row execute function public.party_categories_before();
revoke execute on function public.party_categories_before() from public, anon, authenticated;

alter table public.party_categories enable row level security;
drop policy if exists pcat_select on public.party_categories;
create policy pcat_select on public.party_categories for select to authenticated using (public.has_company(company_id));
drop policy if exists pcat_insert on public.party_categories;
create policy pcat_insert on public.party_categories for insert to authenticated
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'add'));
drop policy if exists pcat_update on public.party_categories;
create policy pcat_update on public.party_categories for update to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'))
  with check (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'edit'));
drop policy if exists pcat_delete on public.party_categories;
create policy pcat_delete on public.party_categories for delete to authenticated
  using (public.can(company_id, case party_type when 'customer' then 'customers' else 'suppliers' end, 'delete'));
grant select, insert, update, delete on public.party_categories to authenticated;
revoke all on public.party_categories from anon;


-- #################### 18_posting.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 18: الترحيل
--  • الحفظ بيخزّن بس. الترحيل بكبستين منفصلات: «ترحيل للمحاسبة» و«ترحيل للمخزون».
--  • من «الأدوات ← الترحيل»: لكل نوع سند بنختار إذا بيترحّل للمحاسبة و/أو للمخزون.
--  • إلغاء الترحيل بصلاحية خاصة (unpost) لكل شاشة: السند بيرجع مسودة وبينمسح قيده/حركته.
--  الفاتورة: status = حالة المحاسبة (draft/posted/cancelled)، وstock_posted = حالة المخزون.
--  قيد كلفة البضاعة (الجرد المستمر) صار قيد لحاله بالفاتورة: cogs_entry_id.
--  سند المخزون: status = حالة المخزون، وentry_id = قيده المحاسبي (الجرد المستمر بس).
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists posting jsonb not null default '{}'::jsonb;
alter table public.invoices add column if not exists stock_posted boolean not null default false;
alter table public.invoices add column if not exists stock_posted_at timestamptz;
alter table public.invoices add column if not exists cogs_entry_id uuid references public.journal_entries(id) on delete set null;
alter table public.invoices add column if not exists cogs_in_entry boolean not null default false;  -- فواتير قديمة: الكلفة جوّا قيد الفاتورة
alter table public.invoices add column if not exists posting_ready boolean not null default false;

-- الفواتير القديمة: المرحّلة كانت بتترحّل للمخزون مع المحاسبة
do $$
begin
  if exists (select 1 from public.invoices where not posting_ready) then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.invoices i set
      stock_posted = i.status in ('posted','cancelled'),
      stock_posted_at = case when i.status in ('posted','cancelled') then i.posted_at end,
      cogs_in_entry = i.status in ('posted','cancelled') and exists (
        select 1 from public.journal_lines l where l.entry_id = i.entry_id
          and (l.description like 'كلفة البضاعة - %' or l.description like 'للمخزون - %' or l.description like 'من المخزون - %')),
      posting_ready = true
    where not i.posting_ready;
    perform set_config('sumou.internal', '', true);
  end if;
end $$;
alter table public.invoices alter column posting_ready set default false;  -- إدخال داخلي بدونها = نسخة احتياطية قديمة

-- ---------------------------------------------------------------------
-- إعدادات الترحيل لكل نوع سند (gl = للمحاسبة، stock = للمخزون)
-- ---------------------------------------------------------------------
create or replace function public.posting_flag(p_company uuid, p_kind text, p_what text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when not public.has_company(p_company) then false
    when p_what = 'stock' and p_kind in ('journal','receipt','payment') then false
    else coalesce(
      (select case when jsonb_typeof(s.posting -> p_kind -> p_what) = 'boolean' then (s.posting -> p_kind ->> p_what)::boolean end
         from public.company_settings s where s.company_id = p_company),
      true) end
$$;
revoke execute on function public.posting_flag(uuid, text, text) from public, anon;
grant execute on function public.posting_flag(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- حماية الفاتورة المرحّلة للمخزون (اسمها ab_ عشان تشتغل قبل invoices_before)
-- ---------------------------------------------------------------------
create or replace function public.ab_invoice_stock_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then
    if tg_op = 'DELETE' then return old; end if;
    -- استرجاع نسخة احتياطية قبل المرحلة 18: الفاتورة المرحّلة كانت مرحّلة للمخزون كمان
    if tg_op = 'INSERT' and not new.posting_ready then
      new.stock_posted := new.status in ('posted','cancelled');
      new.stock_posted_at := case when new.stock_posted then new.posted_at end;
      new.cogs_in_entry := new.stock_posted and exists (select 1 from public.journal_lines l where l.entry_id = new.entry_id
          and (l.description like 'كلفة البضاعة - %' or l.description like 'للمخزون - %' or l.description like 'من المخزون - %'));
      new.posting_ready := true;
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.stock_posted then raise exception 'الفاتورة مرحّلة للمخزون، ما بتنحذف. ألغِ ترحيلها أول'; end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    new.stock_posted := false; new.stock_posted_at := null; new.cogs_entry_id := null; new.cogs_in_entry := false; new.posting_ready := true;
  else
    if old.stock_posted then raise exception 'الفاتورة مرحّلة للمخزون، ما بتنعدّل. ألغِ ترحيلها أول'; end if;
    new.stock_posted := old.stock_posted; new.stock_posted_at := old.stock_posted_at; new.cogs_entry_id := old.cogs_entry_id;
    new.cogs_in_entry := old.cogs_in_entry; new.posting_ready := old.posting_ready;
  end if;
  return new;
end $$;
drop trigger if exists ab_invoice_stock_lock on public.invoices;
create trigger ab_invoice_stock_lock before insert or update or delete on public.invoices
  for each row execute function public.ab_invoice_stock_lock();
revoke execute on function public.ab_invoice_stock_lock() from public, anon, authenticated;

create or replace function public.ab_invoice_lines_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_internal() then
    if tg_op = 'UPDATE' and new.invoice_id is distinct from old.invoice_id then raise exception 'السطر ما بينقل لفاتورة ثانية'; end if;
    if exists (select 1 from public.invoices i where i.stock_posted and i.id in (
         case when tg_op = 'INSERT' then null else old.invoice_id end, case when tg_op = 'DELETE' then null else new.invoice_id end)) then
      raise exception 'الفاتورة مرحّلة للمخزون، ما بتنعدّل سطورها';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists ab_invoice_lines_lock on public.invoice_lines;
create trigger ab_invoice_lines_lock before insert or update or delete on public.invoice_lines
  for each row execute function public.ab_invoice_lines_lock();
revoke execute on function public.ab_invoice_lines_lock() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- قيد كلفة البضاعة للفاتورة (الجرد المستمر): بينعمل لما تكون مرحّلة للمحاسبة وللمخزون
-- ---------------------------------------------------------------------
create or replace function public.invoice_cogs_sync(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; st public.company_settings; v numeric; r record; descr text; eid uuid; n int;
begin
  select * into i from public.invoices where id = p_id;
  if i.id is null or i.status <> 'posted' or not i.stock_posted or i.cogs_entry_id is not null or i.cogs_in_entry then return; end if;
  select * into st from public.company_settings where company_id = i.company_id;
  if not coalesce(st.perpetual_inventory, false) then return; end if;
  select count(*) into n from public.invoice_lines l join public.items it on it.id = l.item_id
   where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock;
  if n = 0 then return; end if;
  if st.inventory_account_id is null or st.cogs_account_id is null then
    raise exception 'الجرد المستمر مفعّل: حدّد حساب المخزون وحساب كلفة البضاعة المباعة بشاشة «حسابات الربط»';
  end if;
  descr := case i.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || coalesce(i.doc_code, i.inv_no::text);
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (i.company_id, i.fiscal_year_id, 'stock', i.inv_date, case when i.inv_type in ('sale','sale_return') then 'كلفة البضاعة - ' else 'قيمة البضاعة بالمخزون - ' end || descr, i.reference, 'draft') returning id into eid;
  if i.inv_type in ('sale','sale_return') then
    select coalesce(sum(abs(qty) * unit_cost), 0) into v from public.stock_moves where source_type = 'invoice' and source_id = p_id;
    if i.inv_type = 'sale' then perform public.add_entry_pair(eid, st.cogs_account_id, st.inventory_account_id, v, 'كلفة البضاعة - ' || descr);
    else perform public.add_entry_pair(eid, st.inventory_account_id, st.cogs_account_id, v, 'كلفة البضاعة - ' || descr); end if;
  else
    for r in
      select coalesce(case when i.inv_type = 'purchase_return' then coalesce(st.purchase_return_account_id, l.account_id) else l.account_id end, st.purchase_account_id) as acc,
             sum(l.qty * case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end) as amt
      from public.invoice_lines l join public.items it on it.id = l.item_id
      where l.invoice_id = p_id and it.item_type = 'goods' and it.track_stock group by 1
    loop
      if i.inv_type = 'purchase' then perform public.add_entry_pair(eid, st.inventory_account_id, r.acc, r.amt, 'للمخزون - ' || descr);
      else perform public.add_entry_pair(eid, r.acc, st.inventory_account_id, r.amt, 'من المخزون - ' || descr); end if;
    end loop;
  end if;
  if not exists (select 1 from public.journal_lines where entry_id = eid) then
    delete from public.journal_entries where id = eid;
    return;
  end if;
  if i.cost_center_id is not null then
    update public.journal_lines l set cost_center_id = i.cost_center_id
      from public.accounts a where a.id = l.account_id and l.entry_id = eid and a.category in ('revenue','expenses');
  end if;
  update public.journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.invoices set cogs_entry_id = eid where id = p_id;
end $$;
revoke execute on function public.invoice_cogs_sync(uuid) from public, anon, authenticated;

-- حركات المخزون من الفاتورة: لما تترحّل للمخزون (ولما تنلغى وهي مرحّلة للمخزون)
create or replace function public.invoice_stock_moves() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid; sgn int; descr text;
begin
  if old.status = 'posted' and new.status = 'cancelled' then
    if new.stock_posted then
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
      select company_id, item_id, warehouse_id, coalesce((select entry_date from public.journal_entries where id = new.cancel_entry_id), current_date),
             -qty, unit_cost, 'invoice_cancel', source_id, 'إلغاء: ' || coalesce(description, ''), is_cost
      from public.stock_moves where source_type = 'invoice' and source_id = new.id;
    end if;
    if new.cogs_entry_id is not null and exists (select 1 from public.journal_entries where id = new.cogs_entry_id and status = 'posted') then
      perform public.reverse_internal(new.cogs_entry_id,
        coalesce((select entry_date from public.journal_entries where id = new.cancel_entry_id), current_date),
        'إلغاء: كلفة البضاعة');
    end if;
    return null;
  end if;
  if old.stock_posted or not new.stock_posted then return null; end if;
  sgn := case when new.inv_type in ('purchase','sale_return') then 1 else -1 end;
  w := coalesce(new.warehouse_id, public.default_warehouse(new.company_id));
  descr := case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || coalesce(new.doc_code, new.inv_no::text);
  insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
  select new.company_id, l.item_id, w, new.inv_date, sgn * l.qty,
         case when new.inv_type in ('purchase','purchase_return') then case when l.qty > 0 then round(l.subtotal / l.qty, 3) else 0 end
              else public.item_avg_cost(new.company_id, l.item_id, new.inv_date) end,
         'invoice', new.id, descr, new.inv_type in ('purchase','purchase_return') and l.qty > 0 and l.subtotal > 0
  from public.invoice_lines l join public.items it on it.id = l.item_id
  where l.invoice_id = new.id and it.item_type = 'goods' and it.track_stock;
  return null;
end $$;
drop trigger if exists invoice_stock_moves on public.invoices;
create trigger invoice_stock_moves after update of status, stock_posted on public.invoices
  for each row execute function public.invoice_stock_moves();

-- بعد ترحيل الفاتورة للمحاسبة: نتأكد إنه النوع بيترحّل للمحاسبة، ونعمل قيد الكلفة إذا لازم
create or replace function public.invoice_gl_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' then
    if not public.posting_flag(new.company_id, new.inv_type, 'gl') then
      raise exception 'هالنوع من الفواتير ما بيترحّل للمحاسبة (من «الأدوات ← الترحيل»)';
    end if;
    perform public.invoice_cogs_sync(new.id);
  end if;
  return null;
end $$;
drop trigger if exists invoice_gl_after on public.invoices;
create trigger invoice_gl_after after update of status on public.invoices
  for each row execute function public.invoice_gl_after();
revoke execute on function public.invoice_gl_after() from public, anon, authenticated;

-- إعادة حساب سطور الفاتورة (نفس حساب الترحيل للمحاسبة)
create or replace function public.invoice_recalc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; r record; gross numeric; sub numeric; tax numeric; s_sub numeric := 0; s_tax numeric := 0; s_disc numeric := 0;
begin
  select * into i from public.invoices where id = p_id;
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.invoice_lines where invoice_id = p_id order by line_no loop
    gross := round(r.qty * r.unit_price - r.discount, 3);
    if gross < 0 then raise exception 'الخصم أكبر من قيمة السطر %', r.line_no; end if;
    if i.prices_include_tax then sub := round(gross / (1 + r.tax_rate / 100), 3); tax := gross - sub;
    else sub := gross; tax := round(sub * r.tax_rate / 100, 3); end if;
    update public.invoice_lines set subtotal = sub, tax_amount = tax, line_total = sub + tax where id = r.id;
    s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + r.discount;
  end loop;
  update public.invoices set subtotal = s_sub, tax_total = s_tax, discount_total = s_disc, total = s_sub + s_tax where id = p_id;
end $$;
revoke execute on function public.invoice_recalc(uuid) from public, anon, authenticated;

-- ترحيل الفاتورة للمخزون
create or replace function public.post_invoice_stock(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices; fy public.fiscal_years; r record;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'post') then raise exception 'ما عندك صلاحية ترحيل الفواتير'; end if;
  if not public.posting_flag(i.company_id, i.inv_type, 'stock') then raise exception 'هالنوع من الفواتير ما بيترحّل للمخزون (من «الأدوات ← الترحيل»)'; end if;
  if i.stock_posted then raise exception 'الفاتورة مرحّلة للمخزون من قبل'; end if;
  if i.status = 'cancelled' then raise exception 'الفاتورة ملغاة'; end if;
  select * into fy from public.fiscal_years where id = i.fiscal_year_id;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
  if not exists (select 1 from public.invoice_lines where invoice_id = p_id) then raise exception 'الفاتورة بدون سطور'; end if;
  if i.status = 'draft' then perform public.invoice_recalc(p_id); end if;
  -- المرتجع: الأصلية لازم تكون مرحّلة للمخزون، والكمية ما بتتجاوزها
  if i.original_invoice_id is not null then
    if not exists (select 1 from public.invoices o where o.id = i.original_invoice_id and o.company_id = i.company_id and o.stock_posted
                   and o.status <> 'cancelled' and o.inv_type = replace(i.inv_type, '_return', '') and o.party_id is not distinct from i.party_id) then
      raise exception 'الفاتورة الأصلية للمرتجع لازم تكون مرحّلة للمخزون ولنفس العميل/المورد';
    end if;
    for r in select l.item_id, sum(l.qty) q, max(it.name) nm from public.invoice_lines l join public.items it on it.id = l.item_id
             where l.invoice_id = p_id group by l.item_id loop
      if r.q + coalesce((select sum(rl.qty) from public.invoice_lines rl join public.invoices ri on ri.id = rl.invoice_id
                         where ri.original_invoice_id = i.original_invoice_id and ri.stock_posted and ri.status <> 'cancelled'
                           and ri.id <> p_id and rl.item_id = r.item_id), 0)
         > coalesce((select sum(o.qty) from public.invoice_lines o where o.invoice_id = i.original_invoice_id and o.item_id = r.item_id), 0) + 0.0005 then
        raise exception 'المرتجع أكثر من الفاتورة الأصلية: «%»', r.nm;
      end if;
    end loop;
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.invoices set stock_posted = true, stock_posted_at = now() where id = p_id;
  perform public.invoice_cogs_sync(p_id);
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, 'ترحيل للمخزون', public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', coalesce(i.doc_code, i.inv_no::text)));
end $$;
revoke execute on function public.post_invoice_stock(uuid) from public, anon;
grant execute on function public.post_invoice_stock(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- سندات المخزون: الترحيل للمخزون لحال، وللمحاسبة لحال (الجرد المستمر)
-- ---------------------------------------------------------------------
create or replace function public.post_stock_doc(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; r record; n int; diff numeric; descr text; cst numeric; fy public.fiscal_years;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if not public.posting_flag(d.company_id, 'stock_' || d.doc_type, 'stock') then raise exception 'هالنوع من السندات ما بيترحّل للمخزون (من «الأدوات ← الترحيل»)'; end if;
  if d.status <> 'draft' then raise exception 'السند مرحّل من قبل'; end if;
  select * into fy from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date order by start_date desc limit 1;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
  select count(*) into n from public.stock_doc_lines where doc_id = p_id;
  if n = 0 then raise exception 'السند بدون أصناف'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || coalesce(d.doc_code, d.doc_no::text);
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.stock_doc_lines where doc_id = p_id order by line_no loop
    cst := public.item_avg_cost(d.company_id, r.item_id, d.doc_date);
    if d.doc_type = 'in' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      cst := coalesce(nullif(r.unit_cost, 0), cst);
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description, is_cost)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, r.qty, cst, 'stock_doc', p_id, descr, cst > 0);
    elsif d.doc_type = 'out' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, cst, 'stock_doc', p_id, descr);
    elsif d.doc_type = 'transfer' then
      if r.qty <= 0 then raise exception 'الكمية لازم تكون أكبر من صفر'; end if;
      insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
      values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, -r.qty, cst, 'stock_doc', p_id, descr),
             (d.company_id, r.item_id, d.to_warehouse_id, d.doc_date, r.qty, cst, 'stock_doc', p_id, descr);
    else
      if r.counted_qty is null then continue; end if;
      diff := r.counted_qty - public.stock_qty(r.item_id, d.warehouse_id, d.doc_date);
      if abs(diff) > 0.0005 then
        insert into public.stock_moves (company_id, item_id, warehouse_id, move_date, qty, unit_cost, source_type, source_id, description)
        values (d.company_id, r.item_id, d.warehouse_id, d.doc_date, diff, cst, 'stock_doc', p_id, descr || ' (تسوية)');
      end if;
      update public.stock_doc_lines set qty = diff, unit_cost = cst where id = r.id;
    end if;
  end loop;
  update public.stock_docs set status = 'posted' where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل للمخزون', 'inventory', p_id::text, jsonb_build_object('doc', descr));
end $$;

-- رقم القيد بسند المخزون بيتعبّى من النظام بس (اسمها ab_ عشان تشتغل قبل stock_docs_before)
create or replace function public.ab_stock_docs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_internal() then
    if tg_op = 'INSERT' then new.entry_id := null; else new.entry_id := old.entry_id; end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_stock_docs_guard on public.stock_docs;
create trigger ab_stock_docs_guard before insert or update on public.stock_docs
  for each row execute function public.ab_stock_docs_guard();
revoke execute on function public.ab_stock_docs_guard() from public, anon, authenticated;

create or replace function public.post_stock_doc_gl(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs; st public.company_settings; v numeric; eid uuid; fy uuid; contra uuid; descr text;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل سندات المخزون'; end if;
  if not public.posting_flag(d.company_id, 'stock_' || d.doc_type, 'gl') then raise exception 'هالنوع من السندات ما بيترحّل للمحاسبة (من «الأدوات ← الترحيل»)'; end if;
  if d.status <> 'posted' then raise exception 'رحّل السند للمخزون أول، عشان تنحسب قيمته'; end if;
  if d.entry_id is not null then raise exception 'السند مرحّل للمحاسبة من قبل'; end if;
  if d.doc_type = 'transfer' then raise exception 'سند التحويل بين المستودعات ما إله قيد محاسبي'; end if;
  select * into st from public.company_settings where company_id = d.company_id;
  if not coalesce(st.perpetual_inventory, false) then raise exception 'سندات المخزون بتترحّل للمحاسبة بس لما يكون «الجرد المستمر» مفعّل (من «حسابات الربط»)'; end if;
  select coalesce(sum(qty * unit_cost), 0) into v from public.stock_moves where source_type = 'stock_doc' and source_id = p_id;
  if abs(v) < 0.0005 then raise exception 'قيمة السند صفر، ما في قيد'; end if;
  contra := coalesce(d.account_id, st.cogs_account_id);
  if st.inventory_account_id is null or contra is null then raise exception 'حدّد حساب المخزون والحساب المقابل بشاشة «حسابات الربط»'; end if;
  select id into fy from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ السند'; end if;
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' else 'جرد ' end || coalesce(d.doc_code, d.doc_no::text);
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (d.company_id, fy, 'stock', d.doc_date, descr || coalesce(' - ' || nullif(d.notes, ''), ''), 'مخزون ' || coalesce(d.doc_code, d.doc_no::text), 'draft') returning id into eid;
  perform public.add_entry_pair(eid, st.inventory_account_id, contra, v, descr);
  update public.journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = eid;
  update public.stock_docs set entry_id = eid where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, 'ترحيل للمحاسبة', 'inventory', p_id::text, jsonb_build_object('doc', descr, 'value', v));
  return eid;
end $$;
revoke execute on function public.post_stock_doc_gl(uuid) from public, anon;
grant execute on function public.post_stock_doc_gl(uuid) to authenticated;

-- سند القيد/القبض/الصرف: نتأكد إنه النوع بيترحّل للمحاسبة
create or replace function public.entry_gl_flag_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'posted' and new.entry_type in ('journal','receipt','payment') and new.reversal_of is null
     and not public.posting_flag(new.company_id, new.entry_type, 'gl') then
    raise exception 'هالنوع من السندات ما بيترحّل للمحاسبة (من «الأدوات ← الترحيل»)';
  end if;
  return null;
end $$;
drop trigger if exists entry_gl_flag_check on public.journal_entries;
create trigger entry_gl_flag_check after update of status on public.journal_entries
  for each row execute function public.entry_gl_flag_check();
revoke execute on function public.entry_gl_flag_check() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- إلغاء الترحيل (صلاحية unpost)
-- ---------------------------------------------------------------------
create or replace function public.unpost_check_entry(p_entry uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries;
begin
  if p_entry is null then return; end if;
  select * into e from public.journal_entries where id = p_entry;
  if e.id is null then return; end if;
  if e.status = 'reversed' or e.reversed_by is not null then raise exception 'القيد انعكس من قبل، ما بينلغى ترحيله'; end if;
  if exists (select 1 from public.fiscal_years where id = e.fiscal_year_id and is_closed) then raise exception 'السنة المالية مغلقة'; end if;
  if exists (select 1 from public.bank_cleared c join public.journal_lines l on l.id = c.line_id where l.entry_id = p_entry) then
    raise exception 'في سطور من القيد معلّمة بالتسوية البنكية، شيل التعليم أول';
  end if;
  if exists (select 1 from public.cheque_events where entry_id = p_entry) then
    raise exception 'القيد مربوط بشيك بمحفظة الشيكات، ما بينلغى ترحيله';
  end if;
end $$;
revoke execute on function public.unpost_check_entry(uuid) from public, anon, authenticated;

create or replace function public.unpost_entry(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries;
begin
  select * into e from public.journal_entries where id = p_id for update;
  if e.id is null then raise exception 'القيد غير موجود'; end if;
  if e.entry_type not in ('journal','receipt','payment') then raise exception 'هالقيد بينعمل من شاشته (فاتورة، شيك، رواتب…)، ألغِ ترحيله من هناك'; end if;
  if not public.can(e.company_id, public.entry_screen(e.entry_type), 'unpost') then raise exception 'ما عندك صلاحية إلغاء الترحيل'; end if;
  if e.status <> 'posted' then raise exception 'القيد مش مرحّل'; end if;
  if e.reversal_of is not null then raise exception 'هاد قيد عكسي، ما بينلغى ترحيله'; end if;
  perform public.unpost_check_entry(p_id);
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set status = 'draft', posted_by = null, posted_at = null where id = p_id;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), e.company_id, 'إلغاء ترحيل', public.entry_screen(e.entry_type), p_id::text, jsonb_build_object('no', coalesce(e.doc_code, e.entry_no::text)));
end $$;

create or replace function public.unpost_invoice(p_id uuid, p_what text) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices;
begin
  select * into i from public.invoices where id = p_id for update;
  if i.id is null then raise exception 'الفاتورة غير موجودة'; end if;
  if not public.can(i.company_id, public.invoice_screen(i.inv_type), 'unpost') then raise exception 'ما عندك صلاحية إلغاء الترحيل'; end if;
  if i.status = 'cancelled' then raise exception 'الفاتورة ملغاة، ما بينلغى ترحيلها'; end if;
  if exists (select 1 from public.fiscal_years where id = i.fiscal_year_id and is_closed) then raise exception 'السنة المالية مغلقة'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  if p_what = 'gl' then
    if i.status <> 'posted' then raise exception 'الفاتورة مش مرحّلة للمحاسبة'; end if;
    if exists (select 1 from public.invoices r where r.original_invoice_id = p_id and r.status = 'posted') then
      raise exception 'في مرتجع مرحّل على هالفاتورة، ألغِ ترحيله أول';
    end if;
    if exists (select 1 from public.journal_entries where id = i.entry_id and (company_id <> i.company_id or entry_type <> 'invoice'))
       or exists (select 1 from public.journal_entries where id = i.cogs_entry_id and (company_id <> i.company_id or entry_type <> 'stock')) then
      raise exception 'قيد الفاتورة مش صحيح';
    end if;
    perform public.unpost_check_entry(i.entry_id);
    perform public.unpost_check_entry(i.cogs_entry_id);
    delete from public.journal_entries where id in (i.entry_id, i.cogs_entry_id);
    update public.invoices set status = 'draft', entry_id = null, cogs_entry_id = null, cogs_in_entry = false, posted_at = null where id = p_id;
  elsif p_what = 'stock' then
    if not i.stock_posted then raise exception 'الفاتورة مش مرحّلة للمخزون'; end if;
    if i.cogs_in_entry and i.status = 'posted' then
      raise exception 'كلفة البضاعة لهالفاتورة جوّا قيدها المحاسبي: ألغِ ترحيل المحاسبة أول';
    end if;
    if exists (select 1 from public.invoices r where r.original_invoice_id = p_id and r.stock_posted and r.status <> 'cancelled') then
      raise exception 'في مرتجع مرحّل للمخزون على هالفاتورة، ألغِ ترحيله أول';
    end if;
    if exists (select 1 from public.journal_entries where id = i.cogs_entry_id and (company_id <> i.company_id or entry_type <> 'stock')) then
      raise exception 'قيد الكلفة مش صحيح';
    end if;
    perform public.unpost_check_entry(i.cogs_entry_id);
    delete from public.journal_entries where id = i.cogs_entry_id;
    delete from public.stock_moves where source_type = 'invoice' and source_id = p_id;
    update public.invoices set stock_posted = false, stock_posted_at = null, cogs_entry_id = null, cogs_in_entry = false where id = p_id;
  else
    raise exception 'نوع الإلغاء غلط';
  end if;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), i.company_id, case when p_what = 'gl' then 'إلغاء ترحيل محاسبة' else 'إلغاء ترحيل مخزون' end,
          public.invoice_screen(i.inv_type), p_id::text, jsonb_build_object('no', coalesce(i.doc_code, i.inv_no::text)));
end $$;

create or replace function public.unpost_stock_doc(p_id uuid, p_what text) returns void
language plpgsql security definer set search_path = public as $$
declare d public.stock_docs;
begin
  select * into d from public.stock_docs where id = p_id for update;
  if d.id is null then raise exception 'السند غير موجود'; end if;
  if not public.can(d.company_id, 'inventory', 'unpost') then raise exception 'ما عندك صلاحية إلغاء الترحيل'; end if;
  if exists (select 1 from public.fiscal_years where company_id = d.company_id and d.doc_date between start_date and end_date and is_closed) then
    raise exception 'السنة المالية مغلقة';
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  if p_what = 'gl' then
    if d.entry_id is null then raise exception 'السند مش مرحّل للمحاسبة'; end if;
    if d.status <> 'posted' or not exists (select 1 from public.journal_entries where id = d.entry_id and company_id = d.company_id and entry_type = 'stock') then
      raise exception 'قيد السند مش صحيح';
    end if;
    perform public.unpost_check_entry(d.entry_id);
    delete from public.journal_entries where id = d.entry_id;
    update public.stock_docs set entry_id = null where id = p_id;
  elsif p_what = 'stock' then
    if d.status <> 'posted' then raise exception 'السند مش مرحّل للمخزون'; end if;
    if d.entry_id is not null then raise exception 'السند مرحّل للمحاسبة: ألغِ ترحيل المحاسبة أول'; end if;
    delete from public.stock_moves where source_type = 'stock_doc' and source_id = p_id;
    update public.stock_docs set status = 'draft' where id = p_id;
  else
    raise exception 'نوع الإلغاء غلط';
  end if;
  perform set_config('sumou.internal', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, case when p_what = 'gl' then 'إلغاء ترحيل محاسبة' else 'إلغاء ترحيل مخزون' end,
          'inventory', p_id::text, jsonb_build_object('no', coalesce(d.doc_code, d.doc_no::text)));
end $$;

revoke execute on function public.unpost_entry(uuid), public.unpost_invoice(uuid, text), public.unpost_stock_doc(uuid, text) from public, anon;
grant execute on function public.unpost_entry(uuid), public.unpost_invoice(uuid, text), public.unpost_stock_doc(uuid, text) to authenticated;

-- ما بتنقفل السنة وفيها فواتير مرحّلة للمحاسبة ومش للمخزون (أو العكس)، أو سندات مخزون ناقصها قيد بالجرد المستمر
create or replace function public.fy_close_posting_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int; m int;
begin
  if new.is_closed and not old.is_closed then
    select count(*) into n from public.invoices i where i.fiscal_year_id = new.id and i.status <> 'cancelled'
      and ((i.status = 'posted' and not i.stock_posted and public.posting_flag(i.company_id, i.inv_type, 'stock')
            and exists (select 1 from public.invoice_lines l join public.items it on it.id = l.item_id where l.invoice_id = i.id and it.item_type = 'goods' and it.track_stock))
        or (i.stock_posted and i.status = 'draft'));
    select count(*) into m from public.stock_docs d join public.company_settings st on st.company_id = d.company_id
      where d.company_id = new.company_id and d.doc_date between new.start_date and new.end_date and d.doc_type <> 'transfer'
        and d.status = 'posted' and d.entry_id is null and st.perpetual_inventory and public.posting_flag(d.company_id, 'stock_' || d.doc_type, 'gl');
    if n > 0 or m > 0 then
      raise exception 'في % فاتورة و% سند مخزون مرحّلين ترحيل ناقص (محاسبة بدون مخزون أو العكس). كمّل ترحيلهم من «الأدوات ← الترحيل» قبل إغلاق السنة', n, m;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists fy_close_posting_check on public.fiscal_years;
create trigger fy_close_posting_check before update of is_closed on public.fiscal_years
  for each row execute function public.fy_close_posting_check();
revoke execute on function public.fy_close_posting_check() from public, anon, authenticated;


-- #################### 19_audit.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 19: سجل التتبع
--  • كل سند وبطاقة: مين أدخله ومتى، ومين آخر واحد عدّل عليه ومتى (created_by/at، updated_by/at)
--  • كل إضافة وتعديل وحذف وترحيل بينسجّل لحاله بسجل النشاط من قاعدة البيانات (ما بيعتمد على الواجهة)
--  • doc_history(): سجل التتبع لسند واحد بأسماء المستخدمين
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array['journal_entries','invoices','stock_docs','parties','items','accounts','cheques','warehouses',
                           'employees','fixed_assets','payroll_runs','item_categories','party_categories','cost_centers',
                           'fiscal_years','companies','obligations','bank_recons','recurring_entries'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('alter table public.%I add column if not exists created_by uuid default auth.uid()', t);
    execute format('alter table public.%I add column if not exists created_at timestamptz default now()', t);
    execute format('alter table public.%I add column if not exists updated_by uuid', t);
    execute format('alter table public.%I add column if not exists updated_at timestamptz', t);
  end loop;
end $$;

-- ختم المستخدم والوقت (اسمها ac_ عشان تشتغل بعد aa_ و ab_ وقبل باقي الـ triggers)
create or replace function public.ac_audit_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_internal() then new.created_by := coalesce(auth.uid(), new.created_by); new.created_at := now(); end if;
    new.created_by := coalesce(new.created_by, auth.uid()); new.created_at := coalesce(new.created_at, now());
    if not public.is_internal() then new.updated_by := null; end if;
  else
    new.created_by := old.created_by; new.created_at := old.created_at;
    if auth.uid() is not null then new.updated_by := auth.uid(); new.updated_at := now();
    else new.updated_by := old.updated_by; new.updated_at := old.updated_at; end if;
  end if;
  return new;
end $$;
revoke execute on function public.ac_audit_stamp() from public, anon, authenticated;

-- تسجيل كل حركة بسجل النشاط
create or replace function public.zy_audit_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; r jsonb; ch text[]; act text; cid uuid; label text;
begin
  if tg_op = 'DELETE' then r := to_jsonb(old); else r := to_jsonb(new); end if;
  if tg_op = 'UPDATE' then
    o := to_jsonb(old); n := to_jsonb(new);
    select array_agg(k order by k) into ch from jsonb_object_keys(n) k
      where k not in ('updated_at','updated_by','seq_key','posting_ready') and (o -> k) is distinct from (n -> k);
    if ch is null then return null; end if;
    act := case
      when (o ->> 'status') is distinct from (n ->> 'status') then
        case n ->> 'status' when 'posted' then 'ترحيل' when 'draft' then 'إلغاء ترحيل' when 'cancelled' then 'إلغاء' when 'reversed' then 'قيد عكسي' else 'تعديل' end
      when (o ->> 'stock_posted') is distinct from (n ->> 'stock_posted') then
        case when (n ->> 'stock_posted')::boolean then 'ترحيل للمخزون' else 'إلغاء ترحيل مخزون' end
      when (o ->> 'entry_id') is distinct from (n ->> 'entry_id') and tg_table_name = 'stock_docs' then
        case when n ->> 'entry_id' is null then 'إلغاء ترحيل محاسبة' else 'ترحيل للمحاسبة' end
      else 'تعديل' end;
  else
    act := case tg_op when 'INSERT' then 'إضافة' else 'حذف' end;
  end if;
  if tg_op = 'INSERT' and public.is_internal() then return null; end if;   -- إدخال من النظام (استرجاع، قيود الترحيل)
  cid := case when tg_table_name = 'companies' then (r ->> 'id')::uuid else (r ->> 'company_id')::uuid end;
  if tg_op = 'DELETE' and not exists (select 1 from public.companies where id = cid) then cid := null; end if;  -- حذف شركة كاملة
  label := coalesce(r ->> 'doc_code', r ->> 'code', r ->> 'name', r ->> 'period', r ->> 'title', r ->> 'cheque_no');
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, act, tg_table_name, r ->> 'id',
          jsonb_strip_nulls(jsonb_build_object('no', label, 'changes', to_jsonb(ch), 'auto', true)));
  return null;
end $$;
revoke execute on function public.zy_audit_log() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['journal_entries','invoices','stock_docs','parties','items','accounts','cheques','warehouses',
                           'employees','fixed_assets','payroll_runs','item_categories','party_categories','cost_centers',
                           'fiscal_years','companies','obligations','bank_recons','recurring_entries'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop trigger if exists ac_audit_stamp on public.%I', t);
    execute format('create trigger ac_audit_stamp before insert or update on public.%I for each row execute function public.ac_audit_stamp()', t);
    execute format('drop trigger if exists zy_audit_log on public.%I', t);
    execute format('create trigger zy_audit_log after insert or update or delete on public.%I for each row execute function public.zy_audit_log()', t);
  end loop;
end $$;
create index if not exists activity_log_entity_idx on public.activity_log (entity_id);
create index if not exists activity_log_user_idx on public.activity_log (user_id, created_at desc);

-- أسماء المستخدمين (للعرض بس)
create or replace function public.user_names(p_ids uuid[]) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1))
  from public.profiles p where public.is_active_user() and p.id = any(p_ids);
$$;
revoke execute on function public.user_names(uuid[]) from public, anon;
grant execute on function public.user_names(uuid[]) to authenticated;

-- سجل التتبع لسند/بطاقة واحدة (لمين إله وصول على شركتها)
create or replace function public.doc_history(p_id uuid)
returns table (created_at timestamptz, user_name text, action text, entity text, details jsonb)
language sql stable security definer set search_path = public as $$
  select l.created_at, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1)), l.action, l.entity, l.details
  from public.activity_log l left join public.profiles p on p.id = l.user_id
  where l.entity_id = p_id::text and l.company_id is not null and public.has_company(l.company_id)
  order by l.created_at desc, l.id desc limit 500;
$$;
revoke execute on function public.doc_history(uuid) from public, anon;
grant execute on function public.doc_history(uuid) to authenticated;


-- #################### 20_expense_cards.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 20: بطاقات المصاريف (أستاذ مساعد للمصاريف مثل العملاء)
--  كل بطاقة مصروف (كهرباء، إيجار، صيانة سيارات…) مربوطة على حساب مصاريف،
--  وبتنختار بسطور السندات مثل العميل/المورد، وإلها كشف حساب وأستاذ مساعد.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- نوع الطرف صار: عميل، مورد، مصروف
do $$
declare c record;
begin
  for c in select con.conname, rel.relname from pg_constraint con join pg_class rel on rel.oid = con.conrelid
           join pg_namespace n on n.oid = rel.relnamespace
           where n.nspname = 'public' and rel.relname in ('parties','party_categories') and con.contype = 'c'
             and pg_get_constraintdef(con.oid) like '%party_type%' and pg_get_constraintdef(con.oid) not like '%expense%' loop
    execute format('alter table public.%I drop constraint %I', c.relname, c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'parties_party_type_chk') then
    alter table public.parties add constraint parties_party_type_chk check (party_type in ('customer','supplier','expense'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'party_categories_party_type_chk') then
    alter table public.party_categories add constraint party_categories_party_type_chk check (party_type in ('customer','supplier','expense'));
  end if;
end $$;

-- الشاشة (للصلاحيات) لكل نوع طرف
create or replace function public.party_screen(p_type text) returns text
language sql immutable as $$
  select case p_type when 'customer' then 'customers' when 'supplier' then 'suppliers' else 'expense_cards' end
$$;

-- رمز تلقائي: C للعملاء، S للموردين، E للمصاريف. وبطاقة المصروف لازم على حساب مصاريف
create or replace function public.parties_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.accounts; n int;
begin
  select * into a from public.accounts where id = new.account_id;
  if a.id is null or a.company_id <> new.company_id then raise exception 'الحساب مش لهالشركة'; end if;
  if a.is_group then raise exception 'حساب الطرف لازم يكون حساب فرعي'; end if;
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.party_type := old.party_type; end if;
  if new.party_type = 'expense' and a.category <> 'expenses' then raise exception 'بطاقة المصروف لازم تكون على حساب من المصاريف'; end if;
  if tg_op = 'INSERT' and (new.code is null or new.code = '') then
    select coalesce(max(nullif(regexp_replace(code, '\D', '', 'g'), '')::int), 0) + 1 into n
      from public.parties where company_id = new.company_id and party_type = new.party_type;
    new.code := case new.party_type when 'customer' then 'C' when 'supplier' then 'S' else 'E' end || lpad(n::text, 4, '0');
  end if;
  return new;
end $$;

drop policy if exists parties_select on public.parties;
create policy parties_select on public.parties for select to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'view') or public.has_company(company_id));
drop policy if exists parties_insert on public.parties;
create policy parties_insert on public.parties for insert to authenticated
  with check (public.can(company_id, public.party_screen(party_type), 'add'));
drop policy if exists parties_update on public.parties;
create policy parties_update on public.parties for update to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'edit'))
  with check (public.can(company_id, public.party_screen(party_type), 'edit'));
drop policy if exists parties_delete on public.parties;
create policy parties_delete on public.parties for delete to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'delete'));

drop policy if exists pcat_insert on public.party_categories;
create policy pcat_insert on public.party_categories for insert to authenticated
  with check (public.can(company_id, public.party_screen(party_type), 'add'));
drop policy if exists pcat_update on public.party_categories;
create policy pcat_update on public.party_categories for update to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'edit'))
  with check (public.can(company_id, public.party_screen(party_type), 'edit'));
drop policy if exists pcat_delete on public.party_categories;
create policy pcat_delete on public.party_categories for delete to authenticated
  using (public.can(company_id, public.party_screen(party_type), 'delete'));


-- #################### 21_departments.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 21: الدوائر (فروع/أقسام الشركة على شكل شجرة)
--  الدائرة إما رئيسية (بيتفرّع منها) أو فرعية (بتنستعمل بالمستندات).
--  كل مستخدم إله دائرة افتراضية بكل شركة، والمستند بياخذها لحاله إذا ما انختارت.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.departments (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  code           text not null,
  name           text not null,
  name2          text,
  kind           text not null default 'sub' check (kind in ('main','sub')),
  parent_id      uuid references public.departments(id) on delete restrict deferrable initially deferred,
  level          int not null default 1,
  is_active      boolean not null default true,
  sales_tax_no   text,
  income_tax_no  text,
  national_no    text,
  currency       text,
  city           text,
  address        text,
  phone          text,
  mobile         text,
  email          text,
  warehouse_id   uuid references public.warehouses(id) on delete set null,
  cost_center_id uuid references public.cost_centers(id) on delete set null,
  notes          text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now(),
  updated_by     uuid,
  updated_at     timestamptz,
  unique (company_id, code)
);
create index if not exists departments_parent_idx on public.departments (parent_id);

create or replace function public.departments_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.departments; x uuid; n int := 0;
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  new.code := btrim(coalesce(new.code, ''));
  new.name := btrim(coalesce(new.name, ''));
  if new.code = '' then raise exception 'رمز الدائرة مطلوب'; end if;
  if new.name = '' then raise exception 'وصف الدائرة مطلوب'; end if;
  if new.parent_id is null then new.level := 1;
  else
    if new.parent_id = new.id then raise exception 'الدائرة ما بتكون أب لحالها'; end if;
    select * into p from public.departments where id = new.parent_id;
    if p.id is null or p.company_id <> new.company_id then raise exception 'الدائرة الرئيسية مش لهالشركة'; end if;
    if p.kind <> 'main' then raise exception 'الدائرة الأب لازم تكون رئيسية'; end if;
    -- منع الدوران
    x := p.parent_id;
    while x is not null loop
      if x = new.id then raise exception 'ما بصير الدائرة تكون تحت وحدة من فروعها'; end if;
      n := n + 1; if n > 50 then exit; end if;
      select parent_id into x from public.departments where id = x;
    end loop;
    new.level := p.level + 1;
  end if;
  if tg_op = 'UPDATE' and new.kind = 'sub' and old.kind = 'main'
     and exists (select 1 from public.departments where parent_id = new.id) then
    raise exception 'الدائرة إلها فروع، ما بتصير فرعية';
  end if;
  if new.warehouse_id is not null and not exists (select 1 from public.warehouses w where w.id = new.warehouse_id and w.company_id = new.company_id) then
    raise exception 'المستودع مش لهالشركة';
  end if;
  if new.cost_center_id is not null and not exists (select 1 from public.cost_centers c where c.id = new.cost_center_id and c.company_id = new.company_id) then
    raise exception 'مركز الكلفة مش لهالشركة';
  end if;
  return new;
end $$;
drop trigger if exists departments_before on public.departments;
create trigger departments_before before insert or update on public.departments
  for each row execute function public.departments_before();

-- لما يتغيّر مستوى الأب، الفروع بتتحدّث
create or replace function public.departments_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.level is distinct from old.level then
    update public.departments set level = new.level + 1 where parent_id = new.id;
  end if;
  -- دائرة انوقفت أو صارت رئيسية: بتنشال كافتراضية عن المستخدمين
  if (not new.is_active or new.kind <> 'sub') and (old.is_active and old.kind = 'sub') then
    update public.user_companies set department_id = null where department_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists departments_after on public.departments;
create trigger departments_after after update of level, is_active, kind on public.departments
  for each row execute function public.departments_after();

alter table public.departments enable row level security;
drop policy if exists dept_select on public.departments;
create policy dept_select on public.departments for select to authenticated using (public.has_company(company_id));
drop policy if exists dept_insert on public.departments;
create policy dept_insert on public.departments for insert to authenticated with check (public.can(company_id, 'departments', 'add'));
drop policy if exists dept_update on public.departments;
create policy dept_update on public.departments for update to authenticated
  using (public.can(company_id, 'departments', 'edit')) with check (public.can(company_id, 'departments', 'edit'));
drop policy if exists dept_delete on public.departments;
create policy dept_delete on public.departments for delete to authenticated using (public.can(company_id, 'departments', 'delete'));
grant select, insert, update, delete on public.departments to authenticated;

-- سجل التتبع
drop trigger if exists ac_audit_stamp on public.departments;
create trigger ac_audit_stamp before insert or update on public.departments for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.departments;
create trigger zy_audit_log after insert or update or delete on public.departments for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  دائرة المستخدم الافتراضية بكل شركة + «إخفاء الدوائر»
-- ---------------------------------------------------------------------
alter table public.user_companies add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.user_companies add column if not exists hide_departments boolean not null default false;

create or replace function public.user_companies_dept_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.department_id is not null and not exists (
       select 1 from public.departments d where d.id = new.department_id and d.company_id = new.company_id and d.kind = 'sub') then
    raise exception 'الدائرة لازم تكون فرعية ومن نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists user_companies_dept_check on public.user_companies;
create trigger user_companies_dept_check before insert or update of department_id, company_id on public.user_companies
  for each row execute function public.user_companies_dept_check();

create or replace function public.my_department(p_company uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select department_id from public.user_companies where user_id = auth.uid() and company_id = p_company
$$;
grant execute on function public.my_department(uuid) to authenticated;

-- ---------------------------------------------------------------------
--  الدائرة على المستندات: القيود، الفواتير، سندات المخزون
-- ---------------------------------------------------------------------
alter table public.journal_entries add column if not exists department_id uuid references public.departments(id) on delete restrict;
alter table public.invoices        add column if not exists department_id uuid references public.departments(id) on delete restrict;
alter table public.stock_docs      add column if not exists department_id uuid references public.departments(id) on delete restrict;
create index if not exists journal_entries_dept_idx on public.journal_entries (company_id, department_id);
create index if not exists invoices_dept_idx on public.invoices (company_id, department_id);

create or replace function public.ad_doc_department() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid; uc public.user_companies; def uuid;
begin
  if public.is_internal() then
    -- القيد العكسي بياخذ دائرة القيد الأصلي
    if tg_table_name = 'journal_entries' and tg_op = 'INSERT' and new.department_id is null then
      -- (to_jsonb عشان الدالة نفسها على الفواتير وسندات المخزون، وما فيهم reversal_of)
      if (to_jsonb(new) ->> 'reversal_of') is not null then
        select department_id into new.department_id from public.journal_entries where id = (to_jsonb(new) ->> 'reversal_of')::uuid;
      end if;
    end if;
    return new;
  end if;
  cid := case when tg_op = 'UPDATE' then old.company_id else new.company_id end;   -- الشركة ما بتتغيّر
  select * into uc from public.user_companies where user_id = auth.uid() and company_id = cid;
  def := uc.department_id;
  if def is not null and not exists (select 1 from public.departments d where d.id = def and d.company_id = cid and d.kind = 'sub' and d.is_active) then
    def := null;   -- الدائرة الافتراضية انوقفت: المستند بينحفظ بدون دائرة
  end if;
  -- «إخفاء الدوائر»: المستخدم ما بيختار، بتنحط دائرته
  if coalesce(uc.hide_departments, false) and not public.is_admin() then
    new.department_id := case when tg_op = 'UPDATE' then old.department_id else def end;
    return new;
  end if;
  if tg_op = 'INSERT' and new.department_id is null then new.department_id := def; end if;
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not exists (select 1 from public.departments d where d.id = new.department_id and d.company_id = cid
                       and d.kind = 'sub' and d.is_active) then
    raise exception 'الدائرة لازم تكون فرعية وفعّالة ومن نفس الشركة';
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['journal_entries','invoices','stock_docs'] loop
    execute format('drop trigger if exists ad_doc_department on public.%I', t);
    execute format('create trigger ad_doc_department before insert or update of department_id on public.%I for each row execute function public.ad_doc_department()', t);
  end loop;
end $$;

-- قيد الفاتورة وسند المخزون (من النظام) بياخذ دائرة المستند
create or replace function public.zx_entry_department_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := current_setting('sumou.internal', true); ids uuid[];
begin
  if new.department_id is null then return null; end if;
  if tg_table_name = 'invoices' then ids := array[new.entry_id, new.cogs_entry_id, new.cancel_entry_id];
  else ids := array[new.entry_id]; end if;
  if not exists (select 1 from public.journal_entries where id = any(ids) and department_id is distinct from new.department_id) then return null; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_entries set department_id = new.department_id
   where id = any(ids) and department_id is distinct from new.department_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
revoke execute on function public.zx_entry_department_sync() from public, anon, authenticated;
drop trigger if exists zx_entry_department_sync on public.invoices;
create trigger zx_entry_department_sync after insert or update of entry_id, cogs_entry_id, cancel_entry_id, department_id on public.invoices
  for each row execute function public.zx_entry_department_sync();
drop trigger if exists zx_entry_department_sync on public.stock_docs;
create trigger zx_entry_department_sync after insert or update of entry_id, department_id on public.stock_docs
  for each row execute function public.zx_entry_department_sync();

-- النسخ الاحتياطي: الدوائر قبل المستندات
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'party_categories',   'company_id = $1', 'party_type, code'),
   (8,  'parties',            'company_id = $1', 'code'),
   (9,  'item_categories',    'company_id = $1', 'code'),
   (10, 'items',              'company_id = $1', 'code'),
   (11, 'warehouses',         'company_id = $1', 'code'),
   (12, 'departments',        'company_id = $1', 'level, code'),
   (13, 'journal_entries',    'company_id = $1', 'created_at'),
   (14, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (15, 'invoices',           'company_id = $1', 'created_at'),
   (16, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (17, 'cheques',            'company_id = $1', 'created_at'),
   (18, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (19, 'stock_docs',         'company_id = $1', 'created_at'),
   (20, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (21, 'stock_moves',        'company_id = $1', 'created_at'),
   (22, 'obligations',        'company_id = $1', 'due_date'),
   (23, 'recurring_entries',  'company_id = $1', 'created_at'),
   (24, 'employees',          'company_id = $1', 'code'),
   (25, 'payroll_runs',       'company_id = $1', 'period'),
   (26, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (27, 'fixed_assets',       'company_id = $1', 'code'),
   (28, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (29, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (30, 'bank_recons',        'company_id = $1', 'created_at'),
   (31, 'bank_cleared',       'company_id = $1', 'line_id'),
   (32, 'attachments',        'company_id = $1', 'created_at');
$$;


-- #################### 22_fiscal_periods.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 22: فترات السنة المالية (12 شهر لكل سنة)
--  كل فترة بتنقفل للمالية أو للمخزون أو الاثنين: ما بينرحّل عليها ولا بينلغى ترحيل.
--  القفل بصلاحية «تعديل» على السنوات المالية، والفتح من جديد بصلاحية «إلغاء ترحيل» (أو المدير).
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.fiscal_periods (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  fiscal_year_id uuid not null references public.fiscal_years(id) on delete cascade,
  code           text not null,          -- 01.26
  name           text,
  start_date     date not null,
  end_date       date not null,
  gl_locked      boolean not null default false,   -- مقفولة للمالية
  stock_locked   boolean not null default false,   -- مقفولة للمخزون
  locked_by      uuid,
  locked_at      timestamptz,
  created_at     timestamptz default now(),
  unique (fiscal_year_id, code),
  check (end_date >= start_date)
);
create index if not exists fiscal_periods_lookup on public.fiscal_periods (company_id, start_date, end_date);

-- توليد الفترات الشهرية لسنة (ما بيكرر الموجود)
create or replace function public.ensure_fiscal_periods(p_fy uuid) returns int
language plpgsql security definer set search_path = public as $$
declare fy public.fiscal_years; d date; e date; n int := 0; prev text := current_setting('sumou.internal', true);
begin
  select * into fy from public.fiscal_years where id = p_fy;
  if fy.id is null then return 0; end if;
  if not public.is_internal() and not public.has_company(fy.company_id) then raise exception 'ما إلك صلاحية على هالشركة'; end if;
  if exists (select 1 from public.fiscal_periods where fiscal_year_id = p_fy) then return 0; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  d := fy.start_date;
  while d <= fy.end_date loop
    e := least((date_trunc('month', d) + interval '1 month - 1 day')::date, fy.end_date);
    insert into public.fiscal_periods (company_id, fiscal_year_id, code, name, start_date, end_date)
    values (fy.company_id, fy.id, to_char(d, 'MM.YY'), to_char(d, 'MM.YY'), d, e)
    on conflict do nothing;
    n := n + 1; d := e + 1;
  end loop;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return n;
end $$;
grant execute on function public.ensure_fiscal_periods(uuid) to authenticated;

-- سنة جديدة = فترات جديدة (الاسترجاع بيرجّع فتراته من النسخة)
create or replace function public.fiscal_years_periods() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := current_setting('sumou.internal', true);
begin
  if public.is_internal() then return null; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  perform public.ensure_fiscal_periods(new.id);
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
drop trigger if exists fiscal_years_periods on public.fiscal_years;
create trigger fiscal_years_periods after insert on public.fiscal_years
  for each row execute function public.fiscal_years_periods();

-- السنوات الموجودة
do $$ declare r record; begin
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select id from public.fiscal_years loop perform public.ensure_fiscal_periods(r.id); end loop;
  perform set_config('sumou.internal', '', true);
end $$;

-- التعديل: بس القفل والاسم. القفل بصلاحية تعديل، والفتح بصلاحية إلغاء الترحيل
create or replace function public.fiscal_periods_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then raise exception 'الفترات بتتولّد لحالها مع السنة المالية'; end if;
  new.company_id := old.company_id; new.fiscal_year_id := old.fiscal_year_id; new.code := old.code;
  new.start_date := old.start_date; new.end_date := old.end_date;
  if (old.gl_locked and not new.gl_locked) or (old.stock_locked and not new.stock_locked) then
    if not (public.is_admin() or public.can(old.company_id, 'fiscal_years', 'unpost')) then
      raise exception 'فتح الفترة المقفولة بدها صلاحية «إلغاء ترحيل» على السنوات المالية';
    end if;
  end if;
  if (new.gl_locked, new.stock_locked) is distinct from (old.gl_locked, old.stock_locked) then
    new.locked_by := auth.uid(); new.locked_at := now();
  else new.locked_by := old.locked_by; new.locked_at := old.locked_at; end if;
  return new;
end $$;
drop trigger if exists fiscal_periods_before on public.fiscal_periods;
create trigger fiscal_periods_before before insert or update on public.fiscal_periods
  for each row execute function public.fiscal_periods_before();

alter table public.fiscal_periods enable row level security;
drop policy if exists fp_select on public.fiscal_periods;
create policy fp_select on public.fiscal_periods for select to authenticated using (public.has_company(company_id));
drop policy if exists fp_update on public.fiscal_periods;
create policy fp_update on public.fiscal_periods for update to authenticated
  using (public.can(company_id, 'fiscal_years', 'edit')) with check (public.can(company_id, 'fiscal_years', 'edit'));
grant select, update on public.fiscal_periods to authenticated;

-- هل التاريخ بفترة مقفولة؟ kind = 'gl' أو 'stock'
create or replace function public.period_locked_(p_company uuid, p_date date, p_kind text) returns text
language sql stable security definer set search_path = public as $$
  select code from public.fiscal_periods
   where company_id = p_company and p_date between start_date and end_date
     and case when p_kind = 'gl' then gl_locked else stock_locked end
   limit 1
$$;
revoke execute on function public.period_locked_(uuid, date, text) from public, anon, authenticated;
create or replace function public.period_locked(p_company uuid, p_date date, p_kind text) returns text
language sql stable security definer set search_path = public as $$
  select case when public.has_company(p_company) then public.period_locked_(p_company, p_date, p_kind) end
$$;
grant execute on function public.period_locked(uuid, date, text) to authenticated;

-- المالية: ترحيل قيد أو إلغاء ترحيله أو حذفه بفترة مقفولة ممنوع (قيد الإقفال من النظام مستثنى)
create or replace function public.ae_entry_period_lock() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text;
begin
  if tg_op = 'DELETE' then
    if old.status = 'posted' and old.entry_type <> 'closing' and exists (select 1 from public.companies where id = old.company_id) then
      p := public.period_locked_(old.company_id, old.entry_date, 'gl');
      if p is not null then raise exception 'الفترة % مقفولة للمالية، ما بينلغى الترحيل فيها', p; end if;
    end if;
    return old;
  end if;
  if new.entry_type = 'closing' then return new; end if;
  if (tg_op = 'INSERT' and new.status = 'posted')
     or (tg_op = 'UPDATE' and new.status = 'posted' and old.status = 'draft') then
    p := public.period_locked_(new.company_id, new.entry_date, 'gl');
    if p is not null then raise exception 'الفترة % مقفولة للمالية، ما بينرحّل عليها', p; end if;
  elsif tg_op = 'UPDATE' and old.status = 'posted' and new.status = 'draft' then
    p := public.period_locked_(old.company_id, old.entry_date, 'gl');
    if p is not null then raise exception 'الفترة % مقفولة للمالية، ما بينلغى الترحيل فيها', p; end if;
  end if;
  return new;
end $$;
drop trigger if exists ae_entry_period_lock on public.journal_entries;
create trigger ae_entry_period_lock before insert or update of status or delete on public.journal_entries
  for each row execute function public.ae_entry_period_lock();

-- المخزون: حركة جديدة أو حذف حركة بفترة مقفولة ممنوع
create or replace function public.ae_stock_period_lock() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text; r public.stock_moves;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if tg_op = 'UPDATE' and (new.qty, new.unit_cost, new.move_date, new.item_id, new.warehouse_id, new.company_id)
                       is not distinct from (old.qty, old.unit_cost, old.move_date, old.item_id, old.warehouse_id, old.company_id) then
    return new;   -- تعديل ما بيغيّر الحركة (مثل تعبئة أعمدة)
  end if;
  if tg_op = 'DELETE' and not exists (select 1 from public.companies where id = r.company_id) then return old; end if;  -- حذف الشركة كاملة
  p := public.period_locked_(r.company_id, r.move_date, 'stock');
  if p is not null then raise exception 'الفترة % مقفولة للمخزون', p; end if;
  if tg_op = 'UPDATE' and old.move_date <> new.move_date then
    p := public.period_locked_(old.company_id, old.move_date, 'stock');
    if p is not null then raise exception 'الفترة % مقفولة للمخزون', p; end if;
  end if;
  return r;
end $$;
drop trigger if exists ae_stock_period_lock on public.stock_moves;
create trigger ae_stock_period_lock before insert or update or delete on public.stock_moves
  for each row execute function public.ae_stock_period_lock();

-- النسخ الاحتياطي: الفترات آخر شي (بعد المستندات، عشان القفل ما يمنع الاسترجاع)
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'party_categories',   'company_id = $1', 'party_type, code'),
   (8,  'parties',            'company_id = $1', 'code'),
   (9,  'item_categories',    'company_id = $1', 'code'),
   (10, 'items',              'company_id = $1', 'code'),
   (11, 'warehouses',         'company_id = $1', 'code'),
   (12, 'departments',        'company_id = $1', 'level, code'),
   (13, 'journal_entries',    'company_id = $1', 'created_at'),
   (14, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (15, 'invoices',           'company_id = $1', 'created_at'),
   (16, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (17, 'cheques',            'company_id = $1', 'created_at'),
   (18, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (19, 'stock_docs',         'company_id = $1', 'created_at'),
   (20, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (21, 'stock_moves',        'company_id = $1', 'created_at'),
   (22, 'obligations',        'company_id = $1', 'due_date'),
   (23, 'recurring_entries',  'company_id = $1', 'created_at'),
   (24, 'employees',          'company_id = $1', 'code'),
   (25, 'payroll_runs',       'company_id = $1', 'period'),
   (26, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (27, 'fixed_assets',       'company_id = $1', 'code'),
   (28, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (29, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (30, 'bank_recons',        'company_id = $1', 'created_at'),
   (31, 'bank_cleared',       'company_id = $1', 'line_id'),
   (32, 'attachments',        'company_id = $1', 'created_at'),
   (33, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;

-- تغيير تواريخ السنة: الفترات بتتولّد من جديد إذا ما في ولا وحدة مقفولة
create or replace function public.fiscal_years_redates() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := current_setting('sumou.internal', true);
begin
  if (new.start_date, new.end_date) is not distinct from (old.start_date, old.end_date) then return null; end if;
  if exists (select 1 from public.fiscal_periods where fiscal_year_id = new.id and (gl_locked or stock_locked)) then
    raise exception 'في فترات مقفولة بهالسنة، افتحها أول قبل ما تغيّر التواريخ';
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  delete from public.fiscal_periods where fiscal_year_id = new.id;
  perform public.ensure_fiscal_periods(new.id);
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
drop trigger if exists fiscal_years_redates on public.fiscal_years;
create trigger fiscal_years_redates after update of start_date, end_date on public.fiscal_years
  for each row execute function public.fiscal_years_redates();


-- #################### 23_lookups.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 23: قوائم الإعداد (مثل «إعداد» بستاليون)
--  وسائل الدفع (مربوطة على حساب صندوق/بنك)، البنوك، فروع البنوك، الدول، المناطق، أنواع الأوراق التجارية.
--  القوائم بتعبّي اختيارات جاهزة بالشاشات (البنك بالشيك، المدينة بالعميل، وسيلة الدفع بالفاتورة والسند).
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

create table if not exists public.lookups (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  kind       text not null check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type')),
  code       text not null,
  name       text not null,
  name2      text,
  parent_id  uuid references public.lookups(id) on delete restrict deferrable initially deferred,
  account_id uuid references public.accounts(id) on delete set null,   -- لوسائل الدفع
  is_active  boolean not null default true,
  notes      text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now(),
  updated_by uuid,
  updated_at timestamptz,
  unique (company_id, kind, code)
);
create index if not exists lookups_kind_idx on public.lookups (company_id, kind, code);

create or replace function public.lookups_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.lookups; a public.accounts;
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.kind := old.kind; end if;
  new.code := btrim(coalesce(new.code, '')); new.name := btrim(coalesce(new.name, ''));
  if new.code = '' then raise exception 'الرمز مطلوب'; end if;
  if new.name = '' then raise exception 'الاسم مطلوب'; end if;
  if new.parent_id is not null then
    select * into p from public.lookups where id = new.parent_id;
    if p.id is null or p.company_id <> new.company_id
       or (new.kind = 'bank_branch' and p.kind <> 'bank') or (new.kind = 'region' and p.kind <> 'country')
       or new.kind not in ('bank_branch', 'region') then
      raise exception 'الأب مش مناسب (فرع البنك تحت بنك، والمنطقة تحت دولة)';
    end if;
  end if;
  if new.account_id is not null then
    select * into a from public.accounts where id = new.account_id;
    if a.id is null or a.company_id <> new.company_id or a.is_group then raise exception 'الحساب لازم يكون فرعي ومن نفس الشركة'; end if;
    if new.kind <> 'payment_method' then new.account_id := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists lookups_before on public.lookups;
create trigger lookups_before before insert or update on public.lookups
  for each row execute function public.lookups_before();

alter table public.lookups enable row level security;
drop policy if exists lk_select on public.lookups;
create policy lk_select on public.lookups for select to authenticated using (public.has_company(company_id));
drop policy if exists lk_insert on public.lookups;
create policy lk_insert on public.lookups for insert to authenticated with check (public.can(company_id, 'lookups', 'add'));
drop policy if exists lk_update on public.lookups;
create policy lk_update on public.lookups for update to authenticated
  using (public.can(company_id, 'lookups', 'edit')) with check (public.can(company_id, 'lookups', 'edit'));
drop policy if exists lk_delete on public.lookups;
create policy lk_delete on public.lookups for delete to authenticated using (public.can(company_id, 'lookups', 'delete'));
grant select, insert, update, delete on public.lookups to authenticated;

drop trigger if exists ac_audit_stamp on public.lookups;
create trigger ac_audit_stamp before insert or update on public.lookups for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.lookups;
create trigger zy_audit_log after insert or update or delete on public.lookups for each row execute function public.zy_audit_log();

-- النسخ الاحتياطي
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'party_categories',   'company_id = $1', 'party_type, code'),
   (8,  'parties',            'company_id = $1', 'code'),
   (9,  'item_categories',    'company_id = $1', 'code'),
   (10, 'items',              'company_id = $1', 'code'),
   (11, 'warehouses',         'company_id = $1', 'code'),
   (12, 'departments',        'company_id = $1', 'level, code'),
   (13, 'lookups',            'company_id = $1', 'parent_id nulls first, kind, code'),
   (14, 'journal_entries',    'company_id = $1', 'created_at'),
   (15, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (16, 'invoices',           'company_id = $1', 'created_at'),
   (17, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (18, 'cheques',            'company_id = $1', 'created_at'),
   (19, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (20, 'stock_docs',         'company_id = $1', 'created_at'),
   (21, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (22, 'stock_moves',        'company_id = $1', 'created_at'),
   (23, 'obligations',        'company_id = $1', 'due_date'),
   (24, 'recurring_entries',  'company_id = $1', 'created_at'),
   (25, 'employees',          'company_id = $1', 'code'),
   (26, 'payroll_runs',       'company_id = $1', 'period'),
   (27, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (28, 'fixed_assets',       'company_id = $1', 'code'),
   (29, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (30, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (31, 'bank_recons',        'company_id = $1', 'created_at'),
   (32, 'bank_cleared',       'company_id = $1', 'line_id'),
   (33, 'attachments',        'company_id = $1', 'created_at'),
   (34, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;


-- #################### 24_sales_reps.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 24: مندوبي المبيعات
--  المندوب بيتعرّف بقوائم الإعداد (kind = sales_rep) مع نسبة عمولة،
--  وبينربط على العميل (افتراضي) وعلى الفاتورة. تقرير مبيعات وتحصيلات المندوبين من الواجهة.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.lookups add column if not exists rate numeric(9,3);   -- نسبة العمولة % للمندوب
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%sales_rep%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname in ('lookups_kind_chk', 'lookups_kind_chk2')) then
    alter table public.lookups add constraint lookups_kind_chk
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep'));
  end if;
end $$;

alter table public.parties  add column if not exists sales_rep_id uuid references public.lookups(id) on delete set null;
alter table public.invoices add column if not exists sales_rep_id uuid references public.lookups(id) on delete restrict;
create index if not exists invoices_rep_idx on public.invoices (company_id, sales_rep_id);

create or replace function public.ad_sales_rep_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if public.is_internal() then return new; end if;
  cid := case when tg_op = 'UPDATE' then old.company_id else new.company_id end;
  if new.sales_rep_id is not null and (tg_op = 'INSERT' or new.sales_rep_id is distinct from old.sales_rep_id)
     and not exists (select 1 from public.lookups l where l.id = new.sales_rep_id and l.company_id = cid and l.kind = 'sales_rep' and l.is_active) then
    raise exception 'المندوب مش موجود أو مش فعّال بهالشركة';
  end if;
  return new;
end $$;
-- الفاتورة الجديدة بتاخذ مندوب العميل إذا ما انختار (قبل الفحص)
create or replace function public.ad_invoice_rep_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_internal() and new.sales_rep_id is null and new.party_id is not null then
    select p.sales_rep_id into new.sales_rep_id from public.parties p
     where p.id = new.party_id and p.company_id = new.company_id and p.party_type = 'customer';
  end if;
  return new;
end $$;
drop trigger if exists ad_invoice_rep_default on public.invoices;
create trigger ad_invoice_rep_default before insert on public.invoices
  for each row execute function public.ad_invoice_rep_default();
drop trigger if exists ad_sales_rep_check on public.invoices;
create trigger ad_sales_rep_check before insert or update of sales_rep_id on public.invoices
  for each row execute function public.ad_sales_rep_check();
drop trigger if exists ad_sales_rep_check on public.parties;
create trigger ad_sales_rep_check before insert or update of sales_rep_id on public.parties
  for each row execute function public.ad_sales_rep_check();


-- #################### 25_orders_marketing.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 25: طلبات المبيعات والتزويد، العروض الترويجية، بطاقات الولاء، الحقول الإضافية
--  الطلب ما بيأثّر على الحسابات ولا المخزون؛ بيتحوّل لفاتورة (مسودة) وبينربط عليها.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- ---------------------------------------------------------------------
--  الطلبات (طلب مبيعات / عرض سعر، طلب تزويد / أمر شراء)
-- ---------------------------------------------------------------------
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  order_type     text not null check (order_type in ('sales_order','purchase_order')),
  order_no       int check (order_no > 0),
  order_date     date not null default current_date,
  valid_until    date,
  party_id       uuid references public.parties(id) on delete restrict,
  party_name     text,
  reference      text,
  notes          text,
  sales_rep_id   uuid references public.lookups(id) on delete set null,
  department_id  uuid references public.departments(id) on delete set null,
  status         text not null default 'open' check (status in ('open','converted','cancelled')),
  invoice_id     uuid references public.invoices(id) on delete set null,
  subtotal       numeric(18,3) not null default 0,
  tax_total      numeric(18,3) not null default 0,
  total          numeric(18,3) not null default 0,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now(),
  updated_by     uuid,
  updated_at     timestamptz,
  unique (company_id, order_type, order_no)
);
create table if not exists public.order_lines (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  line_no     int not null default 1,
  item_id     uuid references public.items(id) on delete restrict,
  description text,
  qty         numeric(18,3) not null default 1 check (qty > 0),
  unit_price  numeric(18,3) not null default 0 check (unit_price >= 0),
  discount    numeric(18,3) not null default 0 check (discount >= 0),
  tax_rate    numeric(6,3) not null default 0 check (tax_rate >= 0),
  check (discount <= qty * unit_price)
);
create unique index if not exists orders_invoice_uniq on public.orders (invoice_id) where invoice_id is not null;
create index if not exists order_lines_order_idx on public.order_lines (order_id, line_no);

create or replace function public.order_screen(p_type text) returns text
language sql immutable as $$ select case p_type when 'sales_order' then 'sales_orders' else 'purchase_orders' end $$;

create or replace function public.orders_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.parties; inv public.invoices; ptype text; itype text; v_notes text; v_by uuid; v_at timestamptz;
begin
  if tg_op = 'UPDATE' then
    new.company_id := old.company_id; new.order_type := old.order_type; new.order_no := old.order_no;
    if old.invoice_id is not null and new.invoice_id is null and not exists (select 1 from public.invoices where id = old.invoice_id) then
      new.status := 'open';   -- الفاتورة (المسودة) انحذفت: الطلب بيرجع مفتوح
      return new;
    end if;
    if not public.is_internal() then
      -- المجاميع من السطور بس، والربط بالفاتورة من link_order_invoice بس
      new.subtotal := old.subtotal; new.tax_total := old.tax_total; new.total := old.total;
      new.invoice_id := old.invoice_id;
      if old.status <> 'open' then
        -- الطلب المحوّل أو الملغى: بس الملاحظات بتتعدّل
        v_notes := new.notes; v_by := new.updated_by; v_at := new.updated_at;
        new := old; new.notes := v_notes; new.updated_by := v_by; new.updated_at := v_at;
        return new;
      end if;
      if new.status not in ('open', 'cancelled') then new.status := old.status; end if;
    end if;
  end if;
  if tg_op = 'INSERT' then
    if new.order_no is null then
      perform pg_advisory_xact_lock(hashtext('orders' || new.company_id::text || new.order_type));
      select coalesce(max(order_no), 0) + 1 into new.order_no from public.orders where company_id = new.company_id and order_type = new.order_type;
    end if;
    if not public.is_internal() then new.status := 'open'; new.invoice_id := null; new.subtotal := 0; new.tax_total := 0; new.total := 0; end if;
  end if;
  ptype := (case new.order_type when 'sales_order' then 'customer' else 'supplier' end);
  itype := (case new.order_type when 'sales_order' then 'sale' else 'purchase' end);
  if new.party_id is not null and (tg_op = 'INSERT' or new.party_id is distinct from old.party_id) then
    select * into p from public.parties where id = new.party_id;
    if p.id is null or p.company_id <> new.company_id or p.party_type <> ptype then
      raise exception 'الطرف مش مناسب لهالطلب';
    end if;
  end if;
  if new.sales_rep_id is not null and (tg_op = 'INSERT' or new.sales_rep_id is distinct from old.sales_rep_id) and not exists (select 1 from public.lookups l where l.id = new.sales_rep_id and l.company_id = new.company_id and l.kind = 'sales_rep') then
    raise exception 'المندوب مش لهالشركة';
  end if;
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not exists (select 1 from public.departments d where d.id = new.department_id and d.company_id = new.company_id and d.kind = 'sub') then
    raise exception 'الدائرة لازم تكون فرعية ومن نفس الشركة';
  end if;
  if new.invoice_id is not null and (tg_op = 'INSERT' or new.invoice_id is distinct from old.invoice_id) then
    select * into inv from public.invoices where id = new.invoice_id;
    if inv.id is null or inv.company_id <> new.company_id
       or inv.inv_type <> itype then
      raise exception 'الفاتورة مش مناسبة لهالطلب';
    end if;
    new.status := 'converted';
  end if;
  return new;
end $$;
drop trigger if exists orders_before on public.orders;
create trigger orders_before before insert or update on public.orders
  for each row execute function public.orders_before();

-- مجموع الطلب من سطوره
create or replace function public.order_lines_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid uuid := coalesce(new.order_id, old.order_id); s numeric; t numeric; prev text := current_setting('sumou.internal', true);
begin
  select coalesce(sum(round(qty * unit_price - discount, 3)), 0), coalesce(sum(round((qty * unit_price - discount) * tax_rate / 100, 3)), 0)
    into s, t from public.order_lines where order_id = oid;
  if exists (select 1 from public.orders where id = oid and (subtotal, tax_total) is distinct from (s, t)) then
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.orders set subtotal = s, tax_total = t, total = s + t where id = oid;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  return null;
end $$;
drop trigger if exists order_lines_after on public.order_lines;
create trigger order_lines_after after insert or update or delete on public.order_lines
  for each row execute function public.order_lines_after();

create or replace function public.order_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare o public.orders; it public.items;
begin
  if tg_op = 'UPDATE' and new.order_id <> old.order_id then raise exception 'السطر ما بينقل لطلب ثاني'; end if;
  select * into o from public.orders where id = coalesce(new.order_id, old.order_id);
  if o.status <> 'open' and not public.is_internal() then raise exception 'الطلب مش مفتوح، ما بينعدّل'; end if;
  if tg_op <> 'DELETE' and new.item_id is not null then
    select * into it from public.items where id = new.item_id;
    if it.id is null or it.company_id <> o.company_id then raise exception 'الصنف مش لهالشركة'; end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists order_lines_before on public.order_lines;
create trigger order_lines_before before insert or update or delete on public.order_lines
  for each row execute function public.order_lines_before();

alter table public.orders enable row level security;
alter table public.order_lines enable row level security;
drop policy if exists ord_select on public.orders;
create policy ord_select on public.orders for select to authenticated using (public.can(company_id, public.order_screen(order_type), 'view'));
drop policy if exists ord_insert on public.orders;
create policy ord_insert on public.orders for insert to authenticated with check (public.can(company_id, public.order_screen(order_type), 'add'));
drop policy if exists ord_update on public.orders;
create policy ord_update on public.orders for update to authenticated
  using (public.can(company_id, public.order_screen(order_type), 'edit')) with check (public.can(company_id, public.order_screen(order_type), 'edit'));
drop policy if exists ord_delete on public.orders;
create policy ord_delete on public.orders for delete to authenticated using (status = 'open' and public.can(company_id, public.order_screen(order_type), 'delete'));
drop policy if exists ordl_all on public.order_lines;
drop policy if exists ordl_select on public.order_lines;
create policy ordl_select on public.order_lines for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and public.can(o.company_id, public.order_screen(o.order_type), 'view')));
drop policy if exists ordl_insert on public.order_lines;
create policy ordl_insert on public.order_lines for insert to authenticated
  with check (exists (select 1 from public.orders o where o.id = order_id
                and (public.can(o.company_id, public.order_screen(o.order_type), 'edit') or public.can(o.company_id, public.order_screen(o.order_type), 'add'))));
drop policy if exists ordl_update on public.order_lines;
create policy ordl_update on public.order_lines for update to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and public.can(o.company_id, public.order_screen(o.order_type), 'edit')))
  with check (exists (select 1 from public.orders o where o.id = order_id and public.can(o.company_id, public.order_screen(o.order_type), 'edit')));
drop policy if exists ordl_delete on public.order_lines;
create policy ordl_delete on public.order_lines for delete to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
           and (public.can(o.company_id, public.order_screen(o.order_type), 'edit') or public.can(o.company_id, public.order_screen(o.order_type), 'add'))));

-- ربط الطلب بالفاتورة اللي انعملت منه (بصلاحية إضافة فواتير، ما بدها تعديل طلبات)
create or replace function public.link_order_invoice(p_order uuid, p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders; i public.invoices; prev text := current_setting('sumou.internal', true);
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null or not public.can(o.company_id, public.order_screen(o.order_type), 'view') then raise exception 'الطلب مش موجود'; end if;
  select * into i from public.invoices where id = p_invoice;
  if i.id is null or i.company_id <> o.company_id or i.inv_type <> (case o.order_type when 'sales_order' then 'sale' else 'purchase' end) then raise exception 'الفاتورة مش مناسبة لهالطلب'; end if;
  if not public.can(i.company_id, case i.inv_type when 'sale' then 'sales_invoices' else 'purchase_invoices' end, 'add') then raise exception 'ما عندك صلاحية'; end if;
  if i.created_by is distinct from auth.uid() and not public.is_admin() then raise exception 'الفاتورة لازم تكون اللي إنت عملتها هلّق'; end if;
  if o.status <> 'open' then raise exception 'الطلب مش مفتوح (يمكن تحوّل من قبل)'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.orders set invoice_id = p_invoice, status = 'converted' where id = p_order;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
end $$;
grant execute on function public.link_order_invoice(uuid, uuid) to authenticated;
grant select, insert, update, delete on public.orders, public.order_lines to authenticated;

drop trigger if exists ac_audit_stamp on public.orders;
create trigger ac_audit_stamp before insert or update on public.orders for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.orders;
create trigger zy_audit_log after insert or update or delete on public.orders for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  العروض الترويجية: خصم % على صنف أو فئة أو كل الأصناف خلال فترة
-- ---------------------------------------------------------------------
create table if not exists public.promotions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  name         text not null,
  date_from    date not null,
  date_to      date not null,
  item_id      uuid references public.items(id) on delete cascade,
  category_id  uuid references public.item_categories(id) on delete cascade,
  discount_pct numeric(6,3) not null check (discount_pct > 0 and discount_pct <= 100),
  min_qty      numeric(18,3) not null default 0,
  is_active    boolean not null default true,
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz default now(),
  check (date_to >= date_from)
);
create or replace function public.promotions_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  if new.item_id is not null and not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id) then raise exception 'الصنف مش لهالشركة'; end if;
  if new.category_id is not null and not exists (select 1 from public.item_categories where id = new.category_id and company_id = new.company_id) then raise exception 'الفئة مش لهالشركة'; end if;
  return new;
end $$;
drop trigger if exists promotions_before on public.promotions;
create trigger promotions_before before insert or update on public.promotions for each row execute function public.promotions_before();
alter table public.promotions enable row level security;
drop policy if exists promo_select on public.promotions;
create policy promo_select on public.promotions for select to authenticated using (public.has_company(company_id));
drop policy if exists promo_write on public.promotions;
create policy promo_write on public.promotions for all to authenticated
  using (public.can(company_id, 'marketing', 'edit')) with check (public.can(company_id, 'marketing', 'edit'));
grant select, insert, update, delete on public.promotions to authenticated;

-- ---------------------------------------------------------------------
--  بطاقات الولاء: نوع البطاقة (lookups kind = loyalty_type، rate = نقاط لكل دينار) ورقم البطاقة على العميل
-- ---------------------------------------------------------------------
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%loyalty_type%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'lookups_kind_chk2') then
    alter table public.lookups add constraint lookups_kind_chk2
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep','loyalty_type'));
  end if;
end $$;
alter table public.parties add column if not exists loyalty_type_id uuid references public.lookups(id) on delete set null;
alter table public.parties add column if not exists loyalty_card_no text;
alter table public.parties add column if not exists loyalty_redeemed numeric(18,3) not null default 0;   -- نقاط مستبدلة
create or replace function public.parties_loyalty_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.loyalty_type_id is not null and (tg_op = 'INSERT' or new.loyalty_type_id is distinct from old.loyalty_type_id)
     and not exists (select 1 from public.lookups l where l.id = new.loyalty_type_id and l.company_id = new.company_id and l.kind = 'loyalty_type') then
    raise exception 'نوع بطاقة الولاء مش لهالشركة';
  end if;
  if new.loyalty_redeemed < 0 then raise exception 'النقاط المستبدلة ما بتكون سالبة'; end if;
  return new;
end $$;
drop trigger if exists parties_loyalty_check on public.parties;
create trigger parties_loyalty_check before insert or update of loyalty_type_id, loyalty_redeemed on public.parties
  for each row execute function public.parties_loyalty_check();

-- ---------------------------------------------------------------------
--  الحقول الإضافية: تعريف حقول للعملاء والموردين والأصناف، والقيم بعمود extra
-- ---------------------------------------------------------------------
create table if not exists public.custom_fields (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  entity     text not null check (entity in ('customer','supplier','item')),
  key        text not null check (key ~ '^[a-z][a-z0-9_]{0,30}$'),
  label      text not null,
  field_type text not null default 'text' check (field_type in ('text','number','date','select','check')),
  options    text,          -- للاختيارات: مفصولة بفاصلة
  sort       int not null default 0,
  is_active  boolean not null default true,
  unique (company_id, entity, key)
);
alter table public.custom_fields enable row level security;
drop policy if exists cf_select on public.custom_fields;
create policy cf_select on public.custom_fields for select to authenticated using (public.has_company(company_id));
drop policy if exists cf_write on public.custom_fields;
create policy cf_write on public.custom_fields for all to authenticated
  using (public.can(company_id, 'lookups', 'edit')) with check (public.can(company_id, 'lookups', 'edit'));
grant select, insert, update, delete on public.custom_fields to authenticated;
alter table public.parties add column if not exists extra jsonb not null default '{}'::jsonb;
alter table public.items   add column if not exists extra jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------
--  النسخ الاحتياطي
-- ---------------------------------------------------------------------
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'lookups',            'company_id = $1', 'parent_id nulls first, kind, code'),
   (8,  'custom_fields',      'company_id = $1', 'entity, sort'),
   (9,  'party_categories',   'company_id = $1', 'party_type, code'),
   (10, 'parties',            'company_id = $1', 'code'),
   (11, 'item_categories',    'company_id = $1', 'code'),
   (12, 'items',              'company_id = $1', 'code'),
   (13, 'promotions',         'company_id = $1', 'date_from'),
   (14, 'warehouses',         'company_id = $1', 'code'),
   (15, 'departments',        'company_id = $1', 'level, code'),
   (16, 'journal_entries',    'company_id = $1', 'created_at'),
   (17, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (18, 'invoices',           'company_id = $1', 'created_at'),
   (19, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (20, 'orders',             'company_id = $1', 'created_at'),
   (21, 'order_lines',        'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (22, 'cheques',            'company_id = $1', 'created_at'),
   (23, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (24, 'stock_docs',         'company_id = $1', 'created_at'),
   (25, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (26, 'stock_moves',        'company_id = $1', 'created_at'),
   (27, 'obligations',        'company_id = $1', 'due_date'),
   (28, 'recurring_entries',  'company_id = $1', 'created_at'),
   (29, 'employees',          'company_id = $1', 'code'),
   (30, 'payroll_runs',       'company_id = $1', 'period'),
   (31, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (32, 'fixed_assets',       'company_id = $1', 'code'),
   (33, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (34, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (35, 'bank_recons',        'company_id = $1', 'created_at'),
   (36, 'bank_cleared',       'company_id = $1', 'line_id'),
   (37, 'attachments',        'company_id = $1', 'created_at'),
   (38, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;


-- #################### 26_manufacturing_service.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 26: التصنيع (قوائم المواد وأوامر الإنتاج)، الصيانة (بطاقات الصيانة)، تنسيق الحقول
--  أمر الإنتاج بيعمل سندين مخزون مسودة: إخراج المواد الخام، وإدخال المنتج بكلفتها؛ وبيترحّلوا بالطريقة العادية.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

-- تنسيق الحقول لكل شركة: {entity: {field: {hide, label, required}}}
alter table public.company_settings add column if not exists field_layout jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------
--  قوائم المواد (الوصفة): منتج نهائي = مجموعة مواد خام بكميات
-- ---------------------------------------------------------------------
create table if not exists public.boms (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  item_id     uuid not null references public.items(id) on delete restrict,   -- المنتج
  output_qty  numeric(18,3) not null default 1 check (output_qty > 0),         -- الكمية اللي بتطلع من الوصفة
  extra_cost  numeric(18,3) not null default 0 check (extra_cost >= 0),       -- كلفة إضافية (عمالة، تشغيل) لكل دفعة
  is_active   boolean not null default true,
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz default now(),
  unique (company_id, code)
);
alter table public.boms add column if not exists updated_by uuid;
alter table public.boms add column if not exists updated_at timestamptz;
create table if not exists public.bom_lines (
  id       uuid primary key default gen_random_uuid(),
  bom_id   uuid not null references public.boms(id) on delete cascade,
  line_no  int not null default 1,
  item_id  uuid not null references public.items(id) on delete restrict,
  qty      numeric(18,3) not null check (qty > 0)
);
create unique index if not exists bom_lines_no_uniq on public.bom_lines (bom_id, line_no);
create or replace function public.boms_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; end if;
  if public.is_internal() then return new; end if;
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id and item_type = 'goods') then
    raise exception 'المنتج لازم يكون صنف بضاعة من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists boms_before on public.boms;
create trigger boms_before before insert or update on public.boms for each row execute function public.boms_before();
create or replace function public.bom_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare b public.boms;
begin
  if tg_op = 'UPDATE' and new.bom_id <> old.bom_id then raise exception 'السطر ما بينقل لوصفة ثانية'; end if;
  if public.is_internal() then return new; end if;
  select * into b from public.boms where id = new.bom_id;
  if not exists (select 1 from public.items where id = new.item_id and company_id = b.company_id and item_type = 'goods') then
    raise exception 'المادة لازم تكون صنف بضاعة من نفس الشركة';
  end if;
  if new.item_id = b.item_id then raise exception 'المنتج ما بيكون مادة بوصفته'; end if;
  return new;
end $$;
drop trigger if exists bom_lines_before on public.bom_lines;
create trigger bom_lines_before before insert or update on public.bom_lines for each row execute function public.bom_lines_before();

-- أوامر الإنتاج
create table if not exists public.productions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  prod_no      int check (prod_no > 0),
  prod_date    date not null default current_date,
  bom_id       uuid not null references public.boms(id) on delete restrict,
  batches      numeric(18,3) not null check (batches > 0),      -- عدد الدفعات
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  out_doc_id   uuid references public.stock_docs(id) on delete set null,
  in_doc_id    uuid references public.stock_docs(id) on delete set null,
  total_cost   numeric(18,3) not null default 0,
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz default now(),
  unique (company_id, prod_no)
);

alter table public.stock_docs add column if not exists production_id uuid;

-- سندات أمر الإنتاج بتترحّل وبتنحذف من أمر الإنتاج بس (post_production / delete_production)
create or replace function public.prod_token_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_setting('sumou.prod', true), '') = public.internal_token()
$$;
revoke execute on function public.prod_token_ok() from public, anon, authenticated;
create or replace function public.ab_production_doc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.production_id is not null and not public.prod_token_ok() and not public.is_internal()
       and exists (select 1 from public.companies where id = old.company_id) then
      raise exception 'هالسند تابع لأمر إنتاج، احذف أمر الإنتاج من شاشة التصنيع';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    new.production_id := old.production_id;
    if old.production_id is not null and old.status = 'draft' and new.status = 'posted' and not public.prod_token_ok() then
      raise exception 'سندات أمر الإنتاج بتترحّل من شاشة أوامر الإنتاج (عشان الكلفة)';
    end if;
  elsif new.production_id is not null and not public.prod_token_ok() and not public.is_internal() then
    new.production_id := null;
  end if;
  return new;
end $$;
drop trigger if exists ab_production_doc_guard on public.stock_docs;
create trigger ab_production_doc_guard before insert or update or delete on public.stock_docs
  for each row execute function public.ab_production_doc_guard();
create or replace function public.ab_production_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select production_id into pid from public.stock_docs where id = coalesce(new.doc_id, old.doc_id);
  if pid is not null and not public.prod_token_ok() and not public.is_internal() then
    raise exception 'سطور سندات أمر الإنتاج ما بتتعدّل';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists ab_production_lines_guard on public.stock_doc_lines;
create trigger ab_production_lines_guard before insert or update or delete on public.stock_doc_lines
  for each row execute function public.ab_production_lines_guard();

-- إنشاء أمر إنتاج: بيعمل السندين (مسودة)، والكلفة بتنحسب وقت الترحيل
create or replace function public.create_production(p_bom uuid, p_batches numeric, p_date date, p_warehouse uuid, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare b public.boms; pid uuid := gen_random_uuid(); od uuid; idoc uuid; n int; r record; ln int := 0; prev text := current_setting('sumou.prod', true);
begin
  select * into b from public.boms where id = p_bom;
  if b.id is null or not b.is_active then raise exception 'الوصفة مش موجودة أو موقوفة'; end if;
  if not public.can(b.company_id, 'manufacturing', 'add') or not public.can(b.company_id, 'inventory', 'add') then raise exception 'ما عندك صلاحية'; end if;
  if coalesce(p_batches, 0) <= 0 then raise exception 'عدد الدفعات لازم أكبر من صفر'; end if;
  if p_date is null then raise exception 'اختار التاريخ'; end if;
  if not exists (select 1 from public.fiscal_years where company_id = b.company_id and not is_closed and p_date between start_date and end_date) then
    raise exception 'التاريخ لازم يكون جوّا سنة مالية مفتوحة';
  end if;
  if not exists (select 1 from public.warehouses where id = p_warehouse and company_id = b.company_id and is_active) then raise exception 'المستودع مش لهالشركة أو موقوف'; end if;
  if not exists (select 1 from public.bom_lines where bom_id = b.id) then raise exception 'الوصفة ما فيها مواد'; end if;
  if exists (select 1 from public.bom_lines l join public.items i on i.id = l.item_id where l.bom_id = b.id and (i.item_type <> 'goods' or not i.is_active)) then
    raise exception 'في مادة بالوصفة موقوفة أو مش بضاعة';
  end if;
  perform pg_advisory_xact_lock(hashtext('prod' || b.company_id::text));
  select coalesce(max(prod_no), 0) + 1 into n from public.productions where company_id = b.company_id;
  perform set_config('sumou.prod', public.internal_token(), true);
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, production_id)
  values (b.company_id, 'out', p_date, p_warehouse, 'أمر إنتاج ' || n || ': مواد خام لـ ' || b.name, pid) returning id into od;
  for r in select l.item_id, l.qty * p_batches as q from public.bom_lines l where l.bom_id = b.id order by l.line_no loop
    ln := ln + 1;
    insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost) values (od, ln, r.item_id, r.q, 0);
  end loop;
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, production_id)
  values (b.company_id, 'in', p_date, p_warehouse, 'أمر إنتاج ' || n || ': ' || b.name, pid) returning id into idoc;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost) values (idoc, 1, b.item_id, b.output_qty * p_batches, 0);
  insert into public.productions (id, company_id, prod_no, prod_date, bom_id, batches, warehouse_id, out_doc_id, in_doc_id, total_cost, notes)
  values (pid, b.company_id, n, p_date, b.id, p_batches, p_warehouse, od, idoc, 0, p_notes);
  perform set_config('sumou.prod', coalesce(prev, ''), true);
  return pid;
end $$;
grant execute on function public.create_production(uuid, numeric, date, uuid, text) to authenticated;

-- ترحيل أمر الإنتاج للمخزون: إخراج المواد أول، وبعدين إدخال المنتج بكلفتها الفعلية + الكلفة الإضافية
create or replace function public.post_production(p_id uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare p public.productions; b public.boms; od public.stock_docs; idoc public.stock_docs; cost numeric; q numeric;
        prev text := current_setting('sumou.prod', true); previ text := current_setting('sumou.internal', true);
begin
  select * into p from public.productions where id = p_id for update;
  if p.id is null or not public.can(p.company_id, 'manufacturing', 'post') or not public.can(p.company_id, 'inventory', 'post') then raise exception 'ما عندك صلاحية ترحيل'; end if;
  select * into b from public.boms where id = p.bom_id;
  select * into od from public.stock_docs where id = p.out_doc_id;
  select * into idoc from public.stock_docs where id = p.in_doc_id;
  if od.id is null or idoc.id is null then raise exception 'سندات أمر الإنتاج ناقصة'; end if;
  if idoc.status = 'posted' then raise exception 'أمر الإنتاج مرحّل من قبل'; end if;
  perform set_config('sumou.prod', public.internal_token(), true);
  if od.status <> 'posted' then perform public.post_stock_doc(od.id); end if;
  select coalesce(-sum(qty * unit_cost), 0) into cost from public.stock_moves where source_type = 'stock_doc' and source_id = od.id;
  cost := round(cost + b.extra_cost * p.batches, 3);
  q := b.output_qty * p.batches;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.stock_doc_lines set unit_cost = round(cost / q, 3) where doc_id = idoc.id;
  update public.productions set total_cost = cost where id = p.id;
  perform set_config('sumou.internal', coalesce(previ, ''), true);
  perform public.post_stock_doc(idoc.id);
  perform set_config('sumou.prod', coalesce(prev, ''), true);
  return cost;
end $$;
grant execute on function public.post_production(uuid) to authenticated;

-- حذف أمر الإنتاج مع سنداته (مسودات بس)
create or replace function public.delete_production(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p public.productions; prev text := current_setting('sumou.prod', true);
begin
  select * into p from public.productions where id = p_id for update;
  if p.id is null or not public.can(p.company_id, 'manufacturing', 'delete') or not public.can(p.company_id, 'inventory', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if exists (select 1 from public.stock_docs where id in (p.out_doc_id, p.in_doc_id) and status = 'posted') then
    raise exception 'في سند مرحّل لأمر الإنتاج؛ ألغِ ترحيله أول';
  end if;
  perform set_config('sumou.prod', public.internal_token(), true);
  delete from public.productions where id = p.id;
  delete from public.stock_docs where id in (p.out_doc_id, p.in_doc_id);
  perform set_config('sumou.prod', coalesce(prev, ''), true);
end $$;
grant execute on function public.delete_production(uuid) to authenticated;

-- الإنتاج ما بينعدّل مباشرة (بس الملاحظات)
create or replace function public.productions_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if public.is_internal() then return new; end if;
  v := new.notes; new := old; new.notes := v; return new;
end $$;
drop trigger if exists productions_before on public.productions;
create trigger productions_before before update on public.productions for each row execute function public.productions_before();

alter table public.boms enable row level security;
alter table public.bom_lines enable row level security;
alter table public.productions enable row level security;
drop policy if exists bom_select on public.boms;
create policy bom_select on public.boms for select to authenticated using (public.can(company_id, 'manufacturing', 'view'));
drop policy if exists bom_insert on public.boms;
create policy bom_insert on public.boms for insert to authenticated with check (public.can(company_id, 'manufacturing', 'add'));
drop policy if exists bom_update on public.boms;
create policy bom_update on public.boms for update to authenticated using (public.can(company_id, 'manufacturing', 'edit')) with check (public.can(company_id, 'manufacturing', 'edit'));
drop policy if exists bom_delete on public.boms;
create policy bom_delete on public.boms for delete to authenticated using (public.can(company_id, 'manufacturing', 'delete'));
drop policy if exists boml_select on public.bom_lines;
create policy boml_select on public.bom_lines for select to authenticated
  using (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'view')));
drop policy if exists boml_write on public.bom_lines;
create or replace function public.bom_has_lines(p_bom uuid) returns boolean
language sql stable security definer set search_path = public as $$ select exists (select 1 from public.bom_lines where bom_id = p_bom) $$;
drop policy if exists boml_insert on public.bom_lines;
create policy boml_insert on public.bom_lines for insert to authenticated
  with check (exists (select 1 from public.boms b where b.id = bom_id and (public.can(b.company_id, 'manufacturing', 'edit')
    or (public.can(b.company_id, 'manufacturing', 'add') and b.created_by = auth.uid() and not public.bom_has_lines(b.id)))));
drop policy if exists boml_update on public.bom_lines;
create policy boml_update on public.bom_lines for update to authenticated
  using (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'edit')))
  with check (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'edit')));
drop policy if exists boml_delete on public.bom_lines;
create policy boml_delete on public.bom_lines for delete to authenticated
  using (exists (select 1 from public.boms b where b.id = bom_id and public.can(b.company_id, 'manufacturing', 'edit')));
drop policy if exists prod_select on public.productions;
create policy prod_select on public.productions for select to authenticated using (public.can(company_id, 'manufacturing', 'view'));
drop policy if exists prod_update on public.productions;
create policy prod_update on public.productions for update to authenticated using (public.can(company_id, 'manufacturing', 'edit')) with check (public.can(company_id, 'manufacturing', 'edit'));
drop policy if exists prod_delete on public.productions;
grant select, insert, update, delete on public.boms, public.bom_lines to authenticated;
grant select, update on public.productions to authenticated;
revoke delete on public.productions from authenticated;
drop trigger if exists ac_audit_stamp on public.boms;
create trigger ac_audit_stamp before insert or update on public.boms for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.boms;
create trigger zy_audit_log after insert or update or delete on public.boms for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  الصيانة: بطاقة لكل جهاز بيستلمه المحل من العميل
-- ---------------------------------------------------------------------
create table if not exists public.service_tickets (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  ticket_no     int check (ticket_no > 0),
  received_at   date not null default current_date,
  party_id      uuid references public.parties(id) on delete restrict,
  customer_name text,
  phone         text,
  device        text not null,
  serial_no     text,
  problem       text,
  accessories   text,
  technician    text,
  estimate      numeric(18,3) not null default 0 check (estimate >= 0),
  status        text not null default 'received' check (status in ('received','in_progress','waiting_parts','ready','delivered','cancelled')),
  promised_at   date,
  delivered_at  date,
  work_done     text,
  invoice_id    uuid references public.invoices(id) on delete set null,
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz default now(),
  updated_by    uuid,
  updated_at    timestamptz,
  unique (company_id, ticket_no)
);
create or replace function public.service_tickets_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_op = 'UPDATE' then new.company_id := old.company_id; new.ticket_no := old.ticket_no; end if;
  if tg_op = 'INSERT' and not (public.is_internal() and new.ticket_no is not null) then
    perform pg_advisory_xact_lock(hashtext('svc' || new.company_id::text));
    select coalesce(max(ticket_no), 0) + 1 into n from public.service_tickets where company_id = new.company_id;
    new.ticket_no := n;
  end if;
  if btrim(coalesce(new.device, '')) = '' then raise exception 'اكتب الجهاز'; end if;
  if new.party_id is not null and (tg_op = 'INSERT' or new.party_id is distinct from old.party_id)
     and not exists (select 1 from public.parties where id = new.party_id and company_id = new.company_id and party_type = 'customer') then
    raise exception 'العميل مش لهالشركة';
  end if;
  if new.invoice_id is not null and (tg_op = 'INSERT' or new.invoice_id is distinct from old.invoice_id) and not public.is_internal()
     and (not public.can(new.company_id, 'sales_invoices', 'add')
          or not exists (select 1 from public.invoices where id = new.invoice_id and company_id = new.company_id and inv_type = 'sale' and created_by = auth.uid())) then
    raise exception 'الفاتورة مش مناسبة';
  end if;
  if new.status = 'delivered' and new.delivered_at is null then new.delivered_at := current_date; end if;
  return new;
end $$;
drop trigger if exists service_tickets_before on public.service_tickets;
create trigger service_tickets_before before insert or update on public.service_tickets for each row execute function public.service_tickets_before();
alter table public.service_tickets enable row level security;
drop policy if exists svc_select on public.service_tickets;
create policy svc_select on public.service_tickets for select to authenticated using (public.can(company_id, 'maintenance', 'view'));
drop policy if exists svc_insert on public.service_tickets;
create policy svc_insert on public.service_tickets for insert to authenticated with check (public.can(company_id, 'maintenance', 'add'));
drop policy if exists svc_update on public.service_tickets;
create policy svc_update on public.service_tickets for update to authenticated using (public.can(company_id, 'maintenance', 'edit')) with check (public.can(company_id, 'maintenance', 'edit'));
drop policy if exists svc_delete on public.service_tickets;
create policy svc_delete on public.service_tickets for delete to authenticated using (public.can(company_id, 'maintenance', 'delete') and invoice_id is null);
grant select, insert, update, delete on public.service_tickets to authenticated;
drop trigger if exists ac_audit_stamp on public.service_tickets;
create trigger ac_audit_stamp before insert or update on public.service_tickets for each row execute function public.ac_audit_stamp();
drop trigger if exists zy_audit_log on public.service_tickets;
create trigger zy_audit_log after insert or update or delete on public.service_tickets for each row execute function public.zy_audit_log();

-- ---------------------------------------------------------------------
--  النسخ الاحتياطي
-- ---------------------------------------------------------------------
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1,  'companies',          'id = $1', 'code'),
   (2,  'fiscal_years',       'company_id = $1', 'start_date'),
   (3,  'accounts',           'company_id = $1', 'level, code'),
   (4,  'cost_centers',       'company_id = $1', 'code'),
   (5,  'currencies',         'company_id = $1', 'code'),
   (6,  'company_settings',   'company_id = $1', 'company_id'),
   (7,  'lookups',            'company_id = $1', 'parent_id nulls first, kind, code'),
   (8,  'custom_fields',      'company_id = $1', 'entity, sort'),
   (9,  'party_categories',   'company_id = $1', 'party_type, code'),
   (10, 'parties',            'company_id = $1', 'code'),
   (11, 'item_categories',    'company_id = $1', 'code'),
   (12, 'items',              'company_id = $1', 'code'),
   (13, 'promotions',         'company_id = $1', 'date_from'),
   (14, 'warehouses',         'company_id = $1', 'code'),
   (15, 'departments',        'company_id = $1', 'level, code'),
   (16, 'boms',               'company_id = $1', 'code'),
   (17, 'bom_lines',          'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (18, 'journal_entries',    'company_id = $1', 'created_at'),
   (19, 'journal_lines',      'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (20, 'invoices',           'company_id = $1', 'created_at'),
   (21, 'invoice_lines',      'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (22, 'orders',             'company_id = $1', 'created_at'),
   (23, 'order_lines',        'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (24, 'service_tickets',    'company_id = $1', 'ticket_no'),
   (25, 'cheques',            'company_id = $1', 'created_at'),
   (26, 'cheque_events',      'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (27, 'stock_docs',         'company_id = $1', 'created_at'),
   (28, 'stock_doc_lines',    'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (29, 'stock_moves',        'company_id = $1', 'created_at'),
   (30, 'productions',        'company_id = $1', 'prod_no'),
   (31, 'obligations',        'company_id = $1', 'due_date'),
   (32, 'recurring_entries',  'company_id = $1', 'created_at'),
   (33, 'employees',          'company_id = $1', 'code'),
   (34, 'payroll_runs',       'company_id = $1', 'period'),
   (35, 'payroll_lines',      'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (36, 'fixed_assets',       'company_id = $1', 'code'),
   (37, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (38, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (39, 'bank_recons',        'company_id = $1', 'created_at'),
   (40, 'bank_cleared',       'company_id = $1', 'line_id'),
   (41, 'attachments',        'company_id = $1', 'created_at'),
   (42, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;
