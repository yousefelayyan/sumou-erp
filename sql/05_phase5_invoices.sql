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
  perform set_config('sumou.internal', 'on', true);
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
  perform set_config('sumou.internal', 'on', true);
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
