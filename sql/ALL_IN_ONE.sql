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
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || e.entry_no || coalesce(' - ' || e.description, '')),
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
create or replace function public.rep_ledger(p_company uuid, p_fy uuid, p_account uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text,
               line_description text, reference text, account_code text, account_name text, debit numeric, credit numeric)
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
         a.code, a.name, l.debit, l.credit
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
create or replace function public.rep_journal(p_company uuid, p_fy uuid, p_from date, p_to date, p_type text default null)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text, reference text, party_name text,
               status text, line_no int, account_code text, account_name text, line_description text, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, e.reference, e.party_name, e.status,
         l.line_no, a.code, a.name, l.description, l.debit, l.credit
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
create or replace function public.rep_party_ledger(p_company uuid, p_fy uuid, p_party uuid, p_from date, p_to date)
returns table (entry_id uuid, entry_type text, entry_no int, entry_date date, description text, line_description text,
               reference text, debit numeric, credit numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'reports', 'view') then raise exception 'ما عندك صلاحية على التقارير'; end if;
  return query
  select e.id, e.entry_type, e.entry_no, e.entry_date, e.description, l.description, e.reference, l.debit, l.credit
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
  select * into fy from public.fiscal_years
   where company_id = e.company_id and p_date between start_date and end_date and not is_closed
   order by start_date desc limit 1;
  if fy.id is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ %', p_date; end if;

  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, reversal_of)
  values (e.company_id, fy.id, e.entry_type, p_date,
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || e.entry_no || coalesce(' - ' || e.description, '')),
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
  check (entry_type in ('journal','receipt','payment','opening','invoice','closing','cheque'));

create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances'
                when 'invoice' then 'journal_entries' when 'closing' then 'journal_entries' when 'cheque' then 'journal_entries' end;
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
           || ' رقم ' || i.inv_no || coalesce(' - ' || coalesce(p.name, i.party_name), '');

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
  check (entry_type in ('journal','receipt','payment','opening','invoice','closing','cheque'));

create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances'
                when 'invoice' then 'journal_entries' when 'closing' then 'journal_entries' when 'cheque' then 'journal_entries' end;
$$;

-- منع إنشاء قيد إقفال من برّا (بس من دالة الإغلاق)
create or replace function public.entries_type_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.entry_type = 'closing' and not public.is_internal() then raise exception 'قيد الإقفال بينعمل من زر «إغلاق السنة» بس'; end if;
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
         case new.inv_type when 'sale' then 'فاتورة بيع ' when 'sale_return' then 'مرتجع بيع ' when 'purchase' then 'فاتورة شراء ' else 'مرتجع شراء ' end || new.inv_no
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
  descr := case d.doc_type when 'in' then 'سند إدخال ' when 'out' then 'سند إخراج ' when 'transfer' then 'سند تحويل ' else 'جرد ' end || d.doc_no;
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
