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
