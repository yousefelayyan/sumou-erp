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
          coalesce(p_note, 'قيد عكسي للقيد رقم ' || e.entry_no || coalesce(' - ' || e.description, '')),
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
create or replace function public.pending_posts(p_company uuid)
returns table (kind text, id uuid, doc_type text, doc_no int, doc_date date, description text, amount numeric, created_by uuid, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select 'entry', e.id, e.entry_type, e.entry_no, e.entry_date, e.description,
         (select coalesce(sum(jl.debit), 0) from public.journal_lines jl where jl.entry_id = e.id), e.created_by, e.created_at
  from public.journal_entries e where e.company_id = p_company and e.status = 'draft' and public.can(p_company, public.entry_screen(e.entry_type), 'view')
  union all
  select 'invoice', i.id, i.inv_type, i.inv_no, i.inv_date, coalesce(i.party_name, (select pp.name from public.parties pp where pp.id = i.party_id)), i.total, i.created_by, i.created_at
  from public.invoices i where i.company_id = p_company and i.status = 'draft' and public.can(p_company, public.invoice_screen(i.inv_type), 'view')
  union all
  select 'stock', d.id, d.doc_type, d.doc_no, d.doc_date, d.notes, null::numeric, d.created_by, d.created_at
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
create or replace function public.rep_bank_lines(p_recon uuid)
returns table (line_id uuid, entry_type text, entry_no int, entry_date date, description text, reference text, debit numeric, credit numeric, cleared boolean)
language plpgsql stable security definer set search_path = public as $$
declare rc public.bank_recons;
begin
  select * into rc from public.bank_recons where id = p_recon;
  if not public.can(rc.company_id, 'bank_recon', 'view') then raise exception 'ما عندك صلاحية'; end if;
  return query
  select l.id, e.entry_type, e.entry_no, e.entry_date, coalesce(l.description, e.description), e.reference, l.debit, l.credit,
         exists (select 1 from public.bank_cleared c where c.line_id = l.id and c.recon_id = p_recon)
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
