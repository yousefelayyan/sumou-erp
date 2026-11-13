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
insert into public.user_groups (name, description, permissions)
select v.* from (values
  ('محاسب', 'إدخال وتعديل على الشركات المسموحة',
   '{"companies":{"view":true,"edit":true,"print":true},
     "fiscal_years":{"view":true,"add":true,"edit":true,"print":true}}'::jsonb),
  ('مدخل بيانات', 'إدخال فقط بدون تعديل بيانات الشركة',
   '{"companies":{"view":true},
     "fiscal_years":{"view":true}}'::jsonb),
  ('مشاهد', 'عرض وطباعة فقط',
   '{"companies":{"view":true,"print":true},
     "fiscal_years":{"view":true,"print":true}}'::jsonb)
) v(name, description, permissions)
where not exists (select 1 from public.user_groups g where g.name = v.name);

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
  if not (public.can(i.company_id, public.invoice_screen(i.inv_type), 'post')
          or (to_regproc('public.pos_ok') is not null and public.pos_ok(i.company_id))) then raise exception 'ما عندك صلاحية ترحيل الفواتير'; end if;
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
  if fy.id is not null and (not public.has_company(fy.company_id) or not public.tenant_writable()) then raise exception 'ما عندك صلاحية لهالعملية'; end if;
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
  if fy.id is not null and (not public.has_company(fy.company_id) or not public.tenant_writable()) then raise exception 'ما عندك صلاحية لهالعملية'; end if;
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
-- بعد المرحلة 28 الاسم فريد جوّا المشترك (profiles_tenant_username_uq)
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'tenant_id') then
    create unique index if not exists profiles_username_uq on public.profiles (lower(username)) where username is not null;
  end if;
end $$;

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
  if c.id is null or not public.has_company(p_company) then raise exception 'الشركة مش موجودة'; end if;
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
  if to_regproc('public.tenant_writable') is not null and not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  if p_data ->> 'app' <> 'sumou-erp' or p_data -> 'tables' is null then raise exception 'الملف مش نسخة احتياطية من السمو ERP'; end if;
  cid := (p_data ->> 'company_id')::uuid;
  if exists (select 1 from public.companies where id = cid) then
    raise exception 'الشركة «%» موجودة. الاسترجاع بيرجّع شركة انحذفت أو لقاعدة جديدة بس', coalesce(p_data ->> 'company_name', '');
  end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  for r in select * from public.backup_tables() order by ord loop
    rows := coalesce(p_data -> 'tables' -> r.tbl, '[]'::jsonb);
    if jsonb_array_length(rows) = 0 then continue; end if;
    -- الروابط الذاتية والحالات اللي بتمنع الإدخال بتنحط بعدين
    if r.tbl in ('invoices', 'stock_docs', 'orders') then   -- التجميد بيرجع بالآخر
      rows := (select jsonb_agg(x - 'is_frozen') from jsonb_array_elements(rows) x);
    end if;
    if r.tbl = 'journal_entries' then
      rows := (select jsonb_agg(x - 'reversal_of' - 'reversed_by' - 'is_frozen') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'invoices' then
      rows := (select jsonb_agg(x - 'original_invoice_id') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'supply_requests' then   -- سنداته بتنرجع بعد ما تنضاف سندات المخزون
      rows := (select jsonb_agg(x - 'out_doc_id' - 'in_doc_id') from jsonb_array_elements(rows) x);
    elsif r.tbl = 'bank_recons' then
      rows := (select jsonb_agg(jsonb_set(x, '{status}', '"open"')) from jsonb_array_elements(rows) x);
    elsif r.tbl = 'companies' then   -- المستخدم اللي أنشأها ممكن ما يكون موجود بقاعدة جديدة
      rows := (select jsonb_agg(case when exists (select 1 from auth.users u where u.id::text = x ->> 'created_by') then x else jsonb_set(x, '{created_by}', 'null') end) from jsonb_array_elements(rows) x);
    elsif r.tbl = 'obligations' then
      rows := (select jsonb_agg(case when exists (select 1 from public.profiles u where u.id::text = x ->> 'assigned_to' and u.tenant_id is not distinct from public.my_tenant()) then x else jsonb_set(x, '{assigned_to}', 'null') end) from jsonb_array_elements(rows) x);
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
  -- علامة التجميد بالآخر (عشان ما تمنع إرجاع الروابط والسطور)
  for r in select * from (values ('journal_entries'), ('invoices'), ('stock_docs'), ('orders')) v(tbl) loop
    if exists (select 1 from pg_attribute where attrelid = ('public.' || r.tbl)::regclass and attname = 'is_frozen' and not attisdropped) then
      execute format('update public.%I t set is_frozen = true from jsonb_array_elements(coalesce($1, ''[]''::jsonb)) x where t.id = (x ->> ''id'')::uuid and (x ->> ''is_frozen'')::boolean', r.tbl)
        using p_data -> 'tables' -> r.tbl;
    end if;
  end loop;
  if to_regclass('public.supply_requests') is not null then
    update public.supply_requests q set out_doc_id = (x ->> 'out_doc_id')::uuid, in_doc_id = (x ->> 'in_doc_id')::uuid
      from jsonb_array_elements(coalesce(p_data -> 'tables' -> 'supply_requests', '[]'::jsonb)) x
     where q.id = (x ->> 'id')::uuid and (x ->> 'out_doc_id' is not null or x ->> 'in_doc_id' is not null);
  end if;
  update public.bank_recons b set status = x ->> 'status'
    from jsonb_array_elements(coalesce(p_data -> 'tables' -> 'bank_recons', '[]'::jsonb)) x where b.id = (x ->> 'id')::uuid;
  -- فحص: كل سطر بالنسخة لازم يكون تابع لهالشركة، وكل رابط لجدول شركات لازم يأشّر على نفس الشركة
  -- (عشان ملف معدّل ما يقدر يكتب أو يربط ببيانات شركة/مشترك ثاني)
  for r in select * from public.backup_tables() order by ord loop
    rows := coalesce(p_data -> 'tables' -> r.tbl, '[]'::jsonb);
    if jsonb_array_length(rows) = 0 then continue; end if;
    execute format('select count(*) from jsonb_populate_recordset(null::public.%I, $2) t where not coalesce((%s), false)', r.tbl, r.cond)
      into n using cid, rows;
    if n > 0 then raise exception 'ملف النسخة مش سليم (جدول %)', r.tbl; end if;
  end loop;
  for r in
    select b.tbl, a.attname as col, c.confrelid::regclass::text as ref, b.cond
    from public.backup_tables() b
    join pg_constraint c on c.conrelid = ('public.' || b.tbl)::regclass and c.contype = 'f' and array_length(c.conkey, 1) = 1
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    join pg_attribute ra on ra.attrelid = c.confrelid and ra.attnum = c.confkey[1] and ra.attname = 'id'
    where c.confrelid = 'public.companies'::regclass
       or exists (select 1 from pg_attribute x where x.attrelid = c.confrelid and x.attname = 'company_id' and not x.attisdropped)
  loop
    if r.ref in ('companies', 'public.companies') then
      execute format('select count(*) from (select * from public.%I where %s) t where t.%I is not null and t.%I <> $1', r.tbl, r.cond, r.col, r.col) into n using cid;
    else
      execute format('select count(*) from (select * from public.%I where %s) t join %s x on x.id = t.%I where x.company_id <> $1', r.tbl, r.cond, r.ref, r.col) into n using cid;
    end if;
    if n > 0 then raise exception 'ملف النسخة مش سليم (رابط % بجدول %)', r.col, r.tbl; end if;
  end loop;
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
  if not (public.can(i.company_id, public.invoice_screen(i.inv_type), 'post')
          or (to_regproc('public.pos_ok') is not null and public.pos_ok(i.company_id))) then raise exception 'ما عندك صلاحية ترحيل الفواتير'; end if;
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
  if not exists (select 1 from pg_constraint where conname in ('lookups_kind_chk', 'lookups_kind_chk2', 'lookups_kind_chk3')) then
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
  if not exists (select 1 from pg_constraint where conname in ('lookups_kind_chk2', 'lookups_kind_chk3')) then
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


-- #################### 27_wip_account.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 27: حساب «الإنتاج تحت التشغيل» لأوامر الإنتاج (الجرد المستمر)
--  سند إخراج المواد: من ح/ الإنتاج تحت التشغيل إلى ح/ المخزون
--  سند إدخال المنتج:  من ح/ المخزون إلى ح/ الإنتاج تحت التشغيل (كلفة المواد + الكلفة الإضافية)
--  الكلفة الإضافية (أجور، تشغيل) بتنقيّد على نفس الحساب بسند قيد، فبيتصفّر.
--  آمن للتشغيل أكثر من مرة.
-- =====================================================================

alter table public.company_settings add column if not exists wip_account_id uuid references public.accounts(id) on delete set null;

-- سندات أمر الإنتاج بتاخذ حساب الإنتاج تحت التشغيل كحساب مقابل
create or replace function public.ab_production_wip() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.production_id is not null and new.account_id is null then
    select wip_account_id into new.account_id from public.company_settings where company_id = new.company_id;
  end if;
  return new;
end $$;
drop trigger if exists ab_production_wip on public.stock_docs;
create trigger ab_production_wip before insert on public.stock_docs
  for each row execute function public.ab_production_wip();

-- إنشاء الحساب لحاله (أخ لحساب المخزون) وربطه
create or replace function public.ensure_wip_account(p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; inv public.accounts; aid uuid; c text; n int := 1;
begin
  if not (public.can(p_company, 'accounts', 'add') and public.can(p_company, 'companies', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  select * into st from public.company_settings where company_id = p_company;
  if st.wip_account_id is not null then return st.wip_account_id; end if;
  select * into inv from public.accounts where id = st.inventory_account_id;
  if inv.id is null then
    select * into inv from public.accounts where company_id = p_company and code = '1105' and not is_group;
  end if;
  if inv.id is null then raise exception 'حدّد حساب المخزون أول بشاشة «حسابات الربط»'; end if;
  select id into aid from public.accounts where company_id = p_company and name = 'الإنتاج تحت التشغيل' and not is_group limit 1;
  if aid is null then
    loop
      c := coalesce((select code from public.accounts where id = inv.parent_id), left(inv.code, greatest(length(inv.code) - 2, 1))) || lpad((90 + n)::text, 2, '0');
      exit when not exists (select 1 from public.accounts where company_id = p_company and code = c);
      n := n + 1; if n > 9 then raise exception 'ما لقيت رمز فاضي للحساب، اعمله بإيدك من دليل الحسابات'; end if;
    end loop;
    insert into public.accounts (company_id, code, name, parent_id, level, is_group, category, nature, account_type)
    values (p_company, c, 'الإنتاج تحت التشغيل', inv.parent_id, inv.level, false, 'assets', 'debit', 'general') returning id into aid;
  end if;
  update public.company_settings set wip_account_id = aid where company_id = p_company;
  -- سندات الإنتاج المسودة اللي ما إلها حساب
  update public.stock_docs set account_id = aid
   where company_id = p_company and production_id is not null and account_id is null and entry_id is null and status = 'draft';
  return aid;
end $$;
grant execute on function public.ensure_wip_account(uuid) to authenticated;


-- #################### 28_tenants.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 28: المشتركين (الاشتراكات والتراخيص)
--  كل مكتب/شركة بتشترك = «مشترك» (tenant) بياناته معزولة تماماً.
--  للمشترك: عدد مستخدمين، عدد شركات، الأقسام المفتوحة، وتاريخ انتهاء.
--  بعد الانتهاء: عرض وطباعة بس. الموقوف: ما بيشوف شي.
--  مدير المنصة (is_super) بيدير المشتركين والدفعات من دوال super_*.
--  ملاحظة: هالملف بيعيد تعريف is_active_user/is_admin/has_company/can
--  وسياسات الجداول العامة (profiles, companies, user_groups, user_companies,
--  activity_log). أي ملف بعده بيعدّلهم لازم يحافظ على شرط المشترك.
-- =====================================================================

create table if not exists public.tenants (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[a-z0-9][a-z0-9-]{1,19}$'),
  name          text not null,
  is_default    boolean not null default false,
  status        text not null default 'active' check (status in ('active','suspended')),
  plan          text,
  max_users     int check (max_users is null or max_users > 0),
  max_companies int check (max_companies is null or max_companies > 0),
  modules       text[],                 -- null = كل الأقسام
  expires_at    date,                   -- آخر يوم بالاشتراك؛ null = مفتوح
  contact_name  text,
  phone         text,
  email         text,
  notes         text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint tenants_reserved_code check (is_default or code <> 'sumou')
);
create unique index if not exists tenants_one_default on public.tenants ((true)) where is_default;

create table if not exists public.tenant_payments (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  paid_at    date not null default current_date,
  amount     numeric(14,3) not null default 0 check (amount >= 0),
  method     text,                      -- كليك، تحويل، نقدي…
  months     int not null default 0 check (months >= 0 and months <= 120),
  reference  text,
  notes      text,
  expires_before date,
  expires_after  date,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists tenant_payments_tenant on public.tenant_payments (tenant_id, paid_at desc);

insert into public.tenants (code, name, is_default)
select 'sumou', 'مؤسسة السمو للمحاسبة والتدريب', true
where not exists (select 1 from public.tenants where is_default);

create or replace function public.default_tenant() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.tenants where is_default limit 1;
$$;

-- الأعمدة الجديدة + تعبئة البيانات الموجودة بالمشترك الافتراضي
alter table public.profiles     add column if not exists tenant_id uuid references public.tenants(id);
alter table public.profiles     add column if not exists is_super  boolean not null default false;
alter table public.profiles     add column if not exists pos_only  boolean not null default false;  -- مستخدم نقطة بيع بس (المرحلة 29)
alter table public.companies    add column if not exists tenant_id uuid references public.tenants(id);
alter table public.user_groups  add column if not exists tenant_id uuid references public.tenants(id);
alter table public.activity_log add column if not exists tenant_id uuid references public.tenants(id) on delete cascade;

do $$
declare dt uuid := public.default_tenant();
begin
  -- التعبئة بدون ما تشتغل triggers الحماية
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.profiles     set tenant_id = dt where tenant_id is null;
  update public.companies    set tenant_id = dt where tenant_id is null;
  update public.user_groups  set tenant_id = dt where tenant_id is null;
  update public.activity_log set tenant_id = dt where tenant_id is null;
  -- مدير المنصة: أول مدير بالمشترك الافتراضي (مرة وحدة بس)
  if not exists (select 1 from public.profiles where is_super) then
    update public.profiles set is_super = true
     where id = (select id from public.profiles where tenant_id = dt and is_admin and is_active order by created_at, id limit 1);
  end if;
  perform set_config('sumou.internal', '', true);
end $$;

-- الرموز وأسماء المستخدمين والمجموعات صارت فريدة جوّا المشترك
alter table public.companies   drop constraint if exists companies_code_key;
create unique index if not exists companies_tenant_code_uq on public.companies (tenant_id, code);
alter table public.user_groups drop constraint if exists user_groups_name_key;
create unique index if not exists user_groups_tenant_name_uq on public.user_groups (tenant_id, name);
drop index if exists public.profiles_username_uq;
create unique index if not exists profiles_tenant_username_uq on public.profiles (tenant_id, lower(username)) where username is not null;
create index if not exists profiles_tenant on public.profiles (tenant_id);
create index if not exists companies_tenant on public.companies (tenant_id);
create index if not exists activity_log_tenant on public.activity_log (tenant_id, created_at desc);

-- =====================================================================
--  الدوال الأساسية
-- =====================================================================
create or replace function public.my_tenant() returns uuid
language sql stable security definer set search_path = public as $$
  select tenant_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_super and is_active from public.profiles where id = auth.uid()), false);
$$;

-- المستخدم مفعّل ومشتركه شغّال (مش موقوف)
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_active and t.status = 'active'
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false);
$$;

-- مدير المشترك (مش مدير المنصة)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin and p.is_active and t.status = 'active'
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false);
$$;

-- الاشتراك ساري (مش منتهي ولا موقوف) = مسموح الإدخال والتعديل
create or replace function public.tenant_writable() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select t.status = 'active' and (t.expires_at is null or t.expires_at >= current_date)
                   from public.profiles p join public.tenants t on t.id = p.tenant_id
                   where p.id = auth.uid()), false);
$$;

-- كل شاشة تابعة لأي قسم
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos')   then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s = 'inventory'                                            then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s = 'fixed_assets'                                         then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

create or replace function public.has_company(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.tenants t on t.id = p.tenant_id and t.status = 'active'
    join public.companies c on c.id = cid and c.tenant_id = p.tenant_id
    where p.id = auth.uid() and p.is_active
      and (p.is_admin or (c.is_active and exists (
             select 1 from public.user_companies uc where uc.user_id = p.id and uc.company_id = cid)))
  );
$$;

-- الصلاحية: الشركة من مشترك المستخدم، والقسم مفتوح، والاشتراك ساري (إلا العرض والطباعة)،
-- وبعدين: مدير المشترك أو صلاحية المستخدم/مجموعته
create or replace function public.can(cid uuid, screen text, act text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.tenants t on t.id = p.tenant_id and t.status = 'active'
    join public.companies c on c.id = cid and c.tenant_id = p.tenant_id
    where p.id = auth.uid() and p.is_active
      and (t.modules is null or public.screen_module(screen) = 'core' or public.screen_module(screen) = any (t.modules))
      and (act in ('view', 'print') or t.expires_at is null or t.expires_at >= current_date)
      and (p.is_admin or exists (
        select 1 from public.user_companies uc
        left join public.user_groups g on g.id = uc.group_id
        where uc.user_id = p.id and uc.company_id = cid
          and ((case jsonb_typeof(p.permissions -> screen)
                  when 'boolean' then (p.permissions ->> screen)::boolean
                  when 'object'  then coalesce((p.permissions -> screen ->> act)::boolean, false)
                  else false end)
               or coalesce((g.permissions -> screen ->> act)::boolean, false))))
  );
$$;

create or replace function public.same_tenant_user(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = u and tenant_id = public.my_tenant());
$$;

create or replace function public.tenant_email_domain(t uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when is_default then 'sumou.local' else code || '.sumou.local' end from public.tenants where id = t;
$$;

revoke execute on function public.default_tenant(), public.tenant_email_domain(uuid) from public, anon, authenticated;
grant execute on function public.my_tenant(), public.is_super(), public.is_active_user(), public.is_admin(),
  public.tenant_writable(), public.screen_module(text), public.has_company(uuid), public.can(uuid, text, text),
  public.same_tenant_user(uuid) to authenticated;
revoke execute on function public.my_tenant(), public.is_super(), public.tenant_writable(), public.same_tenant_user(uuid) from anon;

-- =====================================================================
--  الملفات الشخصية
-- =====================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first_user boolean;
begin
  -- الإيميلات الداخلية بتنعمل من البرنامج بس (مش تسجيل ذاتي بالمفتاح العام)
  if lower(coalesce(new.email, '')) like '%sumou.local' and not public.is_internal() then
    raise exception 'التسجيل بهالإيميل مش مسموح';
  end if;
  select not exists (select 1 from public.profiles) into first_user;
  -- أول مستخدم = مدير المنصة ومدير المشترك الافتراضي. غيره (تسجيل ذاتي) بيستنى موافقة
  insert into public.profiles (id, email, full_name, is_admin, is_active, tenant_id, is_super)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
          first_user, first_user, public.default_tenant(), first_user)
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  new.tenant_id := old.tenant_id;
  new.is_super  := old.is_super;
  -- مدير المنصة ما حدا بيوقفه أو بيغيّر صلاحياته غيره
  if old.is_super and old.id is distinct from auth.uid() then
    new.is_admin := old.is_admin; new.is_active := old.is_active; new.email := old.email;
    new.username := old.username; new.permissions := old.permissions; new.pos_only := old.pos_only;
  end if;
  if not public.is_admin() or old.tenant_id is distinct from public.my_tenant() then
    new.is_admin    := old.is_admin;
    new.is_active   := old.is_active;
    new.email       := old.email;
    new.username    := old.username;
    new.permissions := old.permissions;
    new.pos_only    := old.pos_only;
  end if;
  if old.id = auth.uid() then new.pos_only := old.pos_only; end if;   -- ما حدا بيقفل/بيفك نقطة البيع على حاله
  if new.is_active and not old.is_active then perform public.tenant_user_slot_check(old.tenant_id, old.id); end if;
  return new;
end $$;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant()));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable()))
  with check (id = auth.uid() or (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable()));
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.is_admin() and id <> auth.uid() and not is_super and tenant_id = public.my_tenant() and public.tenant_writable());

-- =====================================================================
--  الشركات
-- =====================================================================
create or replace function public.company_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.tenants; n int;
begin
  if tg_op = 'UPDATE' then new.tenant_id := coalesce(old.tenant_id, new.tenant_id); return new; end if;
  -- الشركة دايماً بمشترك اللي عملها (حتى بالاسترجاع)
  new.tenant_id := coalesce(public.my_tenant(), new.tenant_id, public.default_tenant());
  select * into t from public.tenants where id = new.tenant_id for update;
  if t.max_companies is not null then
    select count(*) into n from public.companies where tenant_id = new.tenant_id;
    if n >= t.max_companies then
      raise exception 'وصلت الحد المسموح من الشركات باشتراكك (%). تواصل معنا لزيادته', t.max_companies;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists aa_company_tenant on public.companies;
create trigger aa_company_tenant before insert or update on public.companies
  for each row execute function public.company_tenant();

drop policy if exists companies_insert on public.companies;
create policy companies_insert on public.companies for insert to authenticated
  with check (public.is_admin() and public.tenant_writable());
drop policy if exists companies_delete on public.companies;
create policy companies_delete on public.companies for delete to authenticated
  using (public.is_admin() and public.has_company(id) and public.tenant_writable());

-- =====================================================================
--  المجموعات وربط المستخدمين بالشركات
-- =====================================================================
create or replace function public.user_group_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.tenant_id := coalesce(old.tenant_id, new.tenant_id); return new; end if;
  if public.is_internal() then new.tenant_id := coalesce(new.tenant_id, public.my_tenant(), public.default_tenant());
  else new.tenant_id := coalesce(public.my_tenant(), new.tenant_id, public.default_tenant()); end if;
  return new;
end $$;
drop trigger if exists aa_user_group_tenant on public.user_groups;
create trigger aa_user_group_tenant before insert or update on public.user_groups
  for each row execute function public.user_group_tenant();

drop policy if exists groups_select on public.user_groups;
create policy groups_select on public.user_groups for select to authenticated
  using (public.is_active_user() and tenant_id = public.my_tenant());
drop policy if exists groups_write on public.user_groups;
drop policy if exists groups_insert on public.user_groups;
create policy groups_insert on public.user_groups for insert to authenticated
  with check (public.is_admin() and public.tenant_writable());
drop policy if exists groups_update on public.user_groups;
create policy groups_update on public.user_groups for update to authenticated
  using (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable())
  with check (public.is_admin() and tenant_id = public.my_tenant());
drop policy if exists groups_delete on public.user_groups;
create policy groups_delete on public.user_groups for delete to authenticated
  using (public.is_admin() and tenant_id = public.my_tenant() and public.tenant_writable());

create or replace function public.user_group_ok(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select g is null or exists (select 1 from public.user_groups where id = g and tenant_id = public.my_tenant());
$$;
grant execute on function public.user_group_ok(uuid) to authenticated;

drop policy if exists uc_select on public.user_companies;
create policy uc_select on public.user_companies for select to authenticated
  using (user_id = auth.uid() or (public.is_admin() and public.has_company(company_id)));
drop policy if exists uc_write on public.user_companies;
create policy uc_write on public.user_companies for all to authenticated
  using (public.is_admin() and public.has_company(company_id) and public.tenant_writable())
  with check (public.is_admin() and public.has_company(company_id) and public.tenant_writable()
              and public.same_tenant_user(user_id) and public.user_group_ok(group_id));

-- =====================================================================
--  سجل النشاط
-- =====================================================================
create or replace function public.activity_log_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.tenant_id := coalesce((select tenant_id from public.companies where id = new.company_id),
                            case when public.is_super() then new.tenant_id end,
                            public.my_tenant(),
                            (select tenant_id from public.profiles where id = new.user_id),
                            public.default_tenant());
  return new;
end $$;
drop trigger if exists aa_activity_log_tenant on public.activity_log;
create trigger aa_activity_log_tenant before insert on public.activity_log
  for each row execute function public.activity_log_tenant();

drop policy if exists log_select on public.activity_log;
create policy log_select on public.activity_log for select to authenticated
  using (public.is_admin() and tenant_id = public.my_tenant());

create or replace function public.user_names(p_ids uuid[]) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name, ''), nullif(p.username, ''), split_part(p.email, '@', 1))
  from public.profiles p
  where public.is_active_user() and p.id = any(p_ids) and p.tenant_id = public.my_tenant();
$$;
revoke execute on function public.user_names(uuid[]) from public, anon;
grant execute on function public.user_names(uuid[]) to authenticated;

-- =====================================================================
--  المرفقات والنسخ الاحتياطي بالتخزين
-- =====================================================================
-- مسار الملف لازم يبدأ برمز نفس الشركة (عشان سطر ما يأشّر على ملف شركة ثانية)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'attachments_path_company') then
    alter table public.attachments add constraint attachments_path_company
      check (split_part(path, '/', 1) = company_id::text) not valid;
  end if;
end $$;
drop policy if exists att_insert on public.attachments;
create policy att_insert on public.attachments for insert to authenticated
  with check (public.has_company(company_id) and public.tenant_writable());
drop policy if exists att_delete on public.attachments;
create policy att_delete on public.attachments for delete to authenticated
  using (public.has_company(company_id) and public.tenant_writable() and (created_by = auth.uid() or public.is_admin()));

do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists sumou_att_insert on storage.objects';
    execute 'drop policy if exists sumou_att_select on storage.objects';
    execute $p$create policy sumou_att_select on storage.objects for select to authenticated
      using (bucket_id = 'attachments' and exists (select 1 from public.attachments a where a.path = name
             and split_part(name, '/', 1) = a.company_id::text and public.attachment_visible(a.company_id, a.entity)))$p$;
    execute 'drop policy if exists sumou_att_delete on storage.objects';
    execute 'drop policy if exists sumou_bak_all on storage.objects';
    execute $p$create policy sumou_att_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid) and public.tenant_writable())$p$;
    execute $p$create policy sumou_att_delete on storage.objects for delete to authenticated
      using (bucket_id = 'attachments' and public.has_company(((storage.foldername(name))[1])::uuid) and public.tenant_writable()
             and not exists (select 1 from public.attachments a where a.path = name and not (a.created_by = auth.uid() or public.is_admin())))$p$;
    execute $p$create policy sumou_bak_all on storage.objects for all to authenticated
      using (bucket_id = 'backups' and public.is_admin() and public.has_company(((storage.foldername(name))[1])::uuid))
      with check (bucket_id = 'backups' and public.is_admin() and public.has_company(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

-- =====================================================================
--  إدارة المستخدمين (جوّا المشترك)
-- =====================================================================
create or replace function public.tenant_user_slot_check(p_tenant uuid, p_exclude uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare mx int; n int;
begin
  select max_users into mx from public.tenants where id = p_tenant for update;
  if mx is null then return; end if;
  select count(*) into n from public.profiles where tenant_id = p_tenant and is_active and id is distinct from p_exclude;
  if n >= mx then raise exception 'وصلت الحد المسموح من المستخدمين باشتراكك (%). وقّف مستخدم أو تواصل معنا لزيادة العدد', mx; end if;
end $$;
revoke execute on function public.tenant_user_slot_check(uuid, uuid) from public, anon, authenticated;

-- الإنشاء الفعلي (داخلي — ما إله صلاحية مباشرة)
create or replace function public.create_tenant_user(p_tenant uuid, p_username text, p_full_name text, p_password text,
  p_permissions jsonb, p_companies uuid[], p_is_admin boolean)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); em text; c uuid; prev text := current_setting('sumou.internal', true);
begin
  p_username := lower(trim(coalesce(p_username, '')));
  if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
  if coalesce(length(p_password), 0) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
  if not exists (select 1 from public.tenants where id = p_tenant) then raise exception 'المشترك مش موجود'; end if;
  perform public.tenant_user_slot_check(p_tenant);
  em := p_username || '@' || public.tenant_email_domain(p_tenant);
  if exists (select 1 from auth.users where lower(email) = em)
     or exists (select 1 from public.profiles where tenant_id = p_tenant and lower(username) = p_username) then
    raise exception 'اسم المستخدم «%» موجود من قبل', p_username;
  end if;
  foreach c in array coalesce(p_companies, '{}') loop
    if not exists (select 1 from public.companies where id = c and tenant_id = p_tenant) then raise exception 'شركة مش من نفس المشترك'; end if;
  end loop;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', coalesce(nullif(trim(p_full_name), ''), p_username)),
    now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  update public.profiles set username = p_username, full_name = coalesce(nullif(trim(p_full_name), ''), p_username),
         is_active = true, is_admin = coalesce(p_is_admin, false), permissions = coalesce(p_permissions, '{}'::jsonb),
         tenant_id = p_tenant, is_super = false
   where id = uid;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (uid, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details, tenant_id)
  values (auth.uid(), 'إضافة', 'users', uid, jsonb_build_object('username', p_username), p_tenant);
  return uid;
end $$;
revoke execute on function public.create_tenant_user(uuid, text, text, text, jsonb, uuid[], boolean) from public, anon, authenticated;

create or replace function public.admin_create_user(p_username text, p_full_name text, p_password text,
  p_permissions jsonb default '{}'::jsonb, p_companies uuid[] default '{}', p_is_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يضيف مستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  return public.create_tenant_user(public.my_tenant(), p_username, p_full_name, p_password, p_permissions, p_companies, p_is_admin);
end $$;

create or replace function public.admin_update_user(p_id uuid, p_username text, p_full_name text, p_password text,
  p_permissions jsonb, p_companies uuid[], p_is_admin boolean, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare em text; c uuid; self boolean := (p_id = auth.uid()); t uuid := public.my_tenant(); pr public.profiles;
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يعدّل المستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  select * into pr from public.profiles where id = p_id;
  if pr.id is null or pr.tenant_id is distinct from t then raise exception 'المستخدم مش موجود'; end if;
  if pr.is_super and not self then raise exception 'ما بتقدر تعدّل حساب مدير المنصة'; end if;
  foreach c in array coalesce(p_companies, '{}') loop
    if not exists (select 1 from public.companies where id = c and tenant_id = t) then raise exception 'شركة مش من نفس المشترك'; end if;
  end loop;
  if not self and coalesce(p_is_active, pr.is_active) and not pr.is_active then
    perform public.tenant_user_slot_check(t, p_id);
  end if;
  p_username := nullif(lower(trim(coalesce(p_username, ''))), '');
  if p_username is not null then
    if p_username !~ '^[a-z0-9._-]{2,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (بدون فراغات)'; end if;
    if exists (select 1 from public.profiles where tenant_id = t and lower(username) = p_username and id <> p_id) then raise exception 'اسم المستخدم «%» موجود من قبل', p_username; end if;
    -- المستخدمين اللي انعملوا من البرنامج بيتغيّر إيميلهم الداخلي مع الاسم
    if (select email from auth.users where id = p_id) like '%sumou.local' then
      em := p_username || '@' || public.tenant_email_domain(t);
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
  delete from public.user_companies where user_id = p_id and not (company_id = any (coalesce(p_companies, '{}')));
  foreach c in array coalesce(p_companies, '{}') loop
    insert into public.user_companies (user_id, company_id) values (p_id, c) on conflict do nothing;
  end loop;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'تعديل', 'users', p_id, jsonb_build_object('username', p_username, 'password_changed', coalesce(p_password, '') <> ''));
end $$;

create or replace function public.admin_delete_user(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'بس مدير النظام بيقدر يحذف المستخدمين'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي. البرنامج للعرض والطباعة بس'; end if;
  if p_id = auth.uid() then raise exception 'ما بتقدر تحذف حالك'; end if;
  if not exists (select 1 from public.profiles where id = p_id and tenant_id = public.my_tenant()) then raise exception 'المستخدم مش موجود'; end if;
  if exists (select 1 from public.profiles where id = p_id and is_super) then raise exception 'ما بينحذف مدير المنصة'; end if;
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

-- =====================================================================
--  اشتراكي (للعرض بالبرنامج: التنبيهات والأقسام)
-- =====================================================================
create or replace function public.my_subscription() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'code', t.code, 'name', t.name, 'plan', t.plan, 'status', t.status, 'is_default', t.is_default,
    'expires_at', t.expires_at,
    'days_left', case when t.expires_at is null then null else t.expires_at - current_date end,
    'writable', t.status = 'active' and (t.expires_at is null or t.expires_at >= current_date),
    'modules', to_jsonb(t.modules),
    'max_users', t.max_users, 'max_companies', t.max_companies,
    'users_used', (select count(*) from public.profiles x where x.tenant_id = t.id and x.is_active),
    'companies_used', (select count(*) from public.companies x where x.tenant_id = t.id),
    'is_super', p.is_super)
  from public.profiles p join public.tenants t on t.id = p.tenant_id
  where p.id = auth.uid() and p.is_active;
$$;
revoke execute on function public.my_subscription() from public, anon;
grant execute on function public.my_subscription() to authenticated;

-- =====================================================================
--  لوحة مدير المنصة
-- =====================================================================
alter table public.tenants enable row level security;
alter table public.tenant_payments enable row level security;
drop policy if exists tenants_select on public.tenants;
create policy tenants_select on public.tenants for select to authenticated
  using (public.is_super() or (id = public.my_tenant() and public.is_admin()));
drop policy if exists tenant_payments_select on public.tenant_payments;
create policy tenant_payments_select on public.tenant_payments for select to authenticated
  using (public.is_super() or (tenant_id = public.my_tenant() and public.is_admin()));
revoke all on public.tenants, public.tenant_payments from anon;
grant select on public.tenants, public.tenant_payments to authenticated;
revoke insert, update, delete on public.tenants, public.tenant_payments from authenticated;

create or replace function public.super_tenants()
returns table (id uuid, code text, name text, is_default boolean, status text, plan text, max_users int, max_companies int,
               modules text[], expires_at date, contact_name text, phone text, email text, notes text, created_at timestamptz,
               users_active bigint, users_total bigint, companies_count bigint, last_login timestamptz, paid_total numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالشاشة لمدير المنصة بس'; end if;
  return query
  select t.id, t.code, t.name, t.is_default, t.status, t.plan, t.max_users, t.max_companies, t.modules, t.expires_at,
         t.contact_name, t.phone, t.email, t.notes, t.created_at,
         (select count(*) from public.profiles p where p.tenant_id = t.id and p.is_active),
         (select count(*) from public.profiles p where p.tenant_id = t.id),
         (select count(*) from public.companies c where c.tenant_id = t.id),
         (select max(l.created_at) from public.activity_log l where l.tenant_id = t.id and l.entity = 'auth'),
         (select coalesce(sum(x.amount), 0) from public.tenant_payments x where x.tenant_id = t.id)
  from public.tenants t order by t.is_default desc, t.created_at;
end $$;

create or replace function public.super_save_tenant(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare tid uuid := p_id; old public.tenants; mods text[]; c text;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  if nullif(trim(p ->> 'name'), '') is null then raise exception 'اكتب اسم المشترك'; end if;
  if p ? 'modules' and jsonb_typeof(p -> 'modules') = 'array' then
    select coalesce(array_agg(x), '{}') into mods from jsonb_array_elements_text(p -> 'modules') x
     where x in ('sales','purchases','inventory','banking','payroll','assets','marketing','manufacturing','maintenance','office');
  else mods := null; end if;
  if tid is null then
    c := lower(trim(coalesce(p ->> 'code', '')));
    if c !~ '^[a-z0-9][a-z0-9-]{1,19}$' then raise exception 'رمز المشترك لازم يكون أحرف إنجليزي صغيرة أو أرقام (2 لـ 20)'; end if;
    if c = 'sumou' or exists (select 1 from public.tenants where code = c) then raise exception 'رمز المشترك «%» مستخدم', c; end if;
    insert into public.tenants (code, name, status, plan, max_users, max_companies, modules, expires_at, contact_name, phone, email, notes, created_by)
    values (c, trim(p ->> 'name'), coalesce(nullif(p ->> 'status', ''), 'active'), nullif(p ->> 'plan', ''),
            nullif(p ->> 'max_users', '')::int, nullif(p ->> 'max_companies', '')::int, mods,
            nullif(p ->> 'expires_at', '')::date, nullif(p ->> 'contact_name', ''), nullif(p ->> 'phone', ''),
            nullif(p ->> 'email', ''), nullif(p ->> 'notes', ''), auth.uid())
    returning id into tid;
    -- مجموعات جاهزة للمشترك الجديد
    perform set_config('sumou.internal', public.internal_token(), true);
    insert into public.user_groups (name, description, permissions, tenant_id)
    select g.name, g.description, g.permissions, tid from public.user_groups g
     where g.tenant_id = public.default_tenant() and g.name in ('محاسب', 'مدخل بيانات', 'مشاهد', 'كاشير');
    perform set_config('sumou.internal', '', true);
  else
    select * into old from public.tenants where id = tid;
    if old.id is null then raise exception 'المشترك مش موجود'; end if;
    if old.is_default and coalesce(p ->> 'status', old.status) <> 'active' then raise exception 'ما بتقدر توقف مشتركك الأساسي'; end if;
    update public.tenants set name = trim(p ->> 'name'),
      status = coalesce(nullif(p ->> 'status', ''), status), plan = nullif(p ->> 'plan', ''),
      max_users = nullif(p ->> 'max_users', '')::int, max_companies = nullif(p ->> 'max_companies', '')::int,
      modules = case when old.is_default then null else mods end,
      expires_at = case when old.is_default then null else nullif(p ->> 'expires_at', '')::date end,
      contact_name = nullif(p ->> 'contact_name', ''), phone = nullif(p ->> 'phone', ''),
      email = nullif(p ->> 'email', ''), notes = nullif(p ->> 'notes', ''), updated_at = now()
     where id = tid;
  end if;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), case when p_id is null then 'إضافة' else 'تعديل' end, 'tenants', tid, p - 'password');
  return tid;
end $$;

create or replace function public.super_create_tenant_admin(p_tenant uuid, p_username text, p_full_name text, p_password text)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  return public.create_tenant_user(p_tenant, p_username, p_full_name, p_password, '{}'::jsonb, '{}', true);
end $$;

create or replace function public.super_tenant_users(p_tenant uuid)
returns table (id uuid, username text, full_name text, is_admin boolean, is_active boolean, last_login timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالشاشة لمدير المنصة بس'; end if;
  return query select p.id, p.username, p.full_name, p.is_admin, p.is_active,
    (select max(l.created_at) from public.activity_log l where l.user_id = p.id and l.entity = 'auth')
    from public.profiles p where p.tenant_id = p_tenant order by p.is_admin desc, p.username;
end $$;

-- تغيير كلمة سر مستخدم عند مشترك (لما ينساها مديرهم) أو تفعيل/إيقاف
create or replace function public.super_set_user(p_user uuid, p_password text, p_is_active boolean)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare pr public.profiles; prev text := current_setting('sumou.internal', true);
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into pr from public.profiles where id = p_user;
  if pr.id is null then raise exception 'المستخدم مش موجود'; end if;
  if pr.id = auth.uid() and p_is_active is false then raise exception 'ما بتقدر توقف حالك'; end if;
  if coalesce(p_password, '') <> '' then
    if length(p_password) < 4 then raise exception 'كلمة السر لازم تكون 4 أحرف على الأقل'; end if;
    update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = p_user;
  end if;
  if p_is_active is not null and p_is_active <> pr.is_active then
    if p_is_active then perform public.tenant_user_slot_check(pr.tenant_id, p_user); end if;
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.profiles set is_active = p_is_active where id = p_user;
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  insert into public.activity_log (user_id, action, entity, entity_id, details, tenant_id)
  values (auth.uid(), 'تعديل', 'users', p_user, jsonb_build_object('by_super', true, 'password_changed', coalesce(p_password, '') <> '', 'is_active', p_is_active), pr.tenant_id);
end $$;

-- تسجيل دفعة وتمديد الاشتراك (من آخر يوم أو من اليوم إذا كان منتهي)
create or replace function public.super_add_payment(p_tenant uuid, p_amount numeric, p_months int, p_method text,
  p_paid_at date default current_date, p_reference text default null, p_notes text default null)
returns date language plpgsql security definer set search_path = public as $$
declare t public.tenants; nexp date;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into t from public.tenants where id = p_tenant for update;
  if t.id is null then raise exception 'المشترك مش موجود'; end if;
  if coalesce(p_months, 0) < 0 or coalesce(p_months, 0) > 120 then raise exception 'عدد الأشهر مش منطقي'; end if;
  if coalesce(p_amount, 0) < 0 then raise exception 'المبلغ لازم يكون موجب'; end if;
  nexp := t.expires_at;
  if coalesce(p_months, 0) > 0 and not t.is_default then
    nexp := (greatest(coalesce(t.expires_at, current_date - 1), current_date - 1) + make_interval(months => p_months))::date;
    update public.tenants set expires_at = nexp, updated_at = now() where id = p_tenant;
  end if;
  insert into public.tenant_payments (tenant_id, paid_at, amount, method, months, reference, notes, expires_before, expires_after, created_by)
  values (p_tenant, coalesce(p_paid_at, current_date), coalesce(p_amount, 0), nullif(trim(p_method), ''), coalesce(p_months, 0),
          nullif(trim(p_reference), ''), nullif(trim(p_notes), ''), t.expires_at, nexp, auth.uid());
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'دفعة', 'tenants', p_tenant, jsonb_build_object('amount', p_amount, 'months', p_months, 'expires_at', nexp));
  return nexp;
end $$;

create or replace function public.super_delete_payment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare x public.tenant_payments;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into x from public.tenant_payments where id = p_id;
  if x.id is null then return; end if;
  -- إذا آخر دفعة: بيرجع تاريخ الانتهاء لقبلها
  if x.months > 0 and not exists (select 1 from public.tenant_payments where tenant_id = x.tenant_id and created_at > x.created_at)
     and (select expires_at from public.tenants where id = x.tenant_id) is not distinct from x.expires_after then
    update public.tenants set expires_at = x.expires_before, updated_at = now() where id = x.tenant_id;
  end if;
  delete from public.tenant_payments where id = p_id;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'حذف', 'tenants', x.tenant_id, jsonb_build_object('payment', x.amount, 'months', x.months));
end $$;

revoke execute on function public.super_tenants(), public.super_save_tenant(uuid, jsonb),
  public.super_create_tenant_admin(uuid, text, text, text), public.super_tenant_users(uuid),
  public.super_set_user(uuid, text, boolean),
  public.super_add_payment(uuid, numeric, int, text, date, text, text), public.super_delete_payment(uuid) from public, anon;
grant execute on function public.super_tenants(), public.super_save_tenant(uuid, jsonb),
  public.super_create_tenant_admin(uuid, text, text, text), public.super_tenant_users(uuid),
  public.super_set_user(uuid, text, boolean),
  public.super_add_payment(uuid, numeric, int, text, date, text, text), public.super_delete_payment(uuid) to authenticated;


-- #################### 29_pos.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 29: نقاط البيع (الكاشير)
--  شاشة لمس: فئات وأصناف بالصور، سلة، دفع نقدي/بطاقة، حفظ = فاتورة بيع نقدية
--  مرحّلة للمحاسبة وللمخزون بنفس العملية، ووصل على طابعة الرول.
--  profiles.pos_only (بالمرحلة 28) = المستخدم بيشوف نقطة البيع بس.
--  صلاحيتها شاشة pos (قسم المبيعات). الكاشير ما بيحتاج صلاحية إضافة/ترحيل فواتير:
--  pos_checkout (security definer) بيرحّل عن طريق السر sumou.pos (pos_ok).
-- =====================================================================

alter table public.items add column if not exists image text;   -- صورة مصغّرة (data:image/jpeg;base64…)
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'items_image_chk' and pg_get_constraintdef(oid) not like '%150000%') then
    alter table public.items drop constraint items_image_chk;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_image_chk') then
    alter table public.items add constraint items_image_chk
      check (image is null or (length(image) <= 150000 and image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'));
  end if;
end $$;

alter table public.company_settings add column if not exists pos jsonb not null default '{}'::jsonb;
alter table public.invoices add column if not exists pos boolean not null default false;
alter table public.invoices add column if not exists pos_paid numeric(18,3);
alter table public.invoices add column if not exists pos_method text;          -- اسم وسيلة الدفع وقت البيع
alter table public.invoices drop constraint if exists invoices_pos_method_check;
alter table public.invoices add column if not exists pos_method_id uuid references public.lookups(id) on delete set null;

-- وسائل الدفع: اسم ظاهر بنقطة البيع، ووين بتظهر (فواتير المبيعات / المشتريات / نقطة البيع)
alter table public.lookups add column if not exists pos_label text;
alter table public.lookups add column if not exists use_sales boolean not null default true;
alter table public.lookups add column if not exists use_purchases boolean not null default true;
alter table public.lookups add column if not exists use_pos boolean not null default false;

-- مجموعة «كاشير» جاهزة لكل مشترك (بدون إضافة/ترحيل فواتير مباشرة)
do $$
declare t record; prev text := current_setting('sumou.internal', true);
begin
  perform set_config('sumou.internal', public.internal_token(), true);
  for t in select id from public.tenants loop
    insert into public.user_groups (name, description, permissions, tenant_id)
    select 'كاشير', 'نقطة البيع: بيع نقدي وطباعة الوصل',
      '{"pos":{"view":true,"add":true,"print":true},"sales_invoices":{"view":true,"print":true},"items":{"view":true},"customers":{"view":true}}'::jsonb, t.id
    where not exists (select 1 from public.user_groups g where g.tenant_id = t.id and g.name = 'كاشير');
  end loop;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
end $$;

-- السر اللي بيسمح لـ post_invoice/post_invoice_stock يرحّلوا فاتورة نقطة البيع
create or replace function public.pos_ok(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_setting('sumou.pos', true), '') = public.internal_token() || ':' || cid::text;
$$;
revoke execute on function public.pos_ok(uuid) from public, anon, authenticated;

-- حماية: حقول نقطة البيع بتنكتب من pos_checkout بس، والمستودع لازم من نفس الشركة
create or replace function public.invoice_pos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then return old; end if;
  if not public.is_internal() and not public.pos_ok(new.company_id) then
    if tg_op = 'INSERT' then new.pos := false; new.pos_paid := null; new.pos_method := null; new.pos_method_id := null;
    else new.pos := old.pos; new.pos_paid := old.pos_paid; new.pos_method := old.pos_method; new.pos_method_id := old.pos_method_id; end if;
  end if;
  if new.warehouse_id is not null and (tg_op = 'INSERT' or new.warehouse_id is distinct from old.warehouse_id)
     and not exists (select 1 from public.warehouses w where w.id = new.warehouse_id and w.company_id = new.company_id) then
    raise exception 'المستودع مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ab_invoice_pos_guard on public.invoices;
create trigger ab_invoice_pos_guard before insert or update on public.invoices
  for each row execute function public.invoice_pos_guard();

-- اليوم بتوقيت الأردن (قاعدة البيانات على UTC)
create or replace function public.local_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Amman')::date; $$;

-- البيع من نقطة البيع: فاتورة نقدية + ترحيل للمحاسبة والمخزون بعملية وحدة
create or replace function public.pos_checkout(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid; fy uuid; d date := public.local_today();
  st public.company_settings; cfg jsonb; iid uuid; l jsonb; it public.items; n int := 0;
  qty numeric; price numeric; disc numeric; rate numeric; gross numeric; sub numeric; tax numeric; paid numeric;
  s_sub numeric := 0; s_tax numeric := 0; s_disc numeric := 0; incl boolean; meth text; acc uuid; wh uuid; inv public.invoices;
  can_edit boolean; can_disc boolean; inv_disc numeric := 0; tot_g numeric; share numeric; left_d numeric; xl record; k int;
  pty public.parties; pay_type text := 'cash'; rep_id uuid; pm public.lookups; is_cash boolean; mname text; prev text := current_setting('sumou.pos', true); lines jsonb;
begin
  begin
    cid := (p ->> 'company_id')::uuid; fy := (p ->> 'fiscal_year_id')::uuid; paid := nullif(p ->> 'paid', '')::numeric;
  exception when others then raise exception 'بيانات البيع مش صحيحة';
  end;
  if cid is null or not public.can(cid, 'pos', 'add') then raise exception 'ما عندك صلاحية البيع من نقطة البيع'; end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'السلة فاضية'; end if;
  if jsonb_array_length(p -> 'lines') > 300 then raise exception 'السلة كبيرة كثير'; end if;
  if not exists (select 1 from public.fiscal_years where id = fy and company_id = cid and not is_closed and d between start_date and end_date) then
    raise exception 'لازم تكون على السنة المالية المفتوحة اللي فيها تاريخ اليوم';
  end if;
  can_edit := public.can(cid, 'sales_invoices', 'edit');
  can_disc := can_edit or public.can(cid, 'pos', 'edit');   -- الخصم: صلاحية «تعديل» على نقطة البيع
  begin inv_disc := round(greatest(coalesce(nullif(p ->> 'discount', '')::numeric, 0), 0), 3);
  exception when others then raise exception 'الخصم مش صحيح'; end;
  if inv_disc > 0 and not can_disc then raise exception 'ما عندك صلاحية تعمل خصم'; end if;
  -- مندوب المبيعات (اختياري)
  if nullif(p ->> 'sales_rep_id', '') is not null then
    begin rep_id := (p ->> 'sales_rep_id')::uuid; exception when invalid_text_representation then raise exception 'المندوب مش صحيح'; end;
    if not exists (select 1 from public.lookups r where r.id = rep_id and r.company_id = cid and r.kind = 'sales_rep' and r.is_active) then raise exception 'المندوب مش موجود'; end if;
  end if;
  -- الزبون (بطاقة عميل) اختياري للنقدي، ولازم للآجل
  if nullif(p ->> 'party_id', '') is not null then
    begin select * into pty from public.parties where id = (p ->> 'party_id')::uuid;
    exception when invalid_text_representation then raise exception 'الزبون مش صحيح'; end;
    if pty.id is null or pty.company_id <> cid or pty.party_type <> 'customer' or not pty.is_active then raise exception 'الزبون مش موجود'; end if;
  end if;
  perform public.ensure_company_settings(cid);
  select * into st from public.company_settings where company_id = cid;
  cfg := coalesce(st.pos, '{}'::jsonb);
  incl := coalesce((cfg ->> 'prices_include_tax')::boolean, true);
  if p ->> 'method' = 'credit' then
    -- آجل: على حساب الزبون
    if pty.id is null then raise exception 'البيع الآجل لازم تختار الزبون'; end if;
    if coalesce((cfg ->> 'allow_credit')::boolean, true) is false then raise exception 'البيع الآجل مسكّر بإعدادات نقطة البيع'; end if;
    meth := 'credit'; pay_type := 'credit'; acc := null; mname := 'آجل';
  elsif nullif(p ->> 'method_id', '') is not null then
    -- وسيلة دفع من «إعداد ← وسائل الدفع» (مأشّر عليها «نقطة البيع»)، وحسابها هو الطرف المدين
    begin select * into pm from public.lookups where id = (p ->> 'method_id')::uuid;
    exception when invalid_text_representation then raise exception 'وسيلة الدفع مش صحيحة'; end;
    if pm.id is null or pm.company_id <> cid or pm.kind <> 'payment_method' or not pm.is_active or not pm.use_pos or pm.account_id is null then
      raise exception 'وسيلة الدفع مش متاحة بنقطة البيع';
    end if;
    acc := pm.account_id; mname := coalesce(nullif(pm.pos_label, ''), pm.name); meth := 'method';
    if not exists (select 1 from public.accounts a where a.id = acc and a.company_id = cid and not a.is_group and a.is_active) then
      raise exception 'حساب وسيلة الدفع «%» لازم يكون حساب فرعي فعّال من نفس الشركة', mname;
    end if;
  else
    meth := coalesce(nullif(p ->> 'method', ''), 'cash');
    if meth not in ('cash', 'card') then raise exception 'طريقة الدفع مش صحيحة'; end if;
    acc := case when meth = 'card' then coalesce(nullif(cfg ->> 'card_account_id', '')::uuid, nullif(cfg ->> 'cash_account_id', '')::uuid, st.cash_account_id)
                else coalesce(nullif(cfg ->> 'cash_account_id', '')::uuid, st.cash_account_id) end;
    mname := case meth when 'card' then 'بطاقة' else 'نقدي' end;
    if acc is null then raise exception 'حدد صندوق نقطة البيع من «إعدادات نقطة البيع»'; end if;
    if not exists (select 1 from public.accounts a where a.id = acc and a.company_id = cid and not a.is_group and a.is_active and a.account_type in ('cash', 'bank')) then
      raise exception 'حساب الصندوق/البطاقات بإعدادات نقطة البيع لازم يكون حساب صندوق أو بنك فرعي من نفس الشركة';
    end if;
  end if;
  -- الباقي بس للوسائل اللي حسابها صندوق نقدي
  is_cash := meth <> 'credit' and (exists (select 1 from public.accounts a where a.id = acc and a.account_type = 'cash') or meth = 'cash');
  wh := nullif(cfg ->> 'warehouse_id', '')::uuid;
  if wh is not null and not exists (select 1 from public.warehouses w where w.id = wh and w.company_id = cid) then
    raise exception 'مستودع نقطة البيع مش من نفس الشركة';
  end if;

  perform set_config('sumou.pos', public.internal_token() || ':' || cid::text, true);
  insert into public.invoices (company_id, fiscal_year_id, inv_type, inv_date, payment_type, party_id, party_name, cash_account_id,
                               prices_include_tax, warehouse_id, notes, reference, pos, pos_method, sales_rep_id)
  values (cid, fy, 'sale', d, pay_type, pty.id, case when pay_type = 'cash' then coalesce(left(nullif(trim(p ->> 'party_name'), ''), 120), pty.name) end, acc,
          incl, wh, left(nullif(trim(p ->> 'notes'), ''), 500), 'نقطة بيع', true, mname, rep_id)
  returning id into iid;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    begin
      select * into it from public.items where id = (l ->> 'item_id')::uuid and company_id = cid and is_active;
      qty := round(coalesce((l ->> 'qty')::numeric, 0), 3);
      price := round(coalesce((l ->> 'price')::numeric, it.sale_price), 3);
      disc := round(greatest(coalesce((l ->> 'discount')::numeric, 0), 0), 3);
    exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'سطر % مش صحيح', n;
    end;
    if it.id is null then raise exception 'صنف مش موجود أو موقوف (سطر %)', n; end if;
    if qty <= 0 or qty > 100000 then raise exception 'الكمية مش منطقية (%)', it.name; end if;
    -- السعر والخصم من الصنف إلا إذا معه صلاحية تعديل الفواتير
    if not can_edit then price := it.sale_price; end if;
    if not can_disc then disc := 0; end if;
    if price < 0 then raise exception 'السعر سالب (%)', it.name; end if;
    rate := it.tax_rate;
    gross := round(qty * price - disc, 3);
    if gross < 0 then raise exception 'الخصم أكبر من قيمة السطر (%)', it.name; end if;
    if incl then sub := round(gross / (1 + rate / 100), 3); tax := gross - sub; else sub := gross; tax := round(sub * rate / 100, 3); end if;
    insert into public.invoice_lines (invoice_id, line_no, item_id, description, qty, unit_price, discount, tax_rate, account_id, subtotal, tax_amount, line_total)
    values (iid, n, it.id, it.name, qty, price, disc, rate, it.sales_account_id, sub, tax, sub + tax);
    s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + disc;
  end loop;
  -- خصم على الفاتورة كلها: بيتوزّع على السطور حسب قيمتها
  if inv_disc > 0 then
    select sum(round(x.qty * x.unit_price - x.discount, 3)) into tot_g from public.invoice_lines x where x.invoice_id = iid;
    if inv_disc > tot_g then raise exception 'الخصم (%) أكبر من مجموع الفاتورة (%)', inv_disc, tot_g; end if;
    left_d := inv_disc; k := 0; s_sub := 0; s_tax := 0; s_disc := 0;
    for xl in select * from public.invoice_lines x where x.invoice_id = iid order by x.line_no loop
      k := k + 1;
      gross := round(xl.qty * xl.unit_price - xl.discount, 3);
      share := case when k = n then left_d else least(left_d, round(inv_disc * gross / nullif(tot_g, 0), 3)) end;
      share := least(share, gross); left_d := left_d - share;
      gross := gross - share;
      if incl then sub := round(gross / (1 + xl.tax_rate / 100), 3); tax := gross - sub; else sub := gross; tax := round(sub * xl.tax_rate / 100, 3); end if;
      update public.invoice_lines set discount = xl.discount + share, subtotal = sub, tax_amount = tax, line_total = sub + tax where id = xl.id;
      s_sub := s_sub + sub; s_tax := s_tax + tax; s_disc := s_disc + xl.discount + share;
    end loop;
  end if;
  update public.invoices set pos_method_id = pm.id where id = iid and pm.id is not null;
  if is_cash then
    paid := coalesce(paid, s_sub + s_tax);
    if paid + 0.0005 < s_sub + s_tax then raise exception 'المدفوع (%) أقل من المطلوب (%)', paid, s_sub + s_tax; end if;
  elsif meth = 'credit' then paid := 0;
  else paid := s_sub + s_tax; end if;
  update public.invoices set subtotal = s_sub, tax_total = s_tax, discount_total = s_disc, total = s_sub + s_tax, pos_paid = paid where id = iid;

  perform public.post_invoice(iid);
  if public.posting_flag(cid, 'sale', 'stock') then perform public.post_invoice_stock(iid); end if;
  perform set_config('sumou.pos', coalesce(prev, ''), true);
  select * into inv from public.invoices where id = iid;
  select jsonb_agg(jsonb_build_object('name', x.description, 'qty', x.qty, 'price', x.unit_price, 'discount', x.discount, 'total', round(x.qty * x.unit_price - x.discount, 3)) order by x.line_no)
    into lines from public.invoice_lines x where x.invoice_id = iid;
  return jsonb_build_object('id', inv.id, 'no', inv.inv_no, 'doc_code', inv.doc_code, 'total', inv.total, 'subtotal', inv.subtotal,
    'tax', inv.tax_total, 'discount', inv.discount_total, 'paid', inv.pos_paid, 'change', inv.pos_paid - inv.total,
    'stock_posted', inv.stock_posted, 'method', inv.pos_method, 'customer', pty.name, 'customer_phone', coalesce(pty.mobile, pty.phone), 'created_at', inv.created_at, 'lines', lines);
end $$;
revoke execute on function public.pos_checkout(jsonb) from public, anon;
grant execute on function public.pos_checkout(jsonb) to authenticated;


-- #################### 30_account_links.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 30: طبيعة «مدين ودائن» للحساب + ربط الموظف بحساب
--  الحساب ممكن يكون مرة مدين ومرة دائن (nature = 'both')؛ الرصيد بيظهر
--  بالجهة اللي طلع عليها. والموظف إله حساب من الدليل (مثل ذمم الموظفين).
-- =====================================================================

alter table public.accounts drop constraint if exists accounts_nature_check;
alter table public.accounts add constraint accounts_nature_check check (nature in ('debit', 'credit', 'both'));

alter table public.employees add column if not exists account_id uuid references public.accounts(id) on delete restrict;
create index if not exists employees_account_idx on public.employees (account_id) where account_id is not null;

create or replace function public.employee_account_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.account_id is not null and (tg_op = 'INSERT' or new.account_id is distinct from old.account_id)
     and not exists (select 1 from public.accounts a where a.id = new.account_id and a.company_id = new.company_id and not a.is_group) then
    raise exception 'حساب الموظف لازم يكون حساب فرعي من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_employee_account_check on public.employees;
create trigger ad_employee_account_check before insert or update of account_id on public.employees
  for each row execute function public.employee_account_check();


-- #################### 31_theme.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 31: لون الواجهة لكل مستخدم
--  profiles.theme (المستخدم بيغيّره لحاله)، والمدير بيشغّل/بيطفي الخاصية
--  من الصلاحيات (شاشة theme). أول مرة بس: كل المجموعات بتاخذها مفعّلة.
-- =====================================================================
do $$
declare prev text := current_setting('sumou.internal', true);
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'theme') then
    alter table public.profiles add column theme text;
    perform set_config('sumou.internal', public.internal_token(), true);
    update public.user_groups set permissions = coalesce(permissions, '{}'::jsonb) || '{"theme":{"view":true}}'::jsonb
     where not (coalesce(permissions, '{}'::jsonb) ? 'theme');
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
end $$;
alter table public.profiles drop constraint if exists profiles_theme_chk;
alter table public.profiles add constraint profiles_theme_chk check (theme is null or theme ~ '^[a-z]{2,20}$');


-- #################### 32_fy_unavailable.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 32: السنوات المالية «غير المتاحة»
--  فتح السنة الجاية بدري (عقود، موازنات، أرصدة) بدون ما ينتقل المستخدمين لها.
--  السنة «غير المتاحة» بتشتغل حسب التاريخ، بس ما بتنختار تلقائياً، وبتبيّن بس
--  لمين إله صلاحية شاشة fy_unavailable. ممنوع على السنة اللي فيها تاريخ اليوم.
--  بتصير متاحة لحالها لما يبدأ تاريخها (company_settings.fy_auto_release).
-- =====================================================================
alter table public.fiscal_years add column if not exists unavailable boolean not null default false;
alter table public.company_settings add column if not exists fy_auto_release boolean not null default true;

create or replace function public.fy_unavailable_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unavailable and (tg_op = 'INSERT' or not old.unavailable or new.start_date is distinct from old.start_date or new.end_date is distinct from old.end_date)
     and public.local_today() between new.start_date and new.end_date and not public.is_internal() then
    raise exception 'تاريخ اليوم داخل هالسنة المالية: ما بتصير «غير متاحة» (المستخدمين رح يضلّوا بدون سنة)';
  end if;
  return new;
end $$;
drop trigger if exists ad_fy_unavailable_check on public.fiscal_years;
create trigger ad_fy_unavailable_check before insert or update on public.fiscal_years
  for each row execute function public.fy_unavailable_check();

-- لما يبدأ تاريخ السنة «غير المتاحة» بتصير متاحة (عند دخول أي مستخدم للشركة)
create or replace function public.fy_release_started(p_company uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; y record;
begin
  if not public.has_company(p_company) then return 0; end if;
  if not coalesce((select fy_auto_release from public.company_settings where company_id = p_company), true) then return 0; end if;
  for y in select id, code from public.fiscal_years
            where company_id = p_company and unavailable and start_date <= public.local_today() and not is_closed loop
    update public.fiscal_years set unavailable = false where id = y.id;
    insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
    values (auth.uid(), p_company, 'تعديل', 'fiscal_years', y.id, jsonb_build_object('code', y.code, 'auto_available', true));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.fy_release_started(uuid) from public, anon;
grant execute on function public.fy_release_started(uuid) to authenticated;


-- #################### 33_asset_movements.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 33: حركات الأصول الثابتة
--  استبعاد/إتلاف، بيع مباشر لزبون، ونقل بين الدوائر — مستند واحد بقيده.
--  الكتابة كلها من دوال (asset_mov_*)؛ الجداول للعرض بس.
--  القيد نوعه depreciation (قيود الأصول، داخلي)، وسطر لكل أصل.
-- =====================================================================
alter table public.fixed_assets add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.company_settings add column if not exists asset_disposal_account_id uuid references public.accounts(id) on delete set null;

create table if not exists public.asset_movements (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete cascade,
  mov_no         int not null,
  kind           text not null check (kind in ('dispose','sale','transfer')),
  mov_date       date not null,
  status         text not null default 'draft' check (status in ('draft','posted','cancelled')),
  party_id       uuid references public.parties(id),   -- الزبون (البيع)
  tax_rate       numeric(6,3) not null default 16 check (tax_rate >= 0),
  from_department_id uuid references public.departments(id) on delete set null,
  to_department_id   uuid references public.departments(id) on delete set null,
  reference      text,
  notes          text,
  entry_id       uuid references public.journal_entries(id) on delete set null,
  cancel_entry_id uuid references public.journal_entries(id) on delete set null,
  total_cost     numeric(18,3) not null default 0,
  total_accum    numeric(18,3) not null default 0,
  total_price    numeric(18,3) not null default 0,
  total_tax      numeric(18,3) not null default 0,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  posted_at      timestamptz,
  unique (company_id, mov_no)
);
create table if not exists public.asset_movement_lines (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references public.asset_movements(id) on delete cascade,
  line_no       int not null,
  asset_id      uuid not null references public.fixed_assets(id),
  sale_price    numeric(18,3) not null default 0 check (sale_price >= 0),
  tax_amount    numeric(18,3) not null default 0 check (tax_amount >= 0),
  cost          numeric(18,3),          -- لقطة وقت الترحيل
  accum         numeric(18,3),
  book_value    numeric(18,3),
  prev_status   text,
  prev_department_id uuid,
  notes         text,
  unique (movement_id, asset_id)
);
create index if not exists asset_mov_lines_asset on public.asset_movement_lines (asset_id);

alter table public.asset_movements enable row level security;
alter table public.asset_movement_lines enable row level security;
drop policy if exists am_select on public.asset_movements;
create policy am_select on public.asset_movements for select to authenticated using (public.can(company_id, 'fixed_assets', 'view'));
drop policy if exists aml_select on public.asset_movement_lines;
create policy aml_select on public.asset_movement_lines for select to authenticated
  using (exists (select 1 from public.asset_movements m where m.id = movement_id and public.can(m.company_id, 'fixed_assets', 'view')));
revoke insert, update, delete on public.asset_movements, public.asset_movement_lines from authenticated;
grant select on public.asset_movements, public.asset_movement_lines to authenticated;

-- حساب «أرباح (خسائر) بيع وشطب أصول ثابتة»: أخ لحساب المبيعات، طبيعته مدين ودائن
create or replace function public.ensure_asset_disposal_account(p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare st public.company_settings; sa public.accounts; aid uuid; c text; n int := 1;
begin
  if not (public.can(p_company, 'accounts', 'add') and public.can(p_company, 'companies', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  perform public.ensure_company_settings(p_company);
  select * into st from public.company_settings where company_id = p_company;
  if st.asset_disposal_account_id is not null then return st.asset_disposal_account_id; end if;
  select * into sa from public.accounts where id = st.sales_account_id;
  if sa.id is null then raise exception 'حدّد حساب المبيعات أول بشاشة «حسابات الربط»'; end if;
  select id into aid from public.accounts where company_id = p_company and name = 'أرباح (خسائر) بيع وشطب أصول ثابتة' and not is_group limit 1;
  if aid is null then
    loop
      c := coalesce((select code from public.accounts where id = sa.parent_id), left(sa.code, greatest(length(sa.code) - 2, 1))) || lpad((90 + n)::text, 2, '0');
      exit when not exists (select 1 from public.accounts where company_id = p_company and code = c);
      n := n + 1; if n > 9 then raise exception 'ما لقيت رمز فاضي للحساب، اعمله بإيدك من دليل الحسابات'; end if;
    end loop;
    insert into public.accounts (company_id, code, name, parent_id, level, is_group, category, nature, account_type)
    values (p_company, c, 'أرباح (خسائر) بيع وشطب أصول ثابتة', sa.parent_id, sa.level, false, 'revenue', 'both', 'general') returning id into aid;
  end if;
  update public.company_settings set asset_disposal_account_id = aid where company_id = p_company;
  return aid;
end $$;

-- الأصل اللي انستبعد/انباع بحركة مرحّلة ما بترجع حالته إلا بإلغاء الحركة
create or replace function public.ab_asset_mov_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if new.status is distinct from old.status and exists (select 1 from public.asset_movement_lines l join public.asset_movements m on m.id = l.movement_id
       where l.asset_id = old.id and m.status = 'posted' and m.kind in ('dispose','sale')) then
    raise exception 'الأصل مستبعد بحركة أصول مرحّلة. ألغِ الحركة بدل ما تغيّر حالته';
  end if;
  if new.status = 'disposed' and old.status = 'active' and exists (select 1 from public.asset_movement_lines l join public.asset_movements m on m.id = l.movement_id
       where l.asset_id = old.id and m.status = 'draft') then
    raise exception 'الأصل عليه حركة أصول لسا ما ترحّلت';
  end if;
  return new;
end $$;
drop trigger if exists ab_asset_mov_guard on public.fixed_assets;
create trigger ab_asset_mov_guard before update of status on public.fixed_assets for each row execute function public.ab_asset_mov_guard();

-- حفظ مسودة (جديدة أو تعديل): p = {id?, company_id, kind, mov_date, party_id, tax_rate, from_department_id, to_department_id, reference, notes, lines:[{asset_id, sale_price, tax_amount?, notes}]}
create or replace function public.asset_mov_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; mid uuid := nullif(p ->> 'id', '')::uuid; m public.asset_movements; k text := p ->> 'kind';
  l jsonb; a public.fixed_assets; n int := 0; pty public.parties; fd uuid := nullif(p ->> 'from_department_id', '')::uuid; td uuid := nullif(p ->> 'to_department_id', '')::uuid;
  rate numeric := coalesce(nullif(p ->> 'tax_rate', '')::numeric, 16); pr numeric; tx numeric;
begin
  if mid is not null then
    select * into m from public.asset_movements where id = mid for update;
    if m.id is null then raise exception 'الحركة مش موجودة'; end if;
    cid := m.company_id; k := m.kind;
    if m.status <> 'draft' then raise exception 'الحركة مرحّلة أو ملغاة، ما بتتعدّل'; end if;
    if not public.can(cid, 'fixed_assets', 'edit') then raise exception 'ما عندك صلاحية تعديل حركات الأصول'; end if;
  elsif not public.can(cid, 'fixed_assets', 'add') then raise exception 'ما عندك صلاحية إضافة حركات الأصول';
  end if;
  if k not in ('dispose', 'sale', 'transfer') then raise exception 'نوع الحركة مش صحيح'; end if;
  if nullif(p ->> 'mov_date', '') is null then raise exception 'اكتب تاريخ الحركة'; end if;
  if k = 'sale' then
    select * into pty from public.parties where id = nullif(p ->> 'party_id', '')::uuid;
    if pty.id is null or pty.company_id <> cid or pty.party_type <> 'customer' then raise exception 'البيع لازم إله زبون من نفس الشركة'; end if;
    if rate < 0 or rate > 100 then raise exception 'نسبة الضريبة مش منطقية'; end if;
  end if;
  if k = 'transfer' then
    if td is null then raise exception 'حدّد الدائرة اللي بينتقل لها الأصل'; end if;
    if fd is not distinct from td then raise exception 'الدائرة المنقول منها والمنقول لها لازم يختلفوا'; end if;
    if not exists (select 1 from public.departments where id = td and company_id = cid and is_active)
       or (fd is not null and not exists (select 1 from public.departments where id = fd and company_id = cid)) then raise exception 'الدائرة مش من نفس الشركة'; end if;
  end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'أضف أصل واحد على الأقل'; end if;

  if mid is null then
    perform pg_advisory_xact_lock(hashtext('assetmov:' || cid::text));
    insert into public.asset_movements (company_id, mov_no, kind, mov_date, party_id, tax_rate, from_department_id, to_department_id, reference, notes)
    values (cid, coalesce((select max(mov_no) from public.asset_movements where company_id = cid), 0) + 1, k, (p ->> 'mov_date')::date,
            pty.id, case when k = 'sale' then rate else 0 end, fd, td, nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'notes'), ''))
    returning id into mid;
  else
    update public.asset_movements set mov_date = (p ->> 'mov_date')::date, party_id = pty.id, tax_rate = case when k = 'sale' then rate else 0 end,
           from_department_id = fd, to_department_id = td, reference = nullif(trim(p ->> 'reference'), ''), notes = nullif(trim(p ->> 'notes'), '')
     where id = mid;
    delete from public.asset_movement_lines where movement_id = mid;
  end if;

  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    select * into a from public.fixed_assets where id = (l ->> 'asset_id')::uuid;
    if a.id is null or a.company_id <> cid then raise exception 'أصل مش موجود (سطر %)', n; end if;
    if a.status <> 'active' then raise exception 'الأصل «%» مستبعد', a.name; end if;
    if k = 'transfer' and fd is not null and a.department_id is distinct from fd then raise exception 'الأصل «%» مش بالدائرة المنقول منها', a.name; end if;
    if exists (select 1 from public.asset_movement_lines x join public.asset_movements y on y.id = x.movement_id
               where x.asset_id = a.id and y.status = 'draft' and y.id <> mid) then
      raise exception 'الأصل «%» بحركة ثانية لسا ما ترحّلت', a.name;
    end if;
    pr := case when k = 'sale' then round(coalesce(nullif(l ->> 'sale_price', '')::numeric, 0), 3) else 0 end;
    if k = 'sale' and pr <= 0 then raise exception 'اكتب سعر البيع للأصل «%»', a.name; end if;
    tx := case when k = 'sale' then round(pr * rate / 100, 3) else 0 end;
    insert into public.asset_movement_lines (movement_id, line_no, asset_id, sale_price, tax_amount, notes)
    values (mid, n, a.id, pr, tx, nullif(trim(l ->> 'notes'), ''));
  end loop;
  update public.asset_movements set total_price = (select coalesce(sum(sale_price), 0) from public.asset_movement_lines where movement_id = mid),
         total_tax = (select coalesce(sum(tax_amount), 0) from public.asset_movement_lines where movement_id = mid) where id = mid;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when p ? 'id' and nullif(p ->> 'id', '') is not null then 'تعديل' else 'إضافة' end, 'asset_movements', mid::text, jsonb_build_object('kind', k, 'lines', n));
  return mid;
end $$;

-- الترحيل: القيد + تطبيق الحركة على الأصول
create or replace function public.asset_mov_post(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.asset_movements; st public.company_settings; fy uuid; eid uuid := null; ln int := 0; r record; prev_m date;
  acc_asset uuid; acc_accum uuid; disp uuid; party_acc uuid; v_book numeric; v_accum numeric; t_cost numeric := 0; t_acc numeric := 0; tot numeric := 0;
  descr text; gl numeric; prev text := current_setting('sumou.internal', true);
begin
  select * into m from public.asset_movements where id = p_id for update;
  if m.id is null then raise exception 'الحركة مش موجودة'; end if;
  if not public.can(m.company_id, 'fixed_assets', 'post') then raise exception 'ما عندك صلاحية ترحيل حركات الأصول'; end if;
  if m.status <> 'draft' then raise exception 'الحركة مرحّلة أو ملغاة'; end if;
  if not exists (select 1 from public.asset_movement_lines where movement_id = p_id) then raise exception 'ما في أصول بالحركة'; end if;
  perform public.ensure_company_settings(m.company_id);
  perform public.ensure_payroll_settings(m.company_id);
  select * into st from public.company_settings where company_id = m.company_id;
  prev_m := (date_trunc('month', m.mov_date) - interval '1 day')::date;
  descr := case m.kind when 'dispose' then 'استبعاد أصول' when 'sale' then 'بيع أصول' else 'نقل أصول بين الدوائر' end || ' — حركة ' || m.mov_no;

  if m.kind in ('dispose', 'sale') then
    select id into fy from public.fiscal_years where company_id = m.company_id and m.mov_date between start_date and end_date and not is_closed order by start_date desc limit 1;
    if fy is null then raise exception 'ما في سنة مالية مفتوحة بتاريخ الحركة'; end if;
    disp := st.asset_disposal_account_id;
    if disp is null then raise exception 'حدّد حساب «أرباح وخسائر بيع وشطب الأصول» بحسابات الربط'; end if;
    if m.kind = 'sale' then
      select account_id into party_acc from public.parties where id = m.party_id;
      if party_acc is null then raise exception 'الزبون ما إله حساب'; end if;
      if m.total_tax > 0 and st.output_tax_account_id is null then raise exception 'حدّد حساب ضريبة المبيعات بحسابات الربط'; end if;
    end if;
    perform set_config('sumou.internal', public.internal_token(), true);
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
    values (m.company_id, fy, 'depreciation', m.mov_date, descr, coalesce(m.reference, 'حركة أصول ' || m.mov_no), 'draft') returning id into eid;
  else
    if not exists (select 1 from public.fiscal_years where company_id = m.company_id and m.mov_date between start_date and end_date and not is_closed) then
      raise exception 'ما في سنة مالية مفتوحة بتاريخ الحركة';
    end if;
    perform set_config('sumou.internal', public.internal_token(), true);
  end if;

  for r in select l.*, a.name, a.code, a.cost acost, a.salvage, a.dep_start, a.status astatus, a.department_id adept,
                  a.asset_account_id, a.accum_account_id, a.cost_center_id cc
             from public.asset_movement_lines l join public.fixed_assets a on a.id = l.asset_id
            where l.movement_id = p_id order by l.line_no for update of a loop
    if r.astatus <> 'active' then raise exception 'الأصل «%» مستبعد', r.name; end if;
    v_accum := least(greatest(coalesce(public.asset_accum(r.asset_id), 0), 0), r.acost);
    v_book := r.acost - v_accum;
    if public.asset_last_dep(r.asset_id) > (date_trunc('month', m.mov_date) + interval '1 month - 1 day')::date then
      raise exception 'الأصل «%» إله استهلاك مرحّل بعد شهر الحركة. ألغِ دورة الاستهلاك أو غيّر التاريخ', r.name;
    end if;
    if m.kind = 'transfer' and m.from_department_id is not null and r.adept is distinct from m.from_department_id then
      raise exception 'الأصل «%» ما عاد بالدائرة المنقول منها', r.name;
    end if;
    if m.kind in ('dispose', 'sale') then
      -- لازم يكون مستهلك لنهاية الشهر السابق (عشان القيمة الدفترية تكون صح)
      if r.dep_start <= prev_m and v_accum < r.acost - r.salvage - 0.0005
         and coalesce(public.asset_last_dep(r.asset_id), r.dep_start - 1) < prev_m then
        raise exception 'الأصل «%» لازم يكون مستهلك لنهاية %. رحّل الاستهلاك أول', r.name, to_char(prev_m, 'MM/YYYY');
      end if;
      acc_asset := r.asset_account_id; acc_accum := coalesce(r.accum_account_id, st.accum_dep_account_id);
      if acc_asset is null or acc_accum is null then raise exception 'حدّد حساب الأصل ومجمع الاستهلاك للأصل «%»', r.name; end if;
      -- مدين: المجمع، دائن: الأصل بالكلفة
      if v_accum > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, acc_accum, 'مجمع استهلاك ' || r.code || ' ' || r.name, v_accum, 0); end if;
      ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, cost_center_id) values (eid, ln, acc_asset, r.code || ' ' || r.name, 0, r.acost, r.cc);
      if m.kind = 'dispose' then
        if v_book > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, disp, 'خسارة استبعاد ' || r.code || ' ' || r.name, v_book, 0); end if;
      else
        ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, party_id) values (eid, ln, party_acc, 'بيع ' || r.code || ' ' || r.name, r.sale_price + r.tax_amount, 0, m.party_id);
        if r.tax_amount > 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, st.output_tax_account_id, 'ضريبة بيع ' || r.code, 0, r.tax_amount); end if;
        gl := r.sale_price - v_book;   -- موجب = ربح (دائن)، سالب = خسارة (مدين)
        if gl <> 0 then ln := ln + 1; insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, ln, disp, case when gl > 0 then 'ربح بيع ' else 'خسارة بيع ' end || r.code || ' ' || r.name, greatest(-gl, 0), greatest(gl, 0)); end if;
      end if;
      update public.fixed_assets set status = 'disposed', disposed_date = m.mov_date where id = r.asset_id;
    else
      update public.fixed_assets set department_id = m.to_department_id where id = r.asset_id;
    end if;
    update public.asset_movement_lines set cost = r.acost, accum = v_accum, book_value = v_book, prev_status = r.astatus, prev_department_id = r.adept where id = r.id;
    t_cost := t_cost + r.acost; t_acc := t_acc + v_accum;
  end loop;

  if eid is not null then
    select sum(debit) into tot from public.journal_lines where entry_id = eid;
    if coalesce(tot, 0) = 0 or tot <> (select sum(credit) from public.journal_lines where entry_id = eid) then
      raise exception 'قيد الحركة مش متوازن، راجع بيانات الأصول (الكلفة ومجمع الاستهلاك السابق)';
    end if;
    update public.journal_entries set status = 'posted', total = tot, posted_by = auth.uid(), posted_at = now() where id = eid;
  end if;
  update public.asset_movements set status = 'posted', entry_id = eid, total_cost = t_cost, total_accum = t_acc, posted_at = now() where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), m.company_id, 'ترحيل', 'asset_movements', p_id::text, jsonb_build_object('no', m.mov_no, 'kind', m.kind));
  return eid;
end $$;

-- الإلغاء: المسودة بتنلغى؛ المرحّلة بقيد عكسي وبيرجع الأصل لحالته (إذا ما عليه حركة بعدها)
create or replace function public.asset_mov_cancel(p_id uuid, p_date date default null) returns void
language plpgsql security definer set search_path = public as $$
declare m public.asset_movements; nid uuid; r record; prev text := current_setting('sumou.internal', true);
begin
  select * into m from public.asset_movements where id = p_id for update;
  if m.id is null then raise exception 'الحركة مش موجودة'; end if;
  if not public.can(m.company_id, 'fixed_assets', case when m.status = 'posted' then 'post' else 'edit' end) then raise exception 'ما عندك صلاحية'; end if;
  if m.status = 'cancelled' then raise exception 'الحركة ملغاة من قبل'; end if;
  if m.status = 'posted' then
    for r in select l.asset_id, a.name, a.department_id dept from public.asset_movement_lines l join public.fixed_assets a on a.id = l.asset_id where l.movement_id = p_id loop
      if m.kind = 'transfer' and r.dept is distinct from m.to_department_id then
        raise exception 'الأصل «%» ما عاد بالدائرة المنقول لها، ما بينلغى النقل', r.name;
      end if;
      if exists (select 1 from public.asset_movement_lines x join public.asset_movements y on y.id = x.movement_id
                 where x.asset_id = r.asset_id and y.status = 'posted' and y.posted_at > m.posted_at) then
        raise exception 'على الأصل «%» حركة بعد هاي، ألغِها أول', r.name;
      end if;
      if m.kind in ('dispose', 'sale') and exists (select 1 from public.depreciation_lines dl join public.depreciation_runs dr on dr.id = dl.run_id
                 where dl.asset_id = r.asset_id and dr.status = 'posted' and dl.to_date >= m.mov_date) then
        raise exception 'الأصل «%» إله استهلاك مرحّل بعد تاريخ الحركة', r.name;
      end if;
    end loop;
    if m.entry_id is not null then
      nid := public.reverse_internal(m.entry_id, greatest(coalesce(p_date, public.local_today()), m.mov_date), 'إلغاء حركة أصول ' || m.mov_no);
    end if;
    perform set_config('sumou.internal', public.internal_token(), true);
    if m.kind = 'transfer' then
      update public.fixed_assets a set department_id = l.prev_department_id
        from public.asset_movement_lines l where l.movement_id = p_id and l.asset_id = a.id;
    else
      update public.fixed_assets a set status = coalesce(l.prev_status, 'active'),
             disposed_date = case when coalesce(l.prev_status, 'active') = 'active' then null else a.disposed_date end
        from public.asset_movement_lines l where l.movement_id = p_id and l.asset_id = a.id;
    end if;
  end if;
  update public.asset_movements set status = 'cancelled', cancel_entry_id = nid where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), m.company_id, 'إلغاء', 'asset_movements', p_id::text, jsonb_build_object('no', m.mov_no));
end $$;

create or replace function public.asset_mov_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.asset_movements;
begin
  select * into m from public.asset_movements where id = p_id;
  if m.id is null then return; end if;
  if not public.can(m.company_id, 'fixed_assets', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if m.status = 'posted' then raise exception 'الحركة مرحّلة، ألغِها بدل الحذف'; end if;
  if m.status <> 'draft' then raise exception 'الحركة الملغاة بتضل للسجل، ما بتنحذف'; end if;
  delete from public.asset_movements where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), m.company_id, 'حذف', 'asset_movements', p_id::text, jsonb_build_object('no', m.mov_no, 'kind', m.kind));
end $$;

revoke execute on function public.ensure_asset_disposal_account(uuid), public.asset_mov_save(jsonb), public.asset_mov_post(uuid),
  public.asset_mov_cancel(uuid, date), public.asset_mov_delete(uuid) from public, anon;
grant execute on function public.ensure_asset_disposal_account(uuid), public.asset_mov_save(jsonb), public.asset_mov_post(uuid),
  public.asset_mov_cancel(uuid, date), public.asset_mov_delete(uuid) to authenticated;

-- النسخ الاحتياطي: حركات الأصول بعد الاستهلاك
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
   (39, 'asset_movements',    'company_id = $1', 'mov_no'),
   (40, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (41, 'bank_recons',        'company_id = $1', 'created_at'),
   (42, 'bank_cleared',       'company_id = $1', 'line_id'),
   (43, 'attachments',        'company_id = $1', 'created_at'),
   (44, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;

-- إلغاء دورة استهلاك: ممنوع إذا أصل فيها انستبعد/انباع بحركة مرحّلة
create or replace function public.cancel_depreciation(p_run uuid, p_date date default current_date) returns void
language plpgsql security definer set search_path = public as $$
declare r public.depreciation_runs; nid uuid; nm text;
begin
  select * into r from public.depreciation_runs where id = p_run for update;
  if r.id is null or not public.can(r.company_id, 'fixed_assets', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.status <> 'posted' then raise exception 'الدورة ملغاة من قبل'; end if;
  if exists (select 1 from public.depreciation_runs x where x.company_id = r.company_id and x.status = 'posted' and x.created_at > r.created_at) then
    raise exception 'ألغِ دورات الاستهلاك الأحدث أول';
  end if;
  select a.name into nm from public.depreciation_lines dl join public.fixed_assets a on a.id = dl.asset_id
   where dl.run_id = p_run and exists (select 1 from public.asset_movement_lines l join public.asset_movements m on m.id = l.movement_id
                                        where l.asset_id = dl.asset_id and m.status = 'posted' and m.kind in ('dispose', 'sale')) limit 1;
  if nm is not null then raise exception 'الأصل «%» انستبعد أو انباع بحركة مرحّلة؛ ألغِ الحركة أول', nm; end if;
  nid := public.reverse_internal(r.entry_id, greatest(p_date, r.period_to), 'إلغاء استهلاك لغاية ' || to_char(r.period_to, 'DD/MM/YYYY'));
  update public.depreciation_runs set status = 'cancelled', cancel_entry_id = nid where id = p_run;
  perform set_config('sumou.internal', '', true);
end $$;


-- #################### 34_asset_custody.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 34: عهد الأصول الثابتة
--  أصحاب العهد + مستندات تسليم/نقل/إرجاع بحالات (في الانتظار ← مثبت ← انتهاء العمل ← مغلق).
--  «انتهاء العمل» بيطبّق على الأصول (صاحب العهدة والموقع). ما في قيد محاسبي.
--  الصلاحية: شاشة asset_custody (قسم الأصول).
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos')   then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s = 'inventory'                                            then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s in ('fixed_assets','asset_custody')                      then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

create table if not exists public.asset_custodians (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  employee_id uuid references public.employees(id) on delete set null,
  phone       text,
  notes       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (company_id, code)
);
alter table public.asset_custodians enable row level security;
grant select, insert, update, delete on public.asset_custodians to authenticated;
drop policy if exists acu_select on public.asset_custodians;
create policy acu_select on public.asset_custodians for select to authenticated
  using (public.can(company_id, 'asset_custody', 'view') or public.can(company_id, 'fixed_assets', 'view'));
drop policy if exists acu_insert on public.asset_custodians;
create policy acu_insert on public.asset_custodians for insert to authenticated with check (public.can(company_id, 'asset_custody', 'add'));
drop policy if exists acu_update on public.asset_custodians;
create policy acu_update on public.asset_custodians for update to authenticated using (public.can(company_id, 'asset_custody', 'edit')) with check (public.can(company_id, 'asset_custody', 'edit'));
drop policy if exists acu_delete on public.asset_custodians;
create policy acu_delete on public.asset_custodians for delete to authenticated using (public.can(company_id, 'asset_custody', 'delete'));

create or replace function public.ad_custodian_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.company_id <> old.company_id then raise exception 'ما بتقدر تغيّر شركة صاحب العهدة'; end if;
  if nullif(trim(new.code), '') is null or nullif(trim(new.name), '') is null then raise exception 'رمز صاحب العهدة واسمه مطلوبين'; end if;
  if new.employee_id is not null and not exists (select 1 from public.employees where id = new.employee_id and company_id = new.company_id) then
    raise exception 'الموظف مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_custodian_check on public.asset_custodians;
create trigger ad_custodian_check before insert or update on public.asset_custodians for each row execute function public.ad_custodian_check();

alter table public.fixed_assets add column if not exists custodian_id uuid references public.asset_custodians(id) on delete set null;
alter table public.fixed_assets add column if not exists custody_since date;

create table if not exists public.custody_docs (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  doc_no        int not null,
  kind          text not null check (kind in ('handover','transfer','return')),
  doc_date      date not null,
  status        text not null default 'pending' check (status in ('pending','confirmed','done','closed','cancelled')),
  from_custodian_id uuid references public.asset_custodians(id),
  to_custodian_id   uuid references public.asset_custodians(id),
  location      text,
  department_id uuid references public.departments(id) on delete set null,
  reference     text,
  notes         text,
  done_at       timestamptz,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, doc_no)
);
create table if not exists public.custody_doc_lines (
  id            uuid primary key default gen_random_uuid(),
  doc_id        uuid not null references public.custody_docs(id) on delete cascade,
  line_no       int not null,
  asset_id      uuid not null references public.fixed_assets(id),
  condition     text,
  accessories   text,
  notes         text,
  prev_custodian_id uuid,
  prev_location text,
  prev_since    date,
  unique (doc_id, asset_id)
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'custody_doc_lines_prev_custodian_fk') then
    alter table public.custody_doc_lines add constraint custody_doc_lines_prev_custodian_fk foreign key (prev_custodian_id) references public.asset_custodians(id) on delete set null;
  end if;
end $$;
create index if not exists custody_lines_asset on public.custody_doc_lines (asset_id);
alter table public.custody_docs enable row level security;
alter table public.custody_doc_lines enable row level security;
drop policy if exists cd_select on public.custody_docs;
create policy cd_select on public.custody_docs for select to authenticated using (public.can(company_id, 'asset_custody', 'view'));
drop policy if exists cdl_select on public.custody_doc_lines;
create policy cdl_select on public.custody_doc_lines for select to authenticated
  using (exists (select 1 from public.custody_docs d where d.id = doc_id and public.can(d.company_id, 'asset_custody', 'view')));
revoke insert, update, delete on public.custody_docs, public.custody_doc_lines from authenticated;
grant select on public.custody_docs, public.custody_doc_lines to authenticated;

-- صاحب العهدة على بطاقة الأصل ما بينكتب يدوي: من المستندات بس
create or replace function public.ab_asset_custody_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then
    if new.custodian_id is not null then raise exception 'صاحب العهدة بيتسجّل بمستند «تسليم عهدة»'; end if;
    new.custody_since := null;
  elsif new.custodian_id is distinct from old.custodian_id or new.custody_since is distinct from old.custody_since then
    raise exception 'صاحب العهدة بيتغيّر بمستندات عهد الأصول بس';
  end if;
  return new;
end $$;
drop trigger if exists ab_asset_custody_guard on public.fixed_assets;
create trigger ab_asset_custody_guard before insert or update on public.fixed_assets for each row execute function public.ab_asset_custody_guard();

-- حفظ (جديد أو تعديل وهو «في الانتظار»)
-- p = {id?, company_id, kind, doc_date, from_custodian_id, to_custodian_id, location, department_id, reference, notes, lines:[{asset_id, condition, accessories, notes}]}
create or replace function public.custody_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; did uuid := nullif(p ->> 'id', '')::uuid; d public.custody_docs; k text := p ->> 'kind';
  fc uuid := nullif(p ->> 'from_custodian_id', '')::uuid; tc uuid := nullif(p ->> 'to_custodian_id', '')::uuid; dep uuid := nullif(p ->> 'department_id', '')::uuid;
  l jsonb; a public.fixed_assets; n int := 0;
begin
  if did is not null then
    select * into d from public.custody_docs where id = did for update;
    if d.id is null then raise exception 'المستند مش موجود'; end if;
    cid := d.company_id; k := d.kind;
    if not public.can(cid, 'asset_custody', 'edit') then raise exception 'ما عندك صلاحية تعديل مستندات العهد'; end if;
    if d.status <> 'pending' then raise exception 'المستند مش «في الانتظار»، رجّعه للانتظار أول عشان تعدّله'; end if;
  elsif not public.can(cid, 'asset_custody', 'add') then raise exception 'ما عندك صلاحية إضافة مستندات العهد';
  end if;
  if k not in ('handover', 'transfer', 'return') then raise exception 'نوع الحركة مش صحيح'; end if;
  if nullif(p ->> 'doc_date', '') is null then raise exception 'اكتب التاريخ'; end if;
  if k = 'handover' then fc := null; end if;
  if k = 'return' then tc := null; end if;
  if k in ('transfer', 'return') and fc is null then raise exception 'حدّد صاحب العهدة المسلِّم'; end if;
  if k in ('handover', 'transfer') and tc is null then raise exception 'حدّد صاحب العهدة المستلِم'; end if;
  if fc is not null and fc is not distinct from tc then raise exception 'المسلِّم والمستلِم لازم يختلفوا'; end if;
  if (fc is not null and not exists (select 1 from public.asset_custodians where id = fc and company_id = cid))
     or (tc is not null and not exists (select 1 from public.asset_custodians where id = tc and company_id = cid and is_active)) then
    raise exception 'صاحب العهدة مش من نفس الشركة أو موقوف';
  end if;
  if dep is not null and not exists (select 1 from public.departments where id = dep and company_id = cid) then raise exception 'الدائرة مش من نفس الشركة'; end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'أضف أصل واحد على الأقل'; end if;

  if did is null then
    perform pg_advisory_xact_lock(hashtext('custody:' || cid::text));
    insert into public.custody_docs (company_id, doc_no, kind, doc_date, from_custodian_id, to_custodian_id, location, department_id, reference, notes)
    values (cid, coalesce((select max(doc_no) from public.custody_docs where company_id = cid), 0) + 1, k, (p ->> 'doc_date')::date, fc, tc,
            nullif(trim(p ->> 'location'), ''), dep, nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'notes'), ''))
    returning id into did;
  else
    update public.custody_docs set doc_date = (p ->> 'doc_date')::date, from_custodian_id = fc, to_custodian_id = tc, location = nullif(trim(p ->> 'location'), ''),
           department_id = dep, reference = nullif(trim(p ->> 'reference'), ''), notes = nullif(trim(p ->> 'notes'), '') where id = did;
    delete from public.custody_doc_lines where doc_id = did;
  end if;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    select * into a from public.fixed_assets where id = (l ->> 'asset_id')::uuid;
    if a.id is null or a.company_id <> cid then raise exception 'أصل مش موجود (سطر %)', n; end if;
    if a.status <> 'active' then raise exception 'الأصل «%» مستبعد', a.name; end if;
    if k = 'handover' and a.custodian_id is not null then raise exception 'الأصل «%» بعهدة حدا، استعمل «نقل»', a.name; end if;
    if k in ('transfer', 'return') and a.custodian_id is distinct from fc then raise exception 'الأصل «%» مش بعهدة المسلِّم', a.name; end if;
    if exists (select 1 from public.custody_doc_lines x join public.custody_docs y on y.id = x.doc_id
               where x.asset_id = a.id and y.id <> did and y.status in ('pending', 'confirmed')) then
      raise exception 'الأصل «%» بمستند عهدة ثاني لسا ما انتهى', a.name;
    end if;
    insert into public.custody_doc_lines (doc_id, line_no, asset_id, condition, accessories, notes)
    values (did, n, a.id, nullif(trim(l ->> 'condition'), ''), nullif(trim(l ->> 'accessories'), ''), nullif(trim(l ->> 'notes'), ''));
  end loop;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when p ? 'id' and nullif(p ->> 'id', '') is not null then 'تعديل' else 'إضافة' end, 'custody_docs', did::text, jsonb_build_object('kind', k, 'lines', n));
  return did;
end $$;

-- تغيير الحالة. done = تطبيق على الأصول، والرجوع منها بيرجّع الأصول (إذا ما في مستند أحدث)
create or replace function public.custody_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare d public.custody_docs; r record; prev text := current_setting('sumou.internal', true);
begin
  select * into d from public.custody_docs where id = p_id for update;
  if d.id is null then raise exception 'المستند مش موجود'; end if;
  if p_status not in ('pending', 'confirmed', 'done', 'closed', 'cancelled') then raise exception 'حالة مش صحيحة'; end if;
  if p_status = d.status then return; end if;
  if not public.can(d.company_id, 'asset_custody', case when p_status in ('done', 'closed') or d.status in ('done', 'closed') then 'post' else 'edit' end) then
    raise exception 'ما عندك صلاحية تغيير حالة المستند';
  end if;
  if d.status = 'cancelled' then raise exception 'المستند ملغى'; end if;
  if d.status = 'closed' then raise exception 'المستند مغلق (أرشيف)'; end if;
  if p_status = 'closed' and d.status <> 'done' then raise exception 'بس المستند المنتهي بيتسكّر'; end if;
  if p_status = 'cancelled' and d.status = 'done' then raise exception 'رجّع المستند للانتظار أول'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);

  if p_status = 'done' then
    if not exists (select 1 from public.custody_doc_lines where doc_id = p_id) then raise exception 'ما في أصول بالمستند'; end if;
    for r in select l.id lid, a.* from public.custody_doc_lines l join public.fixed_assets a on a.id = l.asset_id where l.doc_id = p_id order by l.line_no for update of a loop
      if r.status <> 'active' then raise exception 'الأصل «%» مستبعد', r.name; end if;
      if d.kind = 'handover' and r.custodian_id is not null then raise exception 'الأصل «%» بعهدة حدا، استعمل «نقل»', r.name; end if;
      if d.kind in ('transfer', 'return') and r.custodian_id is distinct from d.from_custodian_id then raise exception 'الأصل «%» مش بعهدة المسلِّم', r.name; end if;
      if exists (select 1 from public.custody_doc_lines x join public.custody_docs y on y.id = x.doc_id
                 where x.asset_id = r.id and y.id <> p_id and y.status in ('done', 'closed') and y.doc_date > d.doc_date) then
        raise exception 'الأصل «%» عليه مستند عهدة بتاريخ أحدث', r.name;
      end if;
      update public.custody_doc_lines set prev_custodian_id = r.custodian_id, prev_location = r.location, prev_since = r.custody_since where id = r.lid;
      update public.fixed_assets set custodian_id = d.to_custodian_id,
             custody_since = case when d.to_custodian_id is null then null else d.doc_date end,
             location = coalesce(d.location, location)
       where id = r.id;
    end loop;
    update public.custody_docs set status = 'done', done_at = now() where id = p_id;
  elsif d.status = 'done' and p_status <> 'closed' then   -- رجوع من «انتهاء العمل»
    for r in select l.*, a.name, a.custodian_id cur, a.status astatus, a.location aloc from public.custody_doc_lines l join public.fixed_assets a on a.id = l.asset_id where l.doc_id = p_id for update of a loop
      if r.astatus <> 'active' then raise exception 'الأصل «%» مستبعد، ما بينرجع عن عهدته', r.name; end if;
      if exists (select 1 from public.custody_doc_lines x join public.custody_docs y on y.id = x.doc_id
                 where x.asset_id = r.asset_id and y.id <> p_id and y.status in ('done', 'closed') and y.done_at > d.done_at) then
        raise exception 'على الأصل «%» حركة عهدة لاحقة، ارجع عنها أول', r.name;
      end if;
      update public.fixed_assets set custodian_id = r.prev_custodian_id, custody_since = r.prev_since,
             location = case when d.location is not null and r.aloc is not distinct from d.location then r.prev_location else r.aloc end
       where id = r.asset_id;
    end loop;
    update public.custody_docs set status = p_status, done_at = null where id = p_id;
    update public.custody_doc_lines set prev_custodian_id = null, prev_location = null, prev_since = null where doc_id = p_id;
  else
    update public.custody_docs set status = p_status where id = p_id;
  end if;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), d.company_id, case when p_status in ('done', 'closed') then 'ترحيل' else 'تعديل' end, 'custody_docs', p_id::text,
          jsonb_build_object('no', d.doc_no, 'from', d.status, 'to', p_status));
end $$;

create or replace function public.custody_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.custody_docs;
begin
  select * into d from public.custody_docs where id = p_id;
  if d.id is null then return; end if;
  if not public.can(d.company_id, 'asset_custody', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if d.status not in ('pending', 'cancelled') then raise exception 'بس المستند «في الانتظار» أو الملغى بينحذف'; end if;
  delete from public.custody_docs where id = p_id;
end $$;

-- سجل عهدة أصل (المستندات المنتهية والمغلقة)
create or replace function public.custody_history(p_asset uuid)
returns table (doc_id uuid, doc_no int, kind text, doc_date date, status text, from_name text, to_name text, location text, condition text, accessories text, ended date)
language sql stable security definer set search_path = public as $$
  with h as (
    select d.id, d.doc_no, d.kind, d.doc_date, d.status, f.name fn, t.name tn, d.location, l.condition, l.accessories, d.done_at
      from public.custody_doc_lines l join public.custody_docs d on d.id = l.doc_id
      left join public.asset_custodians f on f.id = d.from_custodian_id left join public.asset_custodians t on t.id = d.to_custodian_id
     where l.asset_id = p_asset and d.status in ('done', 'closed')
       and (public.can(d.company_id, 'asset_custody', 'view') or public.can(d.company_id, 'fixed_assets', 'view')))
  select id, doc_no, kind, doc_date, status, fn, tn, location, condition, accessories, lead(doc_date) over (order by doc_date, done_at) from h order by doc_date desc, done_at desc;
$$;

revoke execute on function public.custody_save(jsonb), public.custody_set_status(uuid, text), public.custody_delete(uuid), public.custody_history(uuid) from public, anon;
grant execute on function public.custody_save(jsonb), public.custody_set_status(uuid, text), public.custody_delete(uuid), public.custody_history(uuid) to authenticated;

-- النسخ الاحتياطي: أصحاب العهد قبل الأصول، والمستندات بعدها
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
   (36, 'asset_custodians',   'company_id = $1', 'code'),
   (37, 'fixed_assets',       'company_id = $1', 'code'),
   (38, 'depreciation_runs',  'company_id = $1', 'created_at'),
   (39, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (40, 'asset_movements',    'company_id = $1', 'mov_no'),
   (41, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (42, 'custody_docs',       'company_id = $1', 'doc_no'),
   (43, 'custody_doc_lines',  'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (44, 'bank_recons',        'company_id = $1', 'created_at'),
   (45, 'bank_cleared',       'company_id = $1', 'line_id'),
   (46, 'attachments',        'company_id = $1', 'created_at'),
   (47, 'fiscal_periods',     'company_id = $1', 'start_date');
$$;


-- #################### 35_supply_requests.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 35: طلبات التزويد بين المستودعات
--  حد أدنى/أعلى لكل صنف بكل مستودع، طلب (في الانتظار ← مثبت)، إصدار سند إخراج من المستودع المصدر،
--  وبعد ترحيله إصدار سند إدخال للمستودع الوجهة بنفس الكلفة. الشاشة supply_requests (قسم المخزون).
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos')   then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s in ('inventory','supply_requests')                       then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s in ('fixed_assets','asset_custody')                      then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

-- حدود الصنف بالمستودع
create table if not exists public.item_wh_limits (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  item_id      uuid not null references public.items(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  min_qty      numeric(18,3) not null default 0 check (min_qty >= 0),
  max_qty      numeric(18,3) check (max_qty is null or max_qty >= 0),
  unique (item_id, warehouse_id),
  check (max_qty is null or max_qty >= min_qty)
);
alter table public.item_wh_limits enable row level security;
grant select, insert, update, delete on public.item_wh_limits to authenticated;
drop policy if exists iwl_select on public.item_wh_limits;
create policy iwl_select on public.item_wh_limits for select to authenticated
  using (public.can(company_id, 'inventory', 'view') or public.can(company_id, 'supply_requests', 'view'));
drop policy if exists iwl_write on public.item_wh_limits;
create policy iwl_write on public.item_wh_limits for all to authenticated
  using (public.can(company_id, 'inventory', 'edit')) with check (public.can(company_id, 'inventory', 'edit'));
create or replace function public.ad_iwl_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.items where id = new.item_id and company_id = new.company_id)
     or not exists (select 1 from public.warehouses where id = new.warehouse_id and company_id = new.company_id) then
    raise exception 'الصنف أو المستودع مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_iwl_check on public.item_wh_limits;
create trigger ad_iwl_check before insert or update on public.item_wh_limits for each row execute function public.ad_iwl_check();

create table if not exists public.supply_requests (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  req_no        int not null,
  req_date      date not null,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id   uuid not null references public.warehouses(id),
  status        text not null default 'pending' check (status in ('pending','confirmed','rejected','cancelled')),
  reference     text,
  notes         text,
  out_doc_id    uuid references public.stock_docs(id) on delete set null,
  in_doc_id     uuid references public.stock_docs(id) on delete set null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (company_id, req_no),
  check (from_warehouse_id <> to_warehouse_id)
);
create table if not exists public.supply_request_lines (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.supply_requests(id) on delete cascade,
  line_no     int not null,
  item_id     uuid not null references public.items(id),
  qty         numeric(18,3) not null check (qty > 0),
  note        text,
  unique (request_id, item_id)
);
alter table public.supply_requests enable row level security;
alter table public.supply_request_lines enable row level security;
drop policy if exists sr_select on public.supply_requests;
create policy sr_select on public.supply_requests for select to authenticated
  using (public.can(company_id, 'supply_requests', 'view') or public.can(company_id, 'inventory', 'view'));
drop policy if exists srl_select on public.supply_request_lines;
create policy srl_select on public.supply_request_lines for select to authenticated
  using (exists (select 1 from public.supply_requests r where r.id = request_id
                 and (public.can(r.company_id, 'supply_requests', 'view') or public.can(r.company_id, 'inventory', 'view'))));
revoke insert, update, delete on public.supply_requests, public.supply_request_lines from authenticated;
grant select on public.supply_requests, public.supply_request_lines to authenticated;

alter table public.stock_docs add column if not exists supply_request_id uuid references public.supply_requests(id) on delete set null;

-- سند الإدخال الناتج من طلب تزويد: أصنافه وكلفته من سند الإخراج، ما بتتعدّل
create or replace function public.ab_supply_in_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare did uuid := case when tg_op = 'DELETE' then old.doc_id else new.doc_id end;
begin
  if public.is_internal() then return coalesce(new, old); end if;
  if exists (select 1 from public.stock_docs where id = did and supply_request_id is not null and doc_type = 'in')
     or (tg_op = 'UPDATE' and old.doc_id <> new.doc_id and exists (select 1 from public.stock_docs where id = old.doc_id and supply_request_id is not null and doc_type = 'in')) then
    raise exception 'سطور سند الإدخال لطلب التزويد ما بتتعدّل (بتيجي من سند الإخراج)';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists ab_supply_in_lines_guard on public.stock_doc_lines;
create trigger ab_supply_in_lines_guard before insert or update or delete on public.stock_doc_lines
  for each row execute function public.ab_supply_in_lines_guard();

-- سطور سندات المخزون: القراءة بصلاحية view، والإضافة add/edit، والتعديل edit، والحذف edit/delete (كانت سياسة وحدة للكل)
drop policy if exists sdl_all on public.stock_doc_lines;
drop policy if exists sdl_select on public.stock_doc_lines;
create policy sdl_select on public.stock_doc_lines for select to authenticated
  using (exists (select 1 from public.stock_docs d where d.id = doc_id and public.can(d.company_id, 'inventory', 'view')));
drop policy if exists sdl_insert on public.stock_doc_lines;
create policy sdl_insert on public.stock_doc_lines for insert to authenticated
  with check (exists (select 1 from public.stock_docs d where d.id = doc_id and (public.can(d.company_id, 'inventory', 'add') or public.can(d.company_id, 'inventory', 'edit'))));
drop policy if exists sdl_update on public.stock_doc_lines;
create policy sdl_update on public.stock_doc_lines for update to authenticated
  using (exists (select 1 from public.stock_docs d where d.id = doc_id and public.can(d.company_id, 'inventory', 'edit')))
  with check (exists (select 1 from public.stock_docs d where d.id = doc_id and public.can(d.company_id, 'inventory', 'edit')));
drop policy if exists sdl_delete on public.stock_doc_lines;
create policy sdl_delete on public.stock_doc_lines for delete to authenticated
  using (exists (select 1 from public.stock_docs d where d.id = doc_id and (public.can(d.company_id, 'inventory', 'edit') or public.can(d.company_id, 'inventory', 'delete'))));

create or replace function public.ab_supply_doc_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() then return new; end if;
  if tg_op = 'INSERT' then new.supply_request_id := null; return new; end if;
  new.supply_request_id := old.supply_request_id;
  if old.supply_request_id is not null and (new.warehouse_id <> old.warehouse_id or new.doc_type <> old.doc_type) then
    raise exception 'مستودع سند طلب التزويد ما بيتغيّر';
  end if;
  return new;
end $$;
drop trigger if exists ab_supply_doc_guard on public.stock_docs;
create trigger ab_supply_doc_guard before insert or update on public.stock_docs for each row execute function public.ab_supply_doc_guard();

-- سند إخراج طلب التزويد: بعد إصدار سند الإدخال ما بينلغى ترحيله
create or replace function public.ab_supply_out_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.supply_request_id is not null and old.doc_type = 'out' and old.status = 'posted' and new.status <> 'posted'
     and exists (select 1 from public.supply_requests where out_doc_id = old.id and in_doc_id is not null) then
    raise exception 'انصدر سند الإدخال لطلب التزويد؛ احذف سند الإدخال أول عشان تلغي ترحيل الإخراج';
  end if;
  return new;
end $$;
drop trigger if exists ab_supply_out_lock on public.stock_docs;
create trigger ab_supply_out_lock before update of status on public.stock_docs for each row execute function public.ab_supply_out_lock();

-- أرصدة أصناف الطلب بالمستودعين (للشاشة)
create or replace function public.supply_balances(p_company uuid, p_from uuid, p_to uuid, p_date date, p_items uuid[])
returns table (item_id uuid, src_qty numeric, dest_qty numeric, min_qty numeric, max_qty numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'supply_requests', 'view') or public.can(p_company, 'inventory', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select i.id, public.stock_qty(i.id, p_from, coalesce(p_date, public.local_today())), public.stock_qty(i.id, p_to, coalesce(p_date, public.local_today())), l.min_qty, l.max_qty
    from public.items i left join public.item_wh_limits l on l.item_id = i.id and l.warehouse_id = p_to
   where i.company_id = p_company and i.id = any(p_items)
     and exists (select 1 from public.warehouses w where w.id = p_from and w.company_id = p_company)
     and exists (select 1 from public.warehouses w where w.id = p_to and w.company_id = p_company);
end $$;
revoke execute on function public.supply_balances(uuid, uuid, uuid, date, uuid[]) from public, anon;
grant execute on function public.supply_balances(uuid, uuid, uuid, date, uuid[]) to authenticated;

-- حفظ الطلب (جديد أو «في الانتظار»): p = {id?, company_id, req_date, from_warehouse_id, to_warehouse_id, reference, notes, lines:[{item_id, qty, note}]}
create or replace function public.supply_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; rid uuid := nullif(p ->> 'id', '')::uuid; r public.supply_requests;
  fw uuid := nullif(p ->> 'from_warehouse_id', '')::uuid; tw uuid := nullif(p ->> 'to_warehouse_id', '')::uuid; l jsonb; it public.items; n int := 0; q numeric;
begin
  if rid is not null then
    select * into r from public.supply_requests where id = rid for update;
    if r.id is null then raise exception 'الطلب مش موجود'; end if;
    cid := r.company_id;
    if not public.can(cid, 'supply_requests', 'edit') then raise exception 'ما عندك صلاحية تعديل طلبات التزويد'; end if;
    if r.status <> 'pending' or r.out_doc_id is not null then raise exception 'الطلب مثبت أو انصدر إله سند، ما بيتعدّل'; end if;
  elsif not public.can(cid, 'supply_requests', 'add') then raise exception 'ما عندك صلاحية إضافة طلبات التزويد';
  end if;
  if nullif(p ->> 'req_date', '') is null then raise exception 'اكتب التاريخ'; end if;
  if fw is null or tw is null or fw = tw then raise exception 'اختار مستودع المصدر والوجهة (مختلفين)'; end if;
  if not exists (select 1 from public.warehouses where id = fw and company_id = cid and is_active)
     or not exists (select 1 from public.warehouses where id = tw and company_id = cid and is_active) then
    raise exception 'المستودع مش من نفس الشركة أو موقوف';
  end if;
  if coalesce(jsonb_typeof(p -> 'lines'), '') <> 'array' or jsonb_array_length(p -> 'lines') = 0 then raise exception 'أضف صنف واحد على الأقل'; end if;
  if jsonb_array_length(p -> 'lines') > 500 then raise exception 'الطلب كبير كثير'; end if;
  if rid is null then
    perform pg_advisory_xact_lock(hashtext('supply:' || cid::text));
    insert into public.supply_requests (company_id, req_no, req_date, from_warehouse_id, to_warehouse_id, reference, notes)
    values (cid, coalesce((select max(req_no) from public.supply_requests where company_id = cid), 0) + 1, (p ->> 'req_date')::date, fw, tw,
            nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'notes'), '')) returning id into rid;
  else
    update public.supply_requests set req_date = (p ->> 'req_date')::date, from_warehouse_id = fw, to_warehouse_id = tw,
           reference = nullif(trim(p ->> 'reference'), ''), notes = nullif(trim(p ->> 'notes'), '') where id = rid;
    delete from public.supply_request_lines where request_id = rid;
  end if;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    select * into it from public.items where id = (l ->> 'item_id')::uuid;
    if it.id is null or it.company_id <> cid then raise exception 'صنف مش موجود (سطر %)', n; end if;
    if it.item_type <> 'goods' or not it.track_stock then raise exception 'الصنف «%» ما إله مخزون', it.name; end if;
    q := round(coalesce(nullif(l ->> 'qty', '')::numeric, 0), 3);
    if q <= 0 then raise exception 'الكمية للصنف «%» لازم أكبر من صفر', it.name; end if;
    if exists (select 1 from public.supply_request_lines where request_id = rid and item_id = it.id) then raise exception 'الصنف «%» مكرر', it.name; end if;
    insert into public.supply_request_lines (request_id, line_no, item_id, qty, note) values (rid, n, it.id, q, nullif(trim(l ->> 'note'), ''));
  end loop;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, case when nullif(p ->> 'id', '') is not null then 'تعديل' else 'إضافة' end, 'supply_requests', rid::text, jsonb_build_object('lines', n));
  return rid;
end $$;

-- الحالة: pending / confirmed / rejected / cancelled
create or replace function public.supply_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests;
begin
  select * into r from public.supply_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if p_status not in ('pending', 'confirmed', 'rejected', 'cancelled') then raise exception 'حالة مش صحيحة'; end if;
  if not public.can(r.company_id, 'supply_requests', case when p_status in ('confirmed', 'rejected') or r.status = 'confirmed' then 'post' else 'edit' end) then
    raise exception 'ما عندك صلاحية تغيير حالة الطلب';
  end if;
  if r.out_doc_id is not null then raise exception 'انصدر للطلب سند إخراج؛ احذف السند (إذا مش مرحّل) أول'; end if;
  if r.status in ('rejected', 'cancelled') and p_status <> 'pending' then raise exception 'الطلب مرفوض أو ملغى'; end if;
  update public.supply_requests set status = p_status where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, case when p_status = 'confirmed' then 'ترحيل' else 'تعديل' end, 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no, 'from', r.status, 'to', p_status));
end $$;

-- إصدار سند الإخراج (مسودة) من مستودع المصدر
create or replace function public.supply_issue_out(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests; did uuid; dep uuid; prev text := current_setting('sumou.internal', true);
begin
  select * into r from public.supply_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if not (public.can(r.company_id, 'inventory', 'add') and (public.can(r.company_id, 'supply_requests', 'view') or public.can(r.company_id, 'inventory', 'view'))) then
    raise exception 'ما عندك صلاحية إصدار سندات المخزون';
  end if;
  select uc.department_id into dep from public.user_companies uc join public.departments dd on dd.id = uc.department_id and dd.is_active and dd.kind = 'sub'
   where uc.user_id = auth.uid() and uc.company_id = r.company_id;
  if r.status <> 'confirmed' then raise exception 'ثبّت الطلب أول'; end if;
  if r.out_doc_id is not null then raise exception 'انصدر سند الإخراج من قبل'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, supply_request_id, department_id)
  values (r.company_id, 'out', greatest(r.req_date, public.local_today()), r.from_warehouse_id, 'طلب تزويد ' || r.req_no || coalesce(' — ' || r.reference, ''), r.id, dep)
  returning id into did;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, note)
  select did, line_no, item_id, qty, note from public.supply_request_lines where request_id = p_id order by line_no;
  update public.supply_requests set out_doc_id = did where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إضافة', 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no, 'out_doc', did));
  return did;
end $$;

-- إصدار سند الإدخال (مسودة) للمستودع الوجهة: بعد ترحيل الإخراج، بالكميات والكلفة الفعلية
create or replace function public.supply_issue_in(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests; o public.stock_docs; did uuid; prev text := current_setting('sumou.internal', true);
begin
  select * into r from public.supply_requests where id = p_id for update;
  if r.id is null then raise exception 'الطلب مش موجود'; end if;
  if not (public.can(r.company_id, 'inventory', 'add') and (public.can(r.company_id, 'supply_requests', 'view') or public.can(r.company_id, 'inventory', 'view'))) then
    raise exception 'ما عندك صلاحية إصدار سندات المخزون';
  end if;
  if r.in_doc_id is not null then raise exception 'انصدر سند الإدخال من قبل'; end if;
  select * into o from public.stock_docs where id = r.out_doc_id;
  if o.id is null then raise exception 'اصدر سند الإخراج أول'; end if;
  if o.status <> 'posted' then raise exception 'سند الإخراج لسا ما ترحّل للمخزون'; end if;
  if o.doc_type <> 'out' or o.supply_request_id is distinct from r.id or o.warehouse_id <> r.from_warehouse_id then raise exception 'سند الإخراج مش تابع لهالطلب'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.stock_docs (company_id, doc_type, doc_date, warehouse_id, notes, supply_request_id, department_id, account_id)
  values (r.company_id, 'in', greatest(o.doc_date, public.local_today()), r.to_warehouse_id, 'استلام طلب تزويد ' || r.req_no, r.id, o.department_id, o.account_id) returning id into did;
  insert into public.stock_doc_lines (doc_id, line_no, item_id, qty, unit_cost, note)
  select did, row_number() over (order by min(m.created_at)), m.item_id, -sum(m.qty), round(sum(m.qty * m.unit_cost) / nullif(sum(m.qty), 0), 3), null
    from public.stock_moves m where m.source_type = 'stock_doc' and m.source_id = o.id group by m.item_id having sum(m.qty) < 0;
  update public.supply_requests set in_doc_id = did where id = p_id;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إضافة', 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no, 'in_doc', did));
  return did;
end $$;

create or replace function public.supply_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.supply_requests;
begin
  select * into r from public.supply_requests where id = p_id;
  if r.id is null then return; end if;
  if not public.can(r.company_id, 'supply_requests', 'delete') then raise exception 'ما عندك صلاحية'; end if;
  if r.out_doc_id is not null or r.in_doc_id is not null then raise exception 'الطلب إله سندات مخزون، ما بينحذف'; end if;
  if r.status = 'confirmed' then raise exception 'الطلب مثبت، رجّعه للانتظار أو ألغيه'; end if;
  delete from public.supply_requests where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'حذف', 'supply_requests', p_id::text, jsonb_build_object('no', r.req_no));
end $$;

-- اقتراح التعبئة للحد الأدنى: أصناف الوجهة اللي رصيدها أقل من الحد الأدنى
create or replace function public.supply_min_suggest(p_company uuid, p_from uuid, p_to uuid, p_date date default null)
returns table (item_id uuid, code text, name text, unit text, dest_qty numeric, min_qty numeric, max_qty numeric, src_qty numeric, need numeric, suggest numeric, state text)
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_date, public.local_today());
begin
  if not (public.can(p_company, 'supply_requests', 'view') or public.can(p_company, 'inventory', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  with x as (
    select i.id, i.code, i.name, i.unit, l.min_qty mn, l.max_qty mx,
           public.stock_qty(i.id, p_to, d) dq, public.stock_qty(i.id, p_from, d) sq
      from public.item_wh_limits l join public.items i on i.id = l.item_id
     where l.company_id = p_company and l.warehouse_id = p_to and l.min_qty > 0 and i.is_active and i.item_type = 'goods' and i.track_stock)
  select x.id, x.code, x.name, x.unit, x.dq, x.mn, x.mx, x.sq, greatest(x.mn - x.dq, 0),
         least(greatest(x.mn - x.dq, 0), greatest(x.sq, 0)),
         case when x.dq >= x.mn then 'covered' when x.sq <= 0 then 'unavailable' when x.sq < x.mn - x.dq then 'partial' else 'ok' end
    from x order by x.code;
end $$;

revoke execute on function public.supply_save(jsonb), public.supply_set_status(uuid, text), public.supply_issue_out(uuid), public.supply_issue_in(uuid),
  public.supply_delete(uuid), public.supply_min_suggest(uuid, uuid, uuid, date) from public, anon;
grant execute on function public.supply_save(jsonb), public.supply_set_status(uuid, text), public.supply_issue_out(uuid), public.supply_issue_in(uuid),
  public.supply_delete(uuid), public.supply_min_suggest(uuid, uuid, uuid, date) to authenticated;

-- النسخ الاحتياطي: الحدود بعد المستودعات، والطلبات قبل سندات المخزون (روابط السندات بترجع بعدين)
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'cost_centers', 'company_id = $1', 'code'),
   (5, 'currencies', 'company_id = $1', 'code'),
   (6, 'company_settings', 'company_id = $1', 'company_id'),
   (7, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (8, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (9, 'party_categories', 'company_id = $1', 'party_type, code'),
   (10, 'parties', 'company_id = $1', 'code'),
   (11, 'item_categories', 'company_id = $1', 'code'),
   (12, 'items', 'company_id = $1', 'code'),
   (13, 'promotions', 'company_id = $1', 'date_from'),
   (14, 'warehouses', 'company_id = $1', 'code'),
   (15, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (16, 'departments', 'company_id = $1', 'level, code'),
   (17, 'boms', 'company_id = $1', 'code'),
   (18, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (19, 'journal_entries', 'company_id = $1', 'created_at'),
   (20, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (21, 'invoices', 'company_id = $1', 'created_at'),
   (22, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (23, 'orders', 'company_id = $1', 'created_at'),
   (24, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (25, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (26, 'cheques', 'company_id = $1', 'created_at'),
   (27, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (28, 'supply_requests', 'company_id = $1', 'req_no'),
   (29, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (30, 'stock_docs', 'company_id = $1', 'created_at'),
   (31, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (32, 'stock_moves', 'company_id = $1', 'created_at'),
   (33, 'productions', 'company_id = $1', 'prod_no'),
   (34, 'obligations', 'company_id = $1', 'due_date'),
   (35, 'recurring_entries', 'company_id = $1', 'created_at'),
   (36, 'employees', 'company_id = $1', 'code'),
   (37, 'payroll_runs', 'company_id = $1', 'period'),
   (38, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (39, 'asset_custodians', 'company_id = $1', 'code'),
   (40, 'fixed_assets', 'company_id = $1', 'code'),
   (41, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (42, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (43, 'asset_movements', 'company_id = $1', 'mov_no'),
   (44, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (45, 'custody_docs', 'company_id = $1', 'doc_no'),
   (46, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (47, 'bank_recons', 'company_id = $1', 'created_at'),
   (48, 'bank_cleared', 'company_id = $1', 'line_id'),
   (49, 'attachments', 'company_id = $1', 'created_at'),
   (50, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;


-- #################### 36_party_fields.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 36: حقول إضافية لبطاقة العميل/المورد (مثل Stallion)
--  المرجع، الوصف #2 (اسم ثاني)، المسار (lookups kind = route)، الدائرة، العملة، وسيلة الدفع الافتراضية.
-- =====================================================================
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.lookups'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) not like '%route%' loop
    execute format('alter table public.lookups drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'lookups_kind_chk3') then
    alter table public.lookups add constraint lookups_kind_chk3
      check (kind in ('payment_method','bank','bank_branch','country','region','cheque_type','sales_rep','loyalty_type','route'));
  end if;
end $$;

alter table public.parties add column if not exists reference text;
alter table public.parties add column if not exists name2 text;
alter table public.parties add column if not exists route_id uuid references public.lookups(id) on delete set null;
alter table public.parties add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.parties add column if not exists currency text;
alter table public.parties add column if not exists payment_method_id uuid references public.lookups(id) on delete set null;

create or replace function public.ad_party_fields_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.route_id is not null and (tg_op = 'INSERT' or new.route_id is distinct from old.route_id)
     and not exists (select 1 from public.lookups where id = new.route_id and company_id = new.company_id and kind = 'route') then
    raise exception 'المسار مش من نفس الشركة';
  end if;
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id)
     and not exists (select 1 from public.lookups where id = new.payment_method_id and company_id = new.company_id and kind = 'payment_method') then
    raise exception 'وسيلة الدفع مش من نفس الشركة';
  end if;
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not exists (select 1 from public.departments where id = new.department_id and company_id = new.company_id and kind = 'sub') then
    raise exception 'الدائرة لازم تكون فرعية ومن نفس الشركة';
  end if;
  if new.currency is not null and (tg_op = 'INSERT' or new.currency is distinct from old.currency) then
    new.currency := nullif(upper(trim(new.currency)), '');
    if new.currency is not null and new.currency <> 'JOD' and not exists (select 1 from public.currencies where company_id = new.company_id and upper(code) = new.currency) then
      raise exception 'العملة «%» مش معرّفة بالشركة (مراكز الكلفة والعملات)', new.currency;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ad_party_fields_check on public.parties;
create trigger ad_party_fields_check before insert or update on public.parties for each row execute function public.ad_party_fields_check();



-- نموذج الفاتورة ثنائي اللغة: اسم وعنوان الشركة بالإنجليزي، المشروع، وتفاصيل متعددة الأسطر لكل سطر
alter table public.companies add column if not exists name_en text;
alter table public.companies add column if not exists address_en text;
alter table public.invoices add column if not exists project text;
alter table public.orders add column if not exists project text;
alter table public.invoice_lines add column if not exists details text;
alter table public.order_lines add column if not exists details text;


-- #################### 37_ask_reports.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 37: «اسأل السمو» (تقارير المبيعات بالكلام) + رصيد الأصناف للتنبيه بالفاتورة
-- =====================================================================

-- الرصيد المتوفر لأصناف بمستودع (لتنبيه «الكمية المطلوبة أكبر من المتوفرة»)
create or replace function public.items_available(p_company uuid, p_warehouse uuid, p_date date, p_items uuid[])
returns table (item_id uuid, code text, name text, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare w uuid := p_warehouse;
begin
  if not (public.can(p_company, 'items', 'view') or public.can(p_company, 'inventory', 'view') or public.can(p_company, 'sales_invoices', 'add') or public.can(p_company, 'sales_invoices', 'edit')) then
    raise exception 'ما عندك صلاحية';
  end if;
  if w is null then select x.id into w from public.warehouses x where x.company_id = p_company and x.is_active order by x.code limit 1; end if;
  if w is null or not exists (select 1 from public.warehouses x where x.id = w and x.company_id = p_company) then return; end if;
  return query
  select i.id, i.code, i.name, public.stock_qty(i.id, w, coalesce(p_date, public.local_today()))
    from public.items i where i.company_id = p_company and i.id = any(p_items) and i.item_type = 'goods' and i.track_stock;
end $$;
revoke execute on function public.items_available(uuid, uuid, date, uuid[]) from public, anon;
grant execute on function public.items_available(uuid, uuid, date, uuid[]) to authenticated;

-- تجميع المبيعات المرحّلة (البيع ناقص المرتجع) حسب بُعد، مع فلاتر.
-- p_group: customer | item | item_category | customer_category | rep | department | warehouse | month | day | none
-- p_filters: {rep_id, party_id, item_id, item_category_id, party_category_id, department_id}
create or replace function public.ask_sales(p_company uuid, p_from date, p_to date, p_group text, p_filters jsonb default '{}'::jsonb, p_top int default null, p_group2 text default null)
returns table (k1 text, k2 text, label1 text, label2 text, qty numeric, net numeric, tax numeric, invoices bigint)
language plpgsql stable security definer set search_path = public as $$
declare f jsonb := coalesce(p_filters, '{}'::jsonb);
begin
  if not (public.can(p_company, 'sales_invoices', 'view') or public.can(p_company, 'reports', 'view')) then raise exception 'ما عندك صلاحية تقارير المبيعات'; end if;
  if coalesce(p_group, 'none') not in ('customer','item','item_category','customer_category','rep','department','warehouse','month','day','none')
     or coalesce(p_group2, 'none') not in ('customer','item','item_category','customer_category','rep','department','warehouse','month','day','none') then
    raise exception 'نوع التجميع مش معروف';
  end if;
  return query
  with l as (
    select v.id inv_id, v.inv_date, v.party_id, v.party_name, v.sales_rep_id, v.department_id, coalesce(v.warehouse_id, (select w.id from public.warehouses w where w.company_id = v.company_id and w.is_active order by w.code limit 1)) wh,
           il.item_id, il.description,
           case when v.inv_type = 'sale_return' then -1 else 1 end sgn, il.qty, il.subtotal, il.tax_amount
      from public.invoices v join public.invoice_lines il on il.invoice_id = v.id
     where v.company_id = p_company and v.inv_type in ('sale','sale_return') and v.status = 'posted'
       and v.inv_date between p_from and p_to
       and (f ->> 'rep_id' is null or v.sales_rep_id = (f ->> 'rep_id')::uuid)
       and (f ->> 'party_id' is null or v.party_id = (f ->> 'party_id')::uuid)
       and (f ->> 'department_id' is null or v.department_id = (f ->> 'department_id')::uuid)
       and (f ->> 'item_id' is null or il.item_id = (f ->> 'item_id')::uuid)
       and (f ->> 'item_category_id' is null or exists (select 1 from public.items i where i.id = il.item_id and i.category_id = (f ->> 'item_category_id')::uuid))
       and (f ->> 'party_category_id' is null or exists (select 1 from public.parties p where p.id = v.party_id and p.category_id = (f ->> 'party_category_id')::uuid))
  ), d as (
    select l.*, p.name pname, p.code pcode, p.category_id pcat, i.name iname, i.code icode, i.category_id icat
      from l left join public.parties p on p.id = l.party_id left join public.items i on i.id = l.item_id
  ), g as (
    select
      case p_group when 'customer' then coalesce(d.party_id::text, 'cash:' || coalesce(d.party_name, '')) when 'item' then coalesce(d.item_id::text, 'd:' || coalesce(d.description, ''))
        when 'item_category' then coalesce(d.icat::text, '-') when 'customer_category' then coalesce(d.pcat::text, '-') when 'rep' then coalesce(d.sales_rep_id::text, '-')
        when 'department' then coalesce(d.department_id::text, '-') when 'warehouse' then d.wh::text when 'month' then to_char(d.inv_date, 'YYYY-MM') when 'day' then d.inv_date::text else 'all' end a1,
      case p_group2 when 'customer' then coalesce(d.party_id::text, 'cash:' || coalesce(d.party_name, '')) when 'item' then coalesce(d.item_id::text, 'd:' || coalesce(d.description, ''))
        when 'item_category' then coalesce(d.icat::text, '-') when 'customer_category' then coalesce(d.pcat::text, '-') when 'rep' then coalesce(d.sales_rep_id::text, '-')
        when 'department' then coalesce(d.department_id::text, '-') when 'warehouse' then d.wh::text when 'month' then to_char(d.inv_date, 'YYYY-MM') when 'day' then d.inv_date::text else '' end a2,
      d.*
      from d
  ), s as (
    select a1, a2, sum(sgn * g.qty) q, sum(sgn * g.subtotal) n, sum(sgn * g.tax_amount) t, count(distinct inv_id) c from g group by a1, a2
  ), lab as (
    select s.*,
      (select case p_group
          when 'customer' then coalesce((select x.name from public.parties x where x.id::text = s.a1 and x.company_id = p_company), nullif(replace(s.a1, 'cash:', ''), ''), 'زبون نقدي')
          when 'item' then coalesce((select x.code || ' — ' || x.name from public.items x where x.id::text = s.a1 and x.company_id = p_company), nullif(replace(s.a1, 'd:', ''), ''), 'بدون صنف')
          when 'item_category' then coalesce((select x.name from public.item_categories x where x.id::text = s.a1 and x.company_id = p_company), 'بدون فئة')
          when 'customer_category' then coalesce((select x.name from public.party_categories x where x.id::text = s.a1 and x.company_id = p_company), 'بدون فئة')
          when 'rep' then coalesce((select x.name from public.lookups x where x.id::text = s.a1 and x.company_id = p_company), 'بدون مندوب')
          when 'department' then coalesce((select x.name from public.departments x where x.id::text = s.a1 and x.company_id = p_company), 'بدون دائرة')
          when 'warehouse' then coalesce((select x.name from public.warehouses x where x.id::text = s.a1 and x.company_id = p_company), '')
          when 'none' then 'الإجمالي' else s.a1 end) l1,
      (select case p_group2
          when 'customer' then coalesce((select x.name from public.parties x where x.id::text = s.a2 and x.company_id = p_company), nullif(replace(s.a2, 'cash:', ''), ''), 'زبون نقدي')
          when 'item' then coalesce((select x.code || ' — ' || x.name from public.items x where x.id::text = s.a2 and x.company_id = p_company), nullif(replace(s.a2, 'd:', ''), ''), 'بدون صنف')
          when 'item_category' then coalesce((select x.name from public.item_categories x where x.id::text = s.a2 and x.company_id = p_company), 'بدون فئة')
          when 'customer_category' then coalesce((select x.name from public.party_categories x where x.id::text = s.a2 and x.company_id = p_company), 'بدون فئة')
          when 'rep' then coalesce((select x.name from public.lookups x where x.id::text = s.a2 and x.company_id = p_company), 'بدون مندوب')
          when 'department' then coalesce((select x.name from public.departments x where x.id::text = s.a2 and x.company_id = p_company), 'بدون دائرة')
          when 'warehouse' then coalesce((select x.name from public.warehouses x where x.id::text = s.a2 and x.company_id = p_company), '')
          else s.a2 end) l2
      from s
  )
  select a1, a2, l1, l2, round(q, 3), round(n, 3), round(t, 3), c from lab
   order by case when p_group in ('month', 'day') then a1 end, n desc nulls last
   limit coalesce(p_top, 5000);
end $$;
revoke execute on function public.ask_sales(uuid, date, date, text, jsonb, int, text) from public, anon;
grant execute on function public.ask_sales(uuid, date, date, text, jsonb, int, text) to authenticated;

-- سجل أسئلة المستخدم (لكل شركة)
create table if not exists public.ask_history (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id    uuid not null default auth.uid(),
  question   text not null check (length(question) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists ask_history_user on public.ask_history (user_id, company_id, created_at desc);
alter table public.ask_history enable row level security;
grant select, insert, delete on public.ask_history to authenticated;
drop policy if exists ah_select on public.ask_history;
create policy ah_select on public.ask_history for select to authenticated using (user_id = auth.uid() and public.has_company(company_id));
drop policy if exists ah_insert on public.ask_history;
create policy ah_insert on public.ask_history for insert to authenticated with check (user_id = auth.uid() and public.has_company(company_id));
drop policy if exists ah_delete on public.ask_history;
create policy ah_delete on public.ask_history for delete to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
--  حذف الشركة: مسموح بس إذا ما فيها ولا حركة (قيود، فواتير، سندات مخزون، شيكات، رواتب، أصول، طلبات…)
-- ---------------------------------------------------------------------
create or replace function public.company_activity_raw(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := '{}'::jsonb; n bigint; t record;
begin
  for t in select * from (values ('journal_entries', 'قيود وسندات'), ('invoices', 'فواتير'), ('stock_docs', 'سندات مخزون'), ('cheques', 'شيكات'),
             ('payroll_runs', 'مسيّرات رواتب'), ('depreciation_runs', 'دورات استهلاك'), ('orders', 'طلبات بيع/شراء'), ('asset_movements', 'حركات أصول'),
             ('custody_docs', 'مستندات عهد'), ('supply_requests', 'طلبات تزويد'), ('service_tickets', 'بطاقات صيانة'), ('productions', 'أوامر إنتاج'),
             ('stock_moves', 'حركات مخزون')) v(tbl, label) loop
    if to_regclass('public.' || t.tbl) is null then continue; end if;
    execute format('select count(*) from public.%I where company_id = $1', t.tbl) into n using p_company;
    if n > 0 then r := r || jsonb_build_object(t.label, n); end if;
  end loop;
  return r;
end $$;
revoke execute on function public.company_activity_raw(uuid) from public, anon, authenticated;
create or replace function public.company_activity(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  return public.company_activity_raw(p_company);
end $$;
revoke execute on function public.company_activity(uuid) from public, anon;
grant execute on function public.company_activity(uuid) to authenticated;

create or replace function public.ab_company_delete_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare a jsonb;
begin
  if public.is_internal() then return old; end if;
  a := public.company_activity_raw(old.id);
  if a <> '{}'::jsonb then
    raise exception 'الشركة «%» فيها حركات (%)، ما بتنحذف. أوقفها بدل الحذف', old.name,
      (select string_agg(key || ': ' || value, '، ') from jsonb_each_text(a));
  end if;
  return old;
end $$;
drop trigger if exists ab_company_delete_guard on public.companies;
create trigger ab_company_delete_guard before delete on public.companies for each row execute function public.ab_company_delete_guard();

-- سطر الفاتورة: الصنف لازم من نفس الشركة
create or replace function public.ad_invoice_line_item_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.item_id is not null and (tg_op = 'INSERT' or new.item_id is distinct from old.item_id)
     and not exists (select 1 from public.items i join public.invoices v on v.id = new.invoice_id where i.id = new.item_id and i.company_id = v.company_id) then
    raise exception 'الصنف مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_invoice_line_item_check on public.invoice_lines;
create trigger ad_invoice_line_item_check before insert or update on public.invoice_lines for each row execute function public.ad_invoice_line_item_check();


-- #################### 38_doc_freeze.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 38: تجميد المستندات
--  المستند المجمّد ما بينعدّل ولا بينحذف ولا بيترحّل (ولا سطوره) لحد ما ينفك تجميده.
--  التجميد وفكّه من set_doc_frozen بس، بصلاحية edit على شاشة المستند.
-- =====================================================================
alter table public.journal_entries add column if not exists is_frozen boolean not null default false;
alter table public.invoices        add column if not exists is_frozen boolean not null default false;
alter table public.stock_docs      add column if not exists is_frozen boolean not null default false;
alter table public.orders          add column if not exists is_frozen boolean not null default false;

-- الرأس: الحقل is_frozen من الدالة بس، والمجمّد ما بيتغيّر/بينحذف (حتى الترحيل الداخلي)
create or replace function public.ab_doc_frozen_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare flip boolean := coalesce(current_setting('sumou.freeze', true), '') = public.internal_token();
begin
  if tg_op = 'INSERT' then
    if not public.is_internal() then new.is_frozen := false; end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.is_frozen then raise exception 'المستند مجمّد، فك التجميد أول عشان تحذفه'; end if;
    return old;
  end if;
  if new.is_frozen is distinct from old.is_frozen and not flip and not public.is_internal() then
    raise exception 'التجميد بيصير من كبسة «تجميد» بس';
  end if;
  if old.is_frozen and new.is_frozen and not flip then
    raise exception 'المستند مجمّد، ما بينعدّل ولا بيترحّل. فك التجميد أول';
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['journal_entries','invoices','stock_docs','orders'] loop
    execute format('drop trigger if exists ab_doc_frozen_guard on public.%I', t);
    execute format('create trigger ab_doc_frozen_guard before insert or update or delete on public.%I for each row execute function public.ab_doc_frozen_guard()', t);
  end loop;
end $$;

-- السطور: ممنوعة إذا الرأس مجمّد
create or replace function public.ab_doc_lines_frozen() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid; fr boolean;
begin
  if public.is_internal() then return case when tg_op = 'DELETE' then old else new end; end if;
  -- النقل من مستند مجمّد لمستند ثاني ممنوع كمان
  if tg_op = 'UPDATE' then
    if tg_table_name = 'journal_lines' then
      if old.entry_id is distinct from new.entry_id then select is_frozen into fr from public.journal_entries where id = old.entry_id; end if;
    elsif tg_table_name = 'invoice_lines' then
      if old.invoice_id is distinct from new.invoice_id then select is_frozen into fr from public.invoices where id = old.invoice_id; end if;
    elsif tg_table_name = 'stock_doc_lines' then
      if old.doc_id is distinct from new.doc_id then select is_frozen into fr from public.stock_docs where id = old.doc_id; end if;
    else
      if old.order_id is distinct from new.order_id then select is_frozen into fr from public.orders where id = old.order_id; end if;
    end if;
    if coalesce(fr, false) then raise exception 'المستند مجمّد، ما بتتعدّل سطوره'; end if;
  end if;
  if tg_table_name = 'journal_lines' then
    pid := case when tg_op = 'DELETE' then old.entry_id else new.entry_id end;
    select is_frozen into fr from public.journal_entries where id = pid;
  elsif tg_table_name = 'invoice_lines' then
    pid := case when tg_op = 'DELETE' then old.invoice_id else new.invoice_id end;
    select is_frozen into fr from public.invoices where id = pid;
  elsif tg_table_name = 'stock_doc_lines' then
    pid := case when tg_op = 'DELETE' then old.doc_id else new.doc_id end;
    select is_frozen into fr from public.stock_docs where id = pid;
  else
    pid := case when tg_op = 'DELETE' then old.order_id else new.order_id end;
    select is_frozen into fr from public.orders where id = pid;
  end if;
  if coalesce(fr, false) then raise exception 'المستند مجمّد، ما بتتعدّل سطوره'; end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
do $$ declare t text; begin
  foreach t in array array['journal_lines','invoice_lines','stock_doc_lines','order_lines'] loop
    execute format('drop trigger if exists ab_doc_lines_frozen on public.%I', t);
    execute format('create trigger ab_doc_lines_frozen before insert or update or delete on public.%I for each row execute function public.ab_doc_lines_frozen()', t);
  end loop;
end $$;

create or replace function public.set_doc_frozen(p_table text, p_id uuid, p_frozen boolean) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid; scr text; t text; st text; no text;
begin
  if p_table = 'journal_entries' then select company_id, public.entry_screen(entry_type), coalesce(doc_code, entry_no::text) into cid, scr, no from public.journal_entries where id = p_id;
  elsif p_table = 'invoices' then select company_id, public.invoice_screen(inv_type), coalesce(doc_code, inv_no::text) into cid, scr, no from public.invoices where id = p_id;
  elsif p_table = 'stock_docs' then select company_id, 'inventory', coalesce(doc_code, doc_no::text) into cid, scr, no from public.stock_docs where id = p_id;
  elsif p_table = 'orders' then select company_id, case order_type when 'sales_order' then 'sales_orders' else 'purchase_orders' end, order_no::text into cid, scr, no from public.orders where id = p_id;
  else raise exception 'نوع مستند مش معروف'; end if;
  if cid is null then raise exception 'المستند مش موجود'; end if;
  if not public.can(cid, scr, 'edit') then raise exception 'ما عندك صلاحية تجميد هالمستند'; end if;
  -- داخلي عشان أقفال المستند المرحّل ما تمنع تغيير علامة التجميد بس
  perform set_config('sumou.freeze', public.internal_token(), true);
  perform set_config('sumou.internal', public.internal_token(), true);
  execute format('update public.%I set is_frozen = $1 where id = $2', p_table) using p_frozen, p_id;
  perform set_config('sumou.internal', '', true);
  perform set_config('sumou.freeze', '', true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), cid, 'تعديل', p_table, p_id::text, jsonb_build_object('no', no, 'frozen', p_frozen));
end $$;
revoke execute on function public.set_doc_frozen(text, uuid, boolean) from public, anon;
grant execute on function public.set_doc_frozen(text, uuid, boolean) to authenticated;


-- #################### 39_loyalty_tiers.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 39: مراتب الولاء والاسترداد النقدي (Cashback)
--  المرتبة حسب مشتريات الزبون آخر 12 شهر، وكل مرتبة إلها نسبة استرداد.
--  الاسترداد بينحسب على كل فاتورة بيع مرحّلة (ناقص المرتجع) بنسبة مرتبة الزبون وقتها.
--  الصرف (استخدام الرصيد) بقيد: مدين مصروف الاسترداد، دائن حساب الزبون.
--  الصلاحية: شاشة marketing (العرض view، المراتب edit، الصرف post).
-- =====================================================================
create table if not exists public.loyalty_tiers (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  rank         int not null,
  name         text not null,
  min_spend    numeric(18,3) not null default 0 check (min_spend >= 0),
  cashback_pct numeric(6,3) not null default 0 check (cashback_pct >= 0 and cashback_pct <= 50),
  color        text,
  is_active    boolean not null default true,
  unique (company_id, rank)
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'loyalty_tiers_color_chk') then
    alter table public.loyalty_tiers add constraint loyalty_tiers_color_chk check (color is null or color ~ '^#[0-9A-Fa-f]{6}$');
  end if;
end $$;
alter table public.loyalty_tiers enable row level security;
grant select, insert, update, delete on public.loyalty_tiers to authenticated;
drop policy if exists lt_select on public.loyalty_tiers;
create policy lt_select on public.loyalty_tiers for select to authenticated using (public.can(company_id, 'marketing', 'view'));
drop policy if exists lt_write on public.loyalty_tiers;
create policy lt_write on public.loyalty_tiers for all to authenticated using (public.can(company_id, 'marketing', 'edit')) with check (public.can(company_id, 'marketing', 'edit'));

alter table public.company_settings add column if not exists cashback_account_id uuid references public.accounts(id) on delete set null;

create table if not exists public.loyalty_redemptions (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  party_id    uuid not null references public.parties(id),
  red_date    date not null,
  amount      numeric(18,3) not null check (amount > 0),
  entry_id    uuid references public.journal_entries(id) on delete set null,
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
alter table public.loyalty_redemptions enable row level security;
revoke insert, update, delete on public.loyalty_redemptions from authenticated;
grant select on public.loyalty_redemptions to authenticated;
drop policy if exists lr_select on public.loyalty_redemptions;
create policy lr_select on public.loyalty_redemptions for select to authenticated using (public.can(company_id, 'marketing', 'view'));

-- المرتبة لمبلغ مشتريات
create or replace function public.loyalty_tier_for(p_company uuid, p_spend numeric) returns public.loyalty_tiers
language sql stable security definer set search_path = public as $$
  select * from public.loyalty_tiers where company_id = p_company and is_active and min_spend <= coalesce(p_spend, 0) order by min_spend desc, rank desc limit 1;
$$;
revoke execute on function public.loyalty_tier_for(uuid, numeric) from public, anon, authenticated;

-- حالة الزبائن: مشتريات 12 شهر، المرتبة الحالية والجاية، المكتسب والمصروف والرصيد
create or replace function public.loyalty_cashback(p_company uuid, p_party uuid default null, p_date date default null)
returns table (party_id uuid, spend_12m numeric, tier_id uuid, tier_name text, tier_pct numeric, next_name text, next_min numeric, earned numeric, redeemed numeric, balance numeric)
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_date, public.local_today());
begin
  if not public.can(p_company, 'marketing', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query
  with inv as (   -- فواتير البيع والمرتجع المرحّلة لحاملي البطاقات
    select v.party_id pid, v.inv_date, case when v.inv_type = 'sale_return' then -v.subtotal else v.subtotal end net
      from public.invoices v join public.parties p on p.id = v.party_id
     where v.company_id = p_company and v.status = 'posted' and v.inv_type in ('sale','sale_return') and v.inv_date <= d
       and p.party_type = 'customer' and p.loyalty_type_id is not null and (p_party is null or p.id = p_party)
  ), win as (     -- مشتريات الزبون بالسنة اللي قبل كل فاتورة (نافذة متحركة)
    select i.pid, i.net, coalesce(sum(i.net) over (partition by i.pid order by i.inv_date range between interval '364 days' preceding and interval '1 day' preceding), 0) prior
      from inv i
  ), earn as (    -- كل فاتورة بنسبة مرتبة الزبون وقتها
    select w.pid, w.net * coalesce(t.cashback_pct, 0) / 100 amt
      from win w left join lateral (select x.cashback_pct from public.loyalty_tiers x where x.company_id = p_company and x.is_active and x.min_spend <= w.prior
                                     order by x.min_spend desc, x.rank desc limit 1) t on true
  ), base as (
    select p.id pid,
           (select coalesce(sum(i.net), 0) from inv i where i.pid = p.id and i.inv_date > d - 365) s12,
           (select coalesce(sum(e.amt), 0) from earn e where e.pid = p.id) er,
           (select coalesce(sum(r.amount), 0) from public.loyalty_redemptions r where r.party_id = p.id and r.red_date <= d) rd
      from public.parties p
     where p.company_id = p_company and p.party_type = 'customer' and p.loyalty_type_id is not null and (p_party is null or p.id = p_party)
  )
  select b.pid, round(b.s12, 3), t.id, t.name, t.cashback_pct,
         (select n.name from public.loyalty_tiers n where n.company_id = p_company and n.is_active and n.min_spend > b.s12 order by n.min_spend limit 1),
         (select n.min_spend from public.loyalty_tiers n where n.company_id = p_company and n.is_active and n.min_spend > b.s12 order by n.min_spend limit 1),
         round(greatest(b.er, 0), 3), round(b.rd, 3), round(greatest(b.er, 0) - b.rd, 3)
    from base b left join lateral (select * from public.loyalty_tier_for(p_company, b.s12)) t on true;
end $$;
revoke execute on function public.loyalty_cashback(uuid, uuid, date) from public, anon;
grant execute on function public.loyalty_cashback(uuid, uuid, date) to authenticated;

-- صرف رصيد الاسترداد للزبون (بيخفّض ذمته): مدين مصروف الاسترداد، دائن حساب الزبون
create or replace function public.loyalty_redeem(p_party uuid, p_amount numeric, p_date date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare p public.parties; st public.company_settings; bal numeric; fy uuid; eid uuid; d date := coalesce(p_date, public.local_today()); rid uuid;
  prev text := current_setting('sumou.internal', true); amt numeric := round(coalesce(p_amount, 0), 3);
begin
  select * into p from public.parties where id = p_party for update;
  if p.id is null or p.party_type <> 'customer' then raise exception 'الزبون مش موجود'; end if;
  if not public.can(p.company_id, 'marketing', 'post') then raise exception 'ما عندك صلاحية صرف الاسترداد النقدي'; end if;
  if amt <= 0 then raise exception 'المبلغ لازم أكبر من صفر'; end if;
  if exists (select 1 from public.loyalty_redemptions where party_id = p.id and red_date > d) then raise exception 'في صرف بتاريخ أحدث؛ اختار تاريخ بعده'; end if;
  -- المكتسب لتاريخ الصرف ناقص كل المصروف (بأي تاريخ)، وكمان الرصيد لليوم
  select earned into bal from public.loyalty_cashback(p.company_id, p.id, d);
  bal := coalesce(bal, 0) - coalesce((select sum(amount) from public.loyalty_redemptions where party_id = p.id), 0);
  bal := least(bal, coalesce((select balance from public.loyalty_cashback(p.company_id, p.id, greatest(d, public.local_today()))), 0));
  if bal < amt then raise exception 'رصيد الاسترداد (%) أقل من المبلغ', round(greatest(bal, 0), 3); end if;
  select * into st from public.company_settings where company_id = p.company_id;
  if st.cashback_account_id is null then raise exception 'حدّد حساب «مصروف الاسترداد النقدي» بحسابات الربط'; end if;
  if not exists (select 1 from public.accounts where id = st.cashback_account_id and company_id = p.company_id and not is_group and is_active and category = 'expenses') then
    raise exception 'حساب الاسترداد النقدي لازم يكون حساب مصاريف فرعي وفعّال من نفس الشركة';
  end if;
  if p.account_id is null then raise exception 'الزبون ما إله حساب'; end if;
  select id into fy from public.fiscal_years where company_id = p.company_id and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بالتاريخ'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, status)
  values (p.company_id, fy, 'journal', d, 'صرف استرداد نقدي للزبون ' || p.name || coalesce(' — ' || nullif(trim(p_notes), ''), ''), 'استرداد نقدي', 'draft') returning id into eid;
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, 1, st.cashback_account_id, 'استرداد نقدي ' || p.name, amt, 0);
  insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, party_id) values (eid, 2, p.account_id, 'استرداد نقدي', 0, amt, p.id);
  update public.journal_entries set status = 'posted', total = amt, posted_by = auth.uid(), posted_at = now() where id = eid;
  insert into public.loyalty_redemptions (company_id, party_id, red_date, amount, entry_id, notes) values (p.company_id, p.id, d, amt, eid, nullif(trim(p_notes), '')) returning id into rid;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), p.company_id, 'ترحيل', 'loyalty_redemptions', rid::text, jsonb_build_object('party', p.name, 'amount', amt));
  return rid;
end $$;
revoke execute on function public.loyalty_redeem(uuid, numeric, date, text) from public, anon;
grant execute on function public.loyalty_redeem(uuid, numeric, date, text) to authenticated;

-- إلغاء صرف: قيد عكسي وبينحذف السطر من السجل
create or replace function public.loyalty_redeem_cancel(p_id uuid, p_date date default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.loyalty_redemptions; prev text := current_setting('sumou.internal', true);
begin
  select * into r from public.loyalty_redemptions where id = p_id for update;
  if r.id is null then raise exception 'مش موجود'; end if;
  if not public.can(r.company_id, 'marketing', 'post') then raise exception 'ما عندك صلاحية'; end if;
  if r.entry_id is not null and exists (select 1 from public.journal_entries where id = r.entry_id and status = 'posted') then
    perform set_config('sumou.loyalty', public.internal_token(), true);
    perform public.reverse_internal(r.entry_id, greatest(coalesce(p_date, public.local_today()), r.red_date), 'إلغاء صرف استرداد نقدي');
    perform set_config('sumou.loyalty', '', true);
    perform set_config('sumou.internal', coalesce(prev, ''), true);
  end if;
  delete from public.loyalty_redemptions where id = p_id;
  insert into public.activity_log (user_id, company_id, action, entity, entity_id, details)
  values (auth.uid(), r.company_id, 'إلغاء', 'loyalty_redemptions', p_id::text, jsonb_build_object('amount', r.amount));
end $$;
revoke execute on function public.loyalty_redeem_cancel(uuid, date) from public, anon;
grant execute on function public.loyalty_redeem_cancel(uuid, date) to authenticated;

-- قيد الاسترداد ما بينعكس/بينلغى ترحيله من شاشة القيود (من شاشة الولاء بس)
create or replace function public.ab_loyalty_entry_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('sumou.loyalty', true), '') = public.internal_token() then return new; end if;
  if old.status = 'posted' and new.status is distinct from old.status
     and exists (select 1 from public.loyalty_redemptions where entry_id = old.id) then
    raise exception 'قيد الاسترداد النقدي بينلغى من شاشة بطاقات الولاء';
  end if;
  return new;
end $$;
drop trigger if exists ab_loyalty_entry_guard on public.journal_entries;
create trigger ab_loyalty_entry_guard before update of status on public.journal_entries for each row execute function public.ab_loyalty_entry_guard();

-- النسخ الاحتياطي
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'cost_centers', 'company_id = $1', 'code'),
   (5, 'currencies', 'company_id = $1', 'code'),
   (6, 'company_settings', 'company_id = $1', 'company_id'),
   (7, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (8, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (9, 'party_categories', 'company_id = $1', 'party_type, code'),
   (10, 'parties', 'company_id = $1', 'code'),
   (11, 'item_categories', 'company_id = $1', 'code'),
   (12, 'items', 'company_id = $1', 'code'),
   (13, 'promotions', 'company_id = $1', 'date_from'),
   (14, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (15, 'warehouses', 'company_id = $1', 'code'),
   (16, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (17, 'departments', 'company_id = $1', 'level, code'),
   (18, 'boms', 'company_id = $1', 'code'),
   (19, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (20, 'journal_entries', 'company_id = $1', 'created_at'),
   (21, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (22, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (23, 'invoices', 'company_id = $1', 'created_at'),
   (24, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (25, 'orders', 'company_id = $1', 'created_at'),
   (26, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (27, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (28, 'cheques', 'company_id = $1', 'created_at'),
   (29, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (30, 'supply_requests', 'company_id = $1', 'req_no'),
   (31, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (32, 'stock_docs', 'company_id = $1', 'created_at'),
   (33, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (34, 'stock_moves', 'company_id = $1', 'created_at'),
   (35, 'productions', 'company_id = $1', 'prod_no'),
   (36, 'obligations', 'company_id = $1', 'due_date'),
   (37, 'recurring_entries', 'company_id = $1', 'created_at'),
   (38, 'employees', 'company_id = $1', 'code'),
   (39, 'payroll_runs', 'company_id = $1', 'period'),
   (40, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (41, 'asset_custodians', 'company_id = $1', 'code'),
   (42, 'fixed_assets', 'company_id = $1', 'code'),
   (43, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (44, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (45, 'asset_movements', 'company_id = $1', 'mov_no'),
   (46, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (47, 'custody_docs', 'company_id = $1', 'doc_no'),
   (48, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (49, 'bank_recons', 'company_id = $1', 'created_at'),
   (50, 'bank_cleared', 'company_id = $1', 'line_id'),
   (51, 'attachments', 'company_id = $1', 'created_at'),
   (52, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;


-- #################### 40_rep_visits.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 40: تطبيق المندوب (الزيارات ودفعات العملاء من الجوال)
--  زيارة: بداية/نهاية بالوقت والموقع، ملاحظات ومصاريف مواصلات، وصور إثبات (المرفقات entity = 'visit').
--  دفعة عميل: نقد/تحويل = سند قبض (مسودة، أو مرحّل لمين إله ترحيل)، شيكات = register_cheque.
--  الصلاحية: شاشة rep_visits (قسم المبيعات). المندوب بيشوف زياراته؛ المشرف (edit) بيشوف الكل.
-- =====================================================================
create or replace function public.screen_module(s text) returns text
language sql immutable as $$
  select case
    when s in ('customers','sales_invoices','sales_orders','pos','rep_visits')  then 'sales'
    when s in ('suppliers','purchase_invoices','purchase_orders')   then 'purchases'
    when s in ('inventory','supply_requests')                       then 'inventory'
    when s in ('cheques','bank_recon')                              then 'banking'
    when s = 'payroll'                                              then 'payroll'
    when s in ('fixed_assets','asset_custody')                      then 'assets'
    when s = 'marketing'                                            then 'marketing'
    when s = 'manufacturing'                                        then 'manufacturing'
    when s = 'maintenance'                                          then 'maintenance'
    when s = 'obligations'                                          then 'office'
    else 'core' end;
$$;

create table if not exists public.sales_visits (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id) on delete cascade,
  user_id      uuid not null default auth.uid(),
  rep_id       uuid references public.lookups(id) on delete set null,
  party_id     uuid not null references public.parties(id),
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  start_lat    numeric(10,6), start_lng numeric(10,6),
  end_lat      numeric(10,6), end_lng numeric(10,6),
  purpose      text,
  notes        text,
  outcome      text,
  taxi_fee     numeric(18,3) not null default 0 check (taxi_fee >= 0),
  parking_fee  numeric(18,3) not null default 0 check (parking_fee >= 0),
  status       text not null default 'open' check (status in ('open','closed','cancelled'))
);
create index if not exists sales_visits_user on public.sales_visits (company_id, user_id, started_at desc);
create unique index if not exists sales_visits_one_open on public.sales_visits (company_id, user_id) where status = 'open';
alter table public.sales_visits enable row level security;
revoke insert, update, delete on public.sales_visits from authenticated;
grant select on public.sales_visits to authenticated;
drop policy if exists sv_select on public.sales_visits;
create policy sv_select on public.sales_visits for select to authenticated
  using ((user_id = auth.uid() and public.can(company_id, 'rep_visits', 'view')) or public.can(company_id, 'rep_visits', 'edit'));

alter table public.journal_entries add column if not exists visit_id uuid references public.sales_visits(id) on delete set null;
alter table public.cheques add column if not exists visit_id uuid references public.sales_visits(id) on delete set null;

create or replace function public.visit_start(p_company uuid, p_party uuid, p_lat numeric default null, p_lng numeric default null, p_purpose text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare vid uuid; rep uuid;
begin
  if not public.can(p_company, 'rep_visits', 'add') then raise exception 'ما عندك صلاحية تسجيل زيارات'; end if;
  if not exists (select 1 from public.parties where id = p_party and company_id = p_company and party_type = 'customer' and is_active) then raise exception 'العميل مش موجود'; end if;
  if exists (select 1 from public.sales_visits where company_id = p_company and user_id = auth.uid() and status = 'open') then
    raise exception 'عندك زيارة مفتوحة، أنهيها أول';
  end if;
  if (p_lat is null) <> (p_lng is null) or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then raise exception 'الموقع مش صحيح'; end if;
  select sales_rep_id into rep from public.parties where id = p_party;
  insert into public.sales_visits (company_id, party_id, rep_id, start_lat, start_lng, purpose)
  values (p_company, p_party, rep, p_lat, p_lng, nullif(trim(p_purpose), '')) returning id into vid;
  return vid;
exception when unique_violation then raise exception 'عندك زيارة مفتوحة، أنهيها أول';
end $$;

create or replace function public.visit_end(p_id uuid, p_lat numeric default null, p_lng numeric default null, p_notes text default null,
  p_outcome text default null, p_taxi numeric default 0, p_parking numeric default 0) returns void
language plpgsql security definer set search_path = public as $$
declare v public.sales_visits;
begin
  select * into v from public.sales_visits where id = p_id for update;
  if v.id is null then raise exception 'الزيارة مش موجودة'; end if;
  if not ((v.user_id = auth.uid() and public.can(v.company_id, 'rep_visits', 'add')) or public.can(v.company_id, 'rep_visits', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  if v.status <> 'open' then raise exception 'الزيارة منتهية'; end if;
  if coalesce(p_taxi, 0) < 0 or coalesce(p_parking, 0) < 0 or coalesce(p_taxi, 0) > 1000 or coalesce(p_parking, 0) > 1000 then raise exception 'المصاريف مش منطقية'; end if;
  if (p_lat is null) <> (p_lng is null) or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then raise exception 'الموقع مش صحيح'; end if;
  update public.sales_visits set ended_at = now(), end_lat = p_lat, end_lng = p_lng, notes = nullif(trim(p_notes), ''), outcome = nullif(trim(p_outcome), ''),
         taxi_fee = round(coalesce(p_taxi, 0), 3), parking_fee = round(coalesce(p_parking, 0), 3), status = 'closed' where id = p_id;
end $$;

create or replace function public.visit_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.sales_visits;
begin
  select * into v from public.sales_visits where id = p_id for update;
  if v.id is null then raise exception 'الزيارة مش موجودة'; end if;
  if not ((v.user_id = auth.uid() and public.can(v.company_id, 'rep_visits', 'add') and v.status = 'open') or public.can(v.company_id, 'rep_visits', 'edit')) then raise exception 'ما عندك صلاحية'; end if;
  update public.sales_visits set status = 'cancelled', ended_at = coalesce(ended_at, now()) where id = p_id;
end $$;

-- دفعة عميل من الجوال. p = {company_id, party_id, kind: cash|transfer|cheques, amount, account_id (للنقد/التحويل أو وسيلة الدفع), pay_date, reference, notes, visit_id,
--   cheques:[{cheque_no, amount, due_date, bank_name, drawer_name}]}
create or replace function public.mobile_payment(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; pa public.parties; k text := p ->> 'kind'; d date := coalesce(nullif(p ->> 'pay_date', '')::date, public.local_today());
  vid uuid := nullif(p ->> 'visit_id', '')::uuid; acc uuid := nullif(p ->> 'account_id', '')::uuid; amt numeric; fy uuid; eid uuid; c jsonb; chs uuid[] := '{}'; ch uuid; tot numeric := 0; posted boolean := false;
  prev text := current_setting('sumou.internal', true);
begin
  select * into pa from public.parties where id = nullif(p ->> 'party_id', '')::uuid and company_id = cid and party_type = 'customer' and is_active;
  if pa.id is null then raise exception 'اختار العميل'; end if;
  if not public.tenant_writable() then raise exception 'الاشتراك منتهي'; end if;
  if vid is not null and not exists (select 1 from public.sales_visits where id = vid and company_id = cid and party_id = pa.id and user_id = auth.uid()) then
    raise exception 'الزيارة مش لهالعميل';
  end if;
  if coalesce((select (pos ->> 'require_visit')::boolean from public.company_settings where company_id = cid), false)
     and not exists (select 1 from public.sales_visits where id = vid and status = 'open') and not public.can(cid, 'rep_visits', 'edit') then
    raise exception 'لازم تكون بزيارة مفتوحة لنفس العميل عشان تسجّل دفعة';
  end if;
  if k in ('cash', 'transfer') then
    if not public.can(cid, 'receipt_vouchers', 'add') then raise exception 'ما عندك صلاحية سندات القبض'; end if;
    amt := round(coalesce(nullif(p ->> 'amount', '')::numeric, 0), 3);
    if amt <= 0 then raise exception 'المبلغ لازم أكبر من صفر'; end if;
    if acc is null or not exists (select 1 from public.accounts where id = acc and company_id = cid and not is_group and account_type in ('cash', 'bank')) then
      raise exception 'اختار الصندوق أو البنك';
    end if;
    if pa.account_id is null then raise exception 'العميل ما إله حساب'; end if;
    select id into fy from public.fiscal_years where company_id = cid and d between start_date and end_date and not is_closed order by start_date desc limit 1;
    if fy is null then raise exception 'ما في سنة مالية مفتوحة بالتاريخ'; end if;
    perform set_config('sumou.visit', public.internal_token(), true);
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference, party_name, cash_account_id, status, visit_id)
    values (cid, fy, 'receipt', d, coalesce(nullif(trim(p ->> 'notes'), ''), 'دفعة من ' || pa.name) || case when k = 'transfer' then ' (تحويل)' else '' end,
            nullif(trim(p ->> 'reference'), ''), pa.name, acc, 'draft', vid) returning id into eid;
    perform set_config('sumou.visit', '', true);
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit) values (eid, 1, acc, 'دفعة ' || pa.name, amt, 0);
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit, party_id) values (eid, 2, pa.account_id, 'دفعة', 0, amt, pa.id);
    if public.can(cid, 'receipt_vouchers', 'post') then perform public.post_entry(eid); posted := true; end if;
    tot := amt;
  elsif k = 'cheques' then
    if coalesce(jsonb_typeof(p -> 'cheques'), '') <> 'array' or jsonb_array_length(p -> 'cheques') = 0 then raise exception 'أضف شيك واحد على الأقل'; end if;
    if jsonb_array_length(p -> 'cheques') > 50 then raise exception 'شيكات كثير'; end if;
    for c in select * from jsonb_array_elements(p -> 'cheques') loop
      if nullif(trim(c ->> 'cheque_no'), '') is null or nullif(c ->> 'due_date', '') is null then raise exception 'رقم الشيك وتاريخ الاستحقاق مطلوبين'; end if;
      ch := public.register_cheque(jsonb_build_object('company_id', cid, 'direction', 'in', 'party_id', pa.id, 'cheque_no', trim(c ->> 'cheque_no'), 'amount', c ->> 'amount',
              'due_date', c ->> 'due_date', 'issue_date', d, 'bank_name', c ->> 'bank_name', 'drawer_name', coalesce(nullif(c ->> 'drawer_name', ''), pa.name), 'notes', p ->> 'notes'));
      perform set_config('sumou.internal', public.internal_token(), true);
      update public.cheques set visit_id = vid where id = ch;
      perform set_config('sumou.internal', coalesce(prev, ''), true);
      chs := chs || ch; tot := tot + (c ->> 'amount')::numeric;
    end loop;
    posted := true;
  else raise exception 'نوع الدفعة مش صحيح'; end if;
  return jsonb_build_object('entry_id', eid, 'cheques', to_jsonb(chs), 'total', tot, 'posted', posted, 'party', pa.name, 'mobile', coalesce(pa.mobile, pa.phone));
end $$;

-- ملخص المشرف: زيارات الفترة لكل مستخدم
create or replace function public.visits_report(p_company uuid, p_from date, p_to date)
returns table (user_id uuid, visits bigint, open_visits bigint, minutes numeric, customers bigint, taxi numeric, parking numeric, payments numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can(p_company, 'rep_visits', 'edit') then raise exception 'هالتقرير للمشرف'; end if;
  return query
  select v.user_id, count(*) filter (where v.status <> 'cancelled'), count(*) filter (where v.status = 'open'),
         round(coalesce(sum(extract(epoch from (coalesce(v.ended_at, now()) - v.started_at)) / 60) filter (where v.status = 'closed'), 0), 0),
         count(distinct v.party_id), sum(v.taxi_fee), sum(v.parking_fee),
         coalesce((select sum(e.total) from public.journal_entries e where e.visit_id = any(array_agg(v.id)) and e.status = 'posted' and e.reversed_by is null), 0)
         + coalesce((select sum(ch.amount) from public.cheques ch where ch.visit_id = any(array_agg(v.id)) and ch.status not in ('cancelled', 'returned')), 0)
    from public.sales_visits v
   where v.company_id = p_company and (v.started_at at time zone 'Asia/Amman')::date between p_from and p_to
   group by v.user_id;
end $$;

revoke execute on function public.visit_start(uuid, uuid, numeric, numeric, text), public.visit_end(uuid, numeric, numeric, text, text, numeric, numeric),
  public.visit_cancel(uuid), public.mobile_payment(jsonb), public.visits_report(uuid, date, date) from public, anon;
grant execute on function public.visit_start(uuid, uuid, numeric, numeric, text), public.visit_end(uuid, numeric, numeric, text, text, numeric, numeric),
  public.visit_cancel(uuid), public.mobile_payment(jsonb), public.visits_report(uuid, date, date) to authenticated;

-- visit_id على القيود والشيكات من النظام بس (من mobile_payment)، عشان ما حدا يربط دفعات مش إله بزيارته
create or replace function public.ab_visit_link_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() or coalesce(current_setting('sumou.visit', true), '') = public.internal_token() then return new; end if;
  if tg_op = 'INSERT' then
    if new.visit_id is not null then raise exception 'ربط الدفعة بزيارة من تطبيق المندوب بس'; end if;
  elsif new.visit_id is distinct from old.visit_id then
    raise exception 'ربط الدفعة بزيارة من تطبيق المندوب بس';
  end if;
  return new;
end $$;
drop trigger if exists ab_visit_link_guard on public.journal_entries;
create trigger ab_visit_link_guard before insert or update of visit_id on public.journal_entries for each row execute function public.ab_visit_link_guard();
drop trigger if exists ab_visit_link_guard on public.cheques;
create trigger ab_visit_link_guard before insert or update of visit_id on public.cheques for each row execute function public.ab_visit_link_guard();

-- صور الزيارات لمين إله شاشة الزيارات
create or replace function public.attachment_visible(p_company uuid, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_entity when 'employee' then public.can(p_company, 'payroll', 'view')
                       when 'payroll'  then public.can(p_company, 'payroll', 'view')
                       when 'asset'    then public.can(p_company, 'fixed_assets', 'view')
                       when 'visit'    then public.can(p_company, 'rep_visits', 'view')
                       else public.has_company(p_company) end;
$$;

-- النسخ الاحتياطي: الزيارات بعد العملاء وقبل القيود والشيكات
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'cost_centers', 'company_id = $1', 'code'),
   (5, 'currencies', 'company_id = $1', 'code'),
   (6, 'company_settings', 'company_id = $1', 'company_id'),
   (7, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (8, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (9, 'party_categories', 'company_id = $1', 'party_type, code'),
   (10, 'parties', 'company_id = $1', 'code'),
   (11, 'sales_visits', 'company_id = $1', 'started_at'),
   (12, 'item_categories', 'company_id = $1', 'code'),
   (13, 'items', 'company_id = $1', 'code'),
   (14, 'promotions', 'company_id = $1', 'date_from'),
   (15, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (16, 'warehouses', 'company_id = $1', 'code'),
   (17, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (18, 'departments', 'company_id = $1', 'level, code'),
   (19, 'boms', 'company_id = $1', 'code'),
   (20, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (21, 'journal_entries', 'company_id = $1', 'created_at'),
   (22, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (23, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (24, 'invoices', 'company_id = $1', 'created_at'),
   (25, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (26, 'orders', 'company_id = $1', 'created_at'),
   (27, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (28, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (29, 'cheques', 'company_id = $1', 'created_at'),
   (30, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (31, 'supply_requests', 'company_id = $1', 'req_no'),
   (32, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (33, 'stock_docs', 'company_id = $1', 'created_at'),
   (34, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (35, 'stock_moves', 'company_id = $1', 'created_at'),
   (36, 'productions', 'company_id = $1', 'prod_no'),
   (37, 'obligations', 'company_id = $1', 'due_date'),
   (38, 'recurring_entries', 'company_id = $1', 'created_at'),
   (39, 'employees', 'company_id = $1', 'code'),
   (40, 'payroll_runs', 'company_id = $1', 'period'),
   (41, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (42, 'asset_custodians', 'company_id = $1', 'code'),
   (43, 'fixed_assets', 'company_id = $1', 'code'),
   (44, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (45, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (46, 'asset_movements', 'company_id = $1', 'mov_no'),
   (47, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (48, 'custody_docs', 'company_id = $1', 'doc_no'),
   (49, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (50, 'bank_recons', 'company_id = $1', 'created_at'),
   (51, 'bank_cleared', 'company_id = $1', 'line_id'),
   (52, 'attachments', 'company_id = $1', 'created_at'),
   (53, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;

-- ---------------------------------------------------------------------
--  ترقيم الشركات (لكل مشترك): تلقائي 01، 02… أو يدوي، بدون تكرار
-- ---------------------------------------------------------------------
alter table public.tenants add column if not exists settings jsonb not null default '{}'::jsonb;

create or replace function public.company_numbering() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('mode', coalesce(t.settings #>> '{company_code,mode}', 'auto'), 'digits', coalesce((t.settings #>> '{company_code,digits}')::int, 2))
    from public.tenants t where t.id = public.my_tenant();
$$;

create or replace function public.set_company_numbering(p_mode text, p_digits int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() or not public.tenant_writable() then raise exception 'ترقيم الشركات لمدير النظام بس'; end if;
  if p_mode not in ('auto', 'manual') or coalesce(p_digits, 0) not between 1 and 6 then raise exception 'إعداد مش صحيح'; end if;
  update public.tenants set settings = jsonb_set(coalesce(settings, '{}'::jsonb), '{company_code}', jsonb_build_object('mode', p_mode, 'digits', p_digits))
   where id = public.my_tenant();
end $$;

create or replace function public.ab_company_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; mx bigint;
begin
  if public.is_internal() then return new; end if;
  select coalesce(settings -> 'company_code', '{}'::jsonb) into cfg from public.tenants where id = new.tenant_id;
  if coalesce(cfg ->> 'mode', 'auto') = 'auto' then
    if tg_op = 'UPDATE' then
      if new.code is distinct from old.code then raise exception 'رمز الشركة تلقائي، ما بيتعدّل (غيّر طريقة الترقيم ليدوي أول)'; end if;
      return new;
    end if;
    perform pg_advisory_xact_lock(hashtext('cocode:' || coalesce(new.tenant_id::text, '')));
    select coalesce(max(code::bigint), 0) into mx from public.companies where tenant_id is not distinct from new.tenant_id and code ~ '^\d{1,15}$';
    new.code := (mx + 1)::text;
    if length(new.code) < greatest(coalesce((cfg ->> 'digits')::int, 2), 1) then new.code := lpad(new.code, greatest(coalesce((cfg ->> 'digits')::int, 2), 1), '0'); end if;
  else
    new.code := nullif(trim(new.code), '');
    if new.code is null then raise exception 'رمز الشركة مطلوب (الترقيم يدوي)'; end if;
    if exists (select 1 from public.companies where tenant_id is not distinct from new.tenant_id and code = new.code and id <> new.id) then
      raise exception 'رمز الشركة «%» مستخدم', new.code;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ab_company_code on public.companies;
create trigger ab_company_code before insert or update of code on public.companies for each row execute function public.ab_company_code();

revoke execute on function public.set_company_numbering(text, int) from public, anon;
grant execute on function public.company_numbering(), public.set_company_numbering(text, int) to authenticated;


-- #################### 41_trial.sql ####################
-- =====================================================================
--  السمو ERP — المرحلة 41: التجربة المجانية (تسجيل ذاتي بمشترك تجريبي)
--  أي حدا بيسجّل من شاشة الدخول: بينعمله مشترك تجريبي لحاله (14 يوم، حد حركات، مستخدمين اثنين، شركة وحدة)
--  وبعد أول دخول بتنعمله نسخة من «شركة القالب» اللي بيختارها مدير المنصة (بأرقام جديدة، منفصلة تماماً).
-- =====================================================================
alter table public.tenants add column if not exists is_trial boolean not null default false;
alter table public.tenants add column if not exists max_docs int check (max_docs is null or max_docs > 0);
alter table public.tenants add column if not exists signup_ip text;
create index if not exists tenants_trial_created on public.tenants (created_at) where is_trial;

-- قالب التجربة: نسخة احتياطية من شركة بيختارها مدير المنصة
create table if not exists public.demo_template (
  id           int primary key default 1 check (id = 1),
  company_name text,
  data         jsonb not null,
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);
alter table public.demo_template enable row level security;
revoke all on public.demo_template from anon, authenticated;

create or replace function public.super_set_demo_template(p_company uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d jsonb; nm text;
begin
  if not public.is_super() or not public.has_company(p_company) then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select name into nm from public.companies where id = p_company;
  -- حماية: القالب لازم يكون شركة تجريبية (اسمها فيه «تجريب» أو «عرض» أو demo)، مش شركة زبون حقيقي
  if nm !~* '(تجريب|عرض|ديمو|demo)' then raise exception 'القالب لازم يكون شركة تجريبية: سمّيها مثلاً «شركة العرض» أو «شركة تجريبية»'; end if;
  d := public.backup_company(p_company);
  -- بدون مرفقات وزيارات (مواقع) ومتابعة إقرارات
  d := jsonb_set(d, '{tables,attachments}', '[]'::jsonb);
  d := jsonb_set(d, '{tables,sales_visits}', '[]'::jsonb);
  d := jsonb_set(d, '{tables,obligations}', '[]'::jsonb);
  d := jsonb_set(d, '{tables,journal_entries}', coalesce((select jsonb_agg(x - 'visit_id') from jsonb_array_elements(d -> 'tables' -> 'journal_entries') x), '[]'::jsonb));
  d := jsonb_set(d, '{tables,cheques}', coalesce((select jsonb_agg(x - 'visit_id') from jsonb_array_elements(d -> 'tables' -> 'cheques') x), '[]'::jsonb));
  insert into public.demo_template (id, company_name, data, updated_at, updated_by) values (1, nm, d, now(), auth.uid())
  on conflict (id) do update set company_name = excluded.company_name, data = excluded.data, updated_at = now(), updated_by = auth.uid();
end $$;

create or replace function public.super_demo_template_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  return (select jsonb_build_object('company_name', company_name, 'updated_at', updated_at, 'company_id', data ->> 'company_id') from public.demo_template where id = 1);
end $$;

-- التسجيل الذاتي (من شاشة الدخول بدون حساب). حدود عشان ما ينضرب بالتسجيل المتكرر
create or replace function public.trial_signup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions, auth as $$
declare nm text := nullif(trim(p ->> 'name'), ''); co text := nullif(trim(p ->> 'company'), '');
  ph text := regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9+]', '', 'g'); un text := lower(trim(coalesce(p ->> 'username', '')));
  pw text := coalesce(p ->> 'password', ''); em text := nullif(lower(trim(p ->> 'email')), '');
  c text; tid uuid; uid uuid; i int := 0; ip text; prev text := current_setting('sumou.internal', true);
begin
  if not exists (select 1 from public.demo_template where id = 1) then raise exception 'التجربة المجانية مش متاحة هسا'; end if;
  if nm is null or length(nm) > 80 then raise exception 'اكتب اسمك'; end if;
  if co is null or length(co) > 100 then raise exception 'اكتب اسم الشركة أو النشاط'; end if;
  if ph !~ '^\+?[0-9]{9,15}$' then raise exception 'رقم الموبايل مش صحيح'; end if;
  if em is not null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'الإيميل مش صحيح'; end if;
  if un !~ '^[a-z0-9._-]{3,30}$' then raise exception 'اسم المستخدم لازم يكون أحرف إنجليزي أو أرقام (3 لـ 30)'; end if;
  if length(pw) < 6 or length(pw) > 72 then raise exception 'كلمة السر لازم تكون 6 أحرف على الأقل'; end if;
  -- حدود: نفس الرقم مرة وحدة بالشهر، وعدد التسجيلات بالساعة واليوم
  perform pg_advisory_xact_lock(hashtext('trial_signup'));
  if exists (select 1 from public.tenants where is_trial and phone = ph and created_at > now() - interval '30 days') then
    raise exception 'هالرقم إله تجربة من قبل. تواصل معنا لتمديدها أو للاشتراك';
  end if;
  ip := nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '');
  if ip is not null and (select count(*) from public.tenants where is_trial and signup_ip = ip and created_at > now() - interval '1 day') >= 3 then
    raise exception 'سجّلت تجارب كثير من نفس الجهاز اليوم. تواصل معنا';
  end if;
  if (select count(*) from public.tenants where is_trial and created_at > now() - interval '1 hour') >= 30
     or (select count(*) from public.tenants where is_trial and created_at > now() - interval '1 day') >= 150 then
    raise exception 'في ضغط على التسجيل هسا، جرّب بعد شوي';
  end if;
  loop
    c := 'd' || lpad((floor(random() * 100000))::int::text, 5, '0');
    exit when not exists (select 1 from public.tenants where code = c);
    i := i + 1; if i > 30 then raise exception 'جرّب مرة ثانية'; end if;
  end loop;
  insert into public.tenants (code, name, status, plan, max_users, max_companies, max_docs, modules, expires_at, contact_name, phone, email, notes, is_trial, signup_ip)
  values (c, co, 'active', 'تجربة مجانية', 2, 1, 300, null, public.local_today() + 13, nm, ph, em, 'تسجيل ذاتي', true, ip)
  returning id into tid;
  perform set_config('sumou.internal', public.internal_token(), true);
  insert into public.user_groups (name, description, permissions, tenant_id)
  select g.name, g.description, g.permissions, tid from public.user_groups g
   where g.tenant_id = public.default_tenant() and g.name in ('محاسب', 'مدخل بيانات', 'مشاهد', 'كاشير');
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  uid := public.create_tenant_user(tid, un, nm, pw, '{}'::jsonb, '{}', true);
  insert into public.activity_log (user_id, action, entity, entity_id, details, tenant_id)
  values (uid, 'إضافة', 'tenants', tid, jsonb_build_object('trial', true, 'phone', ph, 'company', co), tid);
  return jsonb_build_object('code', c, 'username', un, 'expires_at', public.local_today() + 13);
end $$;

-- بعد أول دخول: نسخة من شركة القالب بأرقام (معرّفات) جديدة
create or replace function public.trial_setup() returns uuid
language plpgsql security definer set search_path = public as $$
declare t public.tenants; d jsonb; txt text; ids text[]; re text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  cid uuid; tb text;
begin
  select * into t from public.tenants where id = public.my_tenant() for update;
  if t.id is null or not t.is_trial then raise exception 'هالعملية للتجربة المجانية بس'; end if;
  if not public.is_admin() then raise exception 'بس مدير الحساب'; end if;
  if exists (select 1 from public.companies where tenant_id = t.id) then
    return (select id from public.companies where tenant_id = t.id order by created_at limit 1);
  end if;
  select data into d from public.demo_template where id = 1;
  if d is null then raise exception 'التجربة المجانية مش متاحة هسا'; end if;
  -- كل معرّف سطر بالنسخة بياخذ معرّف جديد، ومعرّفات المستخدمين بتصير المستخدم الحالي
  for tb in select jsonb_object_keys(d -> 'tables') loop
    ids := ids || coalesce((select array_agg(x ->> 'id') from jsonb_array_elements(d -> 'tables' -> tb) x where x ? 'id' and (x ->> 'id') ~ ('^' || re || '$')), '{}');
  end loop;
  create temp table if not exists _trial_map (old text primary key, new text) on commit drop;
  truncate _trial_map;
  insert into _trial_map select distinct u, gen_random_uuid()::text from unnest(ids) u on conflict do nothing;
  insert into _trial_map select p.id::text, auth.uid()::text from public.profiles p
   where p.id::text in (select m[1] from regexp_matches(d::text, '(' || re || ')', 'g') m) on conflict do nothing;
  txt := d::text;
  with parts as (select p, n from regexp_split_to_table(txt, re) with ordinality s(p, n)),
       ms as (select m[1] as u, n from regexp_matches(txt, '(' || re || ')', 'g') with ordinality s(m, n))
  select string_agg(parts.p || coalesce(mp.new, ms.u, ''), '' order by parts.n) into txt
    from parts left join ms on ms.n = parts.n left join _trial_map mp on mp.old = ms.u;
  d := txt::jsonb;
  cid := (d ->> 'company_id')::uuid;
  perform set_config('sumou.trial', public.internal_token(), true);
  perform public.restore_company(d);
  perform set_config('sumou.trial', '', true);
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.companies set name = t.name where id = cid;
  perform set_config('sumou.internal', '', true);
  insert into public.user_companies (user_id, company_id) values (auth.uid(), cid) on conflict do nothing;
  return cid;
end $$;

-- حد الحركات للتجربة: القيود اليدوية (قيد، قبض، صرف، افتتاحي، والعكسية منهم) والفواتير وسندات المخزون والطلبات بعد تاريخ التسجيل
-- (قيود الترحيل التلقائية للفواتير والمخزون والشيكات ما بتنحسب لأنها جزء من مستندها)
create or replace function public.tenant_docs_used(p_tenant uuid) returns bigint
language sql stable security definer set search_path = public as $$
  with t as (select id, created_at from public.tenants where id = p_tenant), cs as (select c.id from public.companies c, t where c.tenant_id = t.id)
  select (select count(*) from public.journal_entries x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at and x.entry_type in ('journal','receipt','payment','opening'))
       + (select count(*) from public.invoices x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at)
       + (select count(*) from public.stock_docs x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at)
       + (select count(*) from public.orders x, t where x.company_id in (select id from cs) and x.created_at >= t.created_at);
$$;
revoke execute on function public.tenant_docs_used(uuid) from public, anon, authenticated;

create or replace function public.ab_tenant_doc_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.tenants;
begin
  if coalesce(current_setting('sumou.trial', true), '') = public.internal_token() then return new; end if;   -- تجهيز التجربة
  if tg_table_name = 'journal_entries' then
    if (to_jsonb(new) ->> 'entry_type') not in ('journal','receipt','payment','opening') then return new; end if;
  end if;
  select te.* into t from public.tenants te join public.companies c on c.tenant_id = te.id where c.id = new.company_id;
  if t.max_docs is null then return new; end if;
  perform pg_advisory_xact_lock(hashtext('tdocs:' || t.id));
  if public.tenant_docs_used(t.id) >= t.max_docs then
    raise exception 'وصلت حد الحركات بالتجربة المجانية (%). تواصل معنا للاشتراك', t.max_docs;
  end if;
  return new;
end $$;

-- التجربة ما بتسترجع نسخ (عشان حد الحركات وحجم القاعدة) إلا تجهيزها الأول
create or replace function public.ab_trial_restore_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_internal() and coalesce(current_setting('sumou.trial', true), '') <> public.internal_token()
     and exists (select 1 from public.tenants where id = public.my_tenant() and is_trial) then
    raise exception 'الاسترجاع مش متاح بالتجربة المجانية';
  end if;
  return new;
end $$;
drop trigger if exists ab_trial_restore_guard on public.companies;
create trigger ab_trial_restore_guard before insert on public.companies for each row execute function public.ab_trial_restore_guard();

do $$
declare tb text;
begin
  foreach tb in array array['journal_entries', 'invoices', 'stock_docs', 'orders'] loop
    execute format('drop trigger if exists ab_tenant_doc_limit on public.%I', tb);
    execute format('create trigger ab_tenant_doc_limit before insert on public.%I for each row execute function public.ab_tenant_doc_limit()', tb);
  end loop;
end $$;

-- حالة التجربة للواجهة
create or replace function public.trial_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when t.is_trial then jsonb_build_object(
    'is_trial', true, 'code', t.code, 'expires_at', t.expires_at, 'days_left', t.expires_at - public.local_today(),
    'max_docs', t.max_docs,
    'docs_used', public.tenant_docs_used(t.id),
    'has_company', exists (select 1 from public.companies c where c.tenant_id = t.id))
  else jsonb_build_object('is_trial', false) end
  from public.tenants t where t.id = public.my_tenant();
$$;

-- لمدير المنصة: معلومات التجارب، وحذف تجربة خلصت
create or replace function public.super_tenant_extras()
returns table (id uuid, is_trial boolean, max_docs int, docs_used bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception 'هالشاشة لمدير المنصة بس'; end if;
  return query select t.id, t.is_trial, t.max_docs, public.tenant_docs_used(t.id)
    from public.tenants t;
end $$;

create or replace function public.super_delete_trial(p_tenant uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare t public.tenants; cid uuid; r record;
begin
  if not public.is_super() then raise exception 'هالعملية لمدير المنصة بس'; end if;
  select * into t from public.tenants where id = p_tenant for update;
  if t.id is null or not t.is_trial or t.is_default then raise exception 'بس حسابات التجربة بتنحذف من هون'; end if;
  if exists (select 1 from public.tenant_payments where tenant_id = t.id) then raise exception 'هالمشترك إله دفعات، ما بينحذف'; end if;
  -- حذف كامل بدون triggers (بيانات تجربة): كل جدول لحاله بالترتيب العكسي، وبعدين أي جدول فيه company_id
  begin
    perform set_config('session_replication_role', 'replica', true);
  exception when others then raise exception 'الحذف الكامل مش متاح على السيرفر';
  end;
  for cid in select id from public.companies where tenant_id = t.id loop
    for r in select * from public.backup_tables() where tbl <> 'companies' order by ord desc loop
      execute format('delete from public.%I where %s', r.tbl, r.cond) using cid;
    end loop;
    for r in select c.table_name from information_schema.columns c join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name
              where c.table_schema = 'public' and c.column_name = 'company_id' and x.table_type = 'BASE TABLE' loop
      execute format('delete from public.%I where company_id = $1', r.table_name) using cid;
    end loop;
    delete from public.companies where id = cid;
  end loop;
  perform set_config('session_replication_role', 'origin', true);
  delete from public.user_companies where user_id in (select id from public.profiles where tenant_id = t.id);
  delete from public.user_groups where tenant_id = t.id;
  delete from public.activity_log where tenant_id = t.id;
  delete from auth.identities where user_id in (select id from public.profiles where tenant_id = t.id);
  delete from auth.users where id in (select id from public.profiles where tenant_id = t.id);
  delete from public.profiles where tenant_id = t.id;
  delete from public.tenant_payments where tenant_id = p_tenant;
  delete from public.tenants where id = p_tenant;
  insert into public.activity_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'حذف', 'tenants', p_tenant, jsonb_build_object('trial', true, 'code', t.code, 'name', t.name));
end $$;

-- الدفعة بتحوّل التجربة لاشتراك عادي (بدون حد حركات ولا علامة تجربة)
create or replace function public.ab_trial_convert_on_payment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.tenants set is_trial = false, max_docs = null, plan = case when plan = 'تجربة مجانية' then null else plan end, updated_at = now()
   where id = new.tenant_id and is_trial;
  return new;
end $$;
drop trigger if exists ab_trial_convert_on_payment on public.tenant_payments;
create trigger ab_trial_convert_on_payment after insert on public.tenant_payments for each row execute function public.ab_trial_convert_on_payment();

revoke execute on function public.super_set_demo_template(uuid), public.super_demo_template_info(), public.trial_setup(), public.trial_status(),
  public.super_tenant_extras(), public.super_delete_trial(uuid) from public, anon;
grant execute on function public.super_set_demo_template(uuid), public.super_demo_template_info(), public.trial_setup(), public.trial_status(),
  public.super_tenant_extras(), public.super_delete_trial(uuid) to authenticated;
revoke execute on function public.trial_signup(jsonb) from public;
grant execute on function public.trial_signup(jsonb) to anon, authenticated;
