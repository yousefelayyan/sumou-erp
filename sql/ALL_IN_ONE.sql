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

drop trigger if exists companies_touch on public.companies;
create trigger companies_touch before update on public.companies
  for each row execute function public.touch_updated_at();

-- منع تعديل سنة مالية مغلقة (إلا إعادة فتحها من المدير)
create or replace function public.guard_closed_year() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.is_closed and new.is_closed and not public.is_admin() then
    raise exception 'السنة المالية مغلقة ولا يمكن تعديلها';
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
  with check (user_id = auth.uid() and public.is_active_user());
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
    if tg_op = 'UPDATE' and new.parent_id = new.id then raise exception 'الحساب ما بيقدر يكون أب لحاله'; end if;
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

  if tg_op = 'UPDATE' and old.status <> 'draft' and not public.is_internal() then
    raise exception 'القيد مرحّل، ما بينعدّل. اعمل قيد عكسي';
  end if;
  if tg_op = 'INSERT' and new.status <> 'draft' and not public.is_internal() then
    raise exception 'القيد الجديد لازم ينحفظ كمسودة، والترحيل من زر «ترحيل»';
  end if;

  select * into fy from public.fiscal_years where id = new.fiscal_year_id;
  if fy.id is null or fy.company_id <> new.company_id then raise exception 'السنة المالية مش لهالشركة'; end if;
  if fy.is_closed then raise exception 'السنة المالية مغلقة، ما بتقدر تضيف أو تعدّل قيود فيها'; end if;
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
  eid := case when tg_op = 'DELETE' then old.entry_id else new.entry_id end;
  select * into e from public.journal_entries where id = eid;
  if e.id is not null and e.status <> 'draft' and not public.is_internal() then
    raise exception 'القيد مرحّل، ما بتقدر تعدّل سطوره';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  select * into a from public.accounts where id = new.account_id;
  if a.id is null or a.company_id <> e.company_id then raise exception 'الحساب مش لهالشركة'; end if;
  if a.is_group then raise exception 'الحساب «% - %» حساب رئيسي، اختار حساب فرعي', a.code, a.name; end if;
  if not a.is_active then raise exception 'الحساب «% - %» موقوف', a.code, a.name; end if;
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
  check (entry_type in ('journal','receipt','payment','opening','invoice'));

create or replace function public.entry_screen(t text) returns text
language sql immutable as $$
  select case t when 'journal' then 'journal_entries' when 'receipt' then 'receipt_vouchers'
                when 'payment' then 'payment_vouchers' when 'opening' then 'opening_balances'
                when 'invoice' then 'journal_entries' end;
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
  if tg_op = 'UPDATE' and old.status <> 'draft' and not public.is_internal() then raise exception 'الفاتورة مرحّلة، ما بتنعدّل'; end if;
  if tg_op = 'INSERT' and new.status <> 'draft' then raise exception 'الفاتورة الجديدة لازم تنحفظ كمسودة'; end if;
  select * into fy from public.fiscal_years where id = new.fiscal_year_id;
  if fy.id is null or fy.company_id <> new.company_id then raise exception 'السنة المالية مش لهالشركة'; end if;
  if fy.is_closed then raise exception 'السنة المالية مغلقة'; end if;
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
  iid := case when tg_op = 'DELETE' then old.invoice_id else new.invoice_id end;
  select * into i from public.invoices where id = iid;
  if i.id is not null and i.status <> 'draft' and not public.is_internal() then raise exception 'الفاتورة مرحّلة، ما بتنعدّل سطورها'; end if;
  return case when tg_op = 'DELETE' then old else new end;
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
