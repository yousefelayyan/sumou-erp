-- =====================================================================
--  السمو ERP — المرحلة 51: خصومات العملاء وتسوية الأرصدة الصغيرة
--  discount_types: نوع الخصم مربوط بحساب (مصروف خصم مسموح به عادة).
--  customer_discount(jsonb): سند قيد (journal) مدين حساب نوع الخصم ودائن الزبون، ومرحّل إذا إله صلاحية،
--    ومع خيار توزيعه على فاتورة.
--  settle_small_balances(...): شطب الأرصدة الصغيرة بين حدّين بقيد واحد على حساب التسوية (معاينة أو تنفيذ).
-- =====================================================================
create table if not exists public.discount_types (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code       text not null,
  name       text not null,
  account_id uuid not null references public.accounts(id) on delete restrict,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);
alter table public.discount_types enable row level security;
grant select, insert, update, delete on public.discount_types to authenticated;
drop policy if exists dsc_select on public.discount_types;
create policy dsc_select on public.discount_types for select to authenticated using (public.has_company(company_id));
drop policy if exists dsc_write on public.discount_types;
create policy dsc_write on public.discount_types for all to authenticated
  using (public.can(company_id, 'customer_discounts', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'customer_discounts', 'edit') and public.tenant_writable());

create or replace function public.ad_discount_type_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.accounts where id = new.account_id and company_id = new.company_id and not is_group) then
    raise exception 'حساب نوع الخصم لازم يكون حساب فرعي من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_discount_type_check on public.discount_types;
create trigger ad_discount_type_check before insert or update on public.discount_types for each row execute function public.ad_discount_type_check();

alter table public.company_settings add column if not exists settle_account_id uuid references public.accounts(id) on delete set null;

-- سند خصم: p = {company_id, date, description, post:bool, lines:[{party_id, discount_type_id, amount, invoice_id?, note}]}
create or replace function public.customer_discount(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := (p ->> 'company_id')::uuid; d date := coalesce(nullif(p ->> 'date', '')::date, public.local_today()); fy uuid; eid uuid;
  ln int := 0; l jsonb; pt public.parties; dt public.discount_types; amt numeric; tot numeric := 0; inv uuid; allocs jsonb := '[]';
begin
  if not public.can(cid, 'customer_discounts', 'add') or not public.can(cid, 'journal_entries', 'add') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
  select id into fy from public.fiscal_years where company_id = cid and d between start_date and end_date and not is_closed order by start_date desc limit 1;
  if fy is null then raise exception 'ما في سنة مالية مفتوحة بهالتاريخ'; end if;
  if jsonb_array_length(coalesce(p -> 'lines', '[]')) = 0 then raise exception 'أضف سطر واحد على الأقل'; end if;
  insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference)
  values (cid, fy, 'journal', d, coalesce(nullif(trim(p ->> 'description'), ''), 'خصومات عملاء'), 'خصم عملاء') returning id into eid;
  for l in select * from jsonb_array_elements(p -> 'lines') loop
    amt := round(coalesce(nullif(l ->> 'amount', '')::numeric, 0), 3);
    if amt <= 0 then continue; end if;
    select * into pt from public.parties where id = (l ->> 'party_id')::uuid and company_id = cid and party_type = 'customer';
    if pt.id is null then raise exception 'الزبون مش موجود'; end if;
    select * into dt from public.discount_types where id = (l ->> 'discount_type_id')::uuid and company_id = cid and is_active;
    if dt.id is null then raise exception 'نوع الخصم مش موجود'; end if;
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (eid, ln, dt.account_id, dt.name || ' — ' || pt.name || coalesce(' — ' || nullif(trim(l ->> 'note'), ''), ''), amt, 0);
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (eid, ln, pt.account_id, pt.id, dt.name || coalesce(' — ' || nullif(trim(l ->> 'note'), ''), ''), 0, amt);
    tot := tot + amt;
    inv := nullif(l ->> 'invoice_id', '')::uuid;
    if inv is not null then allocs := allocs || jsonb_build_array(jsonb_build_object('party', pt.id, 'invoice_id', inv, 'amount', amt)); end if;
  end loop;
  if ln = 0 then raise exception 'كل المبالغ صفر'; end if;
  if coalesce((p ->> 'post')::boolean, false) and public.can(cid, 'journal_entries', 'post') then
    perform public.post_entry(eid);
    -- التوزيع على الفواتير (لكل زبون)
    for l in select jsonb_build_object('party', x ->> 'party', 'items', jsonb_agg(jsonb_build_object('invoice_id', x ->> 'invoice_id', 'amount', (x ->> 'amount')::numeric)))
               from jsonb_array_elements(allocs) x group by x ->> 'party' loop
      perform public.allocate_payment(eid, (l ->> 'party')::uuid, l -> 'items');
    end loop;
  end if;
  return eid;
end $$;

-- تسوية الأرصدة الصغيرة: p_type customer|supplier، الحدود بالقيمة المطلقة، p_apply false = معاينة
create or replace function public.settle_small_balances(p_company uuid, p_type text, p_min numeric, p_max numeric, p_date date, p_apply boolean default false)
returns table (party_id uuid, code text, name text, balance numeric, entry_id uuid)
language plpgsql security definer set search_path = public as $$
declare acc uuid; fy uuid; eid uuid; ln int := 0; r record; tot numeric := 0;
begin
  if not public.can(p_company, 'customer_discounts', 'view') then raise exception 'ما عندك صلاحية'; end if;
  if p_type not in ('customer','supplier') then raise exception 'النوع غلط'; end if;
  if coalesce(p_max, 0) <= 0 or p_max > 100 or coalesce(p_min, 0) < 0 or p_min > p_max then raise exception 'الحدود لازم بين 0 و 100'; end if;
  create temp table if not exists _settle (party_id uuid, code text, name text, account_id uuid, balance numeric) on commit drop;
  truncate _settle;
  insert into _settle
  select p.id, p.code, p.name, p.account_id, round(public.party_balance_fy(p.id, null), 3)
    from public.parties p where p.company_id = p_company and p.party_type = p_type and p.is_active and public.has_company(p_company);
  delete from _settle s where abs(s.balance) < p_min or abs(s.balance) > p_max or s.balance = 0;
  if p_apply then
    if not public.can(p_company, 'customer_discounts', 'add') or not public.can(p_company, 'journal_entries', 'add') or not public.tenant_writable() then raise exception 'ما عندك صلاحية'; end if;
    select settle_account_id into acc from public.company_settings where company_id = p_company;
    if acc is null then raise exception 'حدّد «حساب تسوية الأرصدة الصغيرة» بحسابات الربط'; end if;
    select id into fy from public.fiscal_years where company_id = p_company and p_date between start_date and end_date and not is_closed order by start_date desc limit 1;
    if fy is null then raise exception 'ما في سنة مالية مفتوحة بهالتاريخ'; end if;
    if not exists (select 1 from _settle) then raise exception 'ما في أرصدة ضمن الحدود'; end if;
    insert into public.journal_entries (company_id, fiscal_year_id, entry_type, entry_date, description, reference)
    values (p_company, fy, 'journal', p_date, 'تسوية أرصدة صغيرة (' || p_min || ' - ' || p_max || ')', 'تسوية أرصدة') returning id into eid;
    for r in select * from _settle order by code loop
      ln := ln + 1;
      insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
      values (eid, ln, r.account_id, r.party_id, 'تسوية رصيد صغير', greatest(-r.balance, 0), greatest(r.balance, 0));
      tot := tot + r.balance;
    end loop;
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, description, debit, credit)
    values (eid, ln, acc, 'تسوية أرصدة صغيرة', greatest(tot, 0), greatest(-tot, 0));
    if public.can(p_company, 'journal_entries', 'post') then perform public.post_entry(eid); end if;
  end if;
  return query select s.party_id, s.code, s.name, s.balance, eid from _settle s order by s.code;
end $$;

-- الرصيد التراكمي: p_fy = null يعني كل السنين (party_balance_fy بيتجاهل p_fy أصلاً)
revoke execute on function public.customer_discount(jsonb), public.settle_small_balances(uuid, text, numeric, numeric, date, boolean) from public, anon;
grant execute on function public.customer_discount(jsonb), public.settle_small_balances(uuid, text, numeric, numeric, date, boolean) to authenticated;

-- النسخة الاحتياطية: أنواع الخصم بعد الحسابات
create or replace function public.backup_tables() returns table (ord int, tbl text, cond text, ordby text)
language sql immutable as $$
  values
   (1, 'companies', 'id = $1', 'code'),
   (2, 'fiscal_years', 'company_id = $1', 'start_date'),
   (3, 'accounts', 'company_id = $1', 'level, code'),
   (4, 'discount_types', 'company_id = $1', 'code'),
   (5, 'cost_centers', 'company_id = $1', 'code'),
   (6, 'currencies', 'company_id = $1', 'code'),
   (7, 'company_settings', 'company_id = $1', 'company_id'),
   (8, 'lookups', 'company_id = $1', 'parent_id nulls first, kind, code'),
   (9, 'custom_fields', 'company_id = $1', 'entity, sort'),
   (10, 'party_categories', 'company_id = $1', 'party_type, code'),
   (11, 'price_lists', 'company_id = $1', 'code'),
   (12, 'parties', 'company_id = $1', 'code'),
   (13, 'sales_visits', 'company_id = $1', 'started_at'),
   (14, 'item_categories', 'company_id = $1', 'code'),
   (15, 'items', 'company_id = $1', 'code'),
   (16, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (17, 'promotions', 'company_id = $1', 'date_from'),
   (18, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (19, 'warehouses', 'company_id = $1', 'code'),
   (20, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (21, 'departments', 'company_id = $1', 'level, code'),
   (22, 'doc_types', 'company_id = $1', 'kind, code'),
   (23, 'boms', 'company_id = $1', 'code'),
   (24, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (25, 'journal_entries', 'company_id = $1', 'created_at'),
   (26, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (27, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (28, 'invoices', 'company_id = $1', 'created_at'),
   (29, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (30, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (31, 'orders', 'company_id = $1', 'created_at'),
   (32, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (33, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (34, 'cheques', 'company_id = $1', 'created_at'),
   (35, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (36, 'supply_requests', 'company_id = $1', 'req_no'),
   (37, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (38, 'stock_docs', 'company_id = $1', 'created_at'),
   (39, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (40, 'stock_moves', 'company_id = $1', 'created_at'),
   (41, 'productions', 'company_id = $1', 'prod_no'),
   (42, 'obligations', 'company_id = $1', 'due_date'),
   (43, 'recurring_entries', 'company_id = $1', 'created_at'),
   (44, 'work_locations', 'company_id = $1', 'name'),
   (45, 'employees', 'company_id = $1', 'code'),
   (46, 'attendance', 'company_id = $1', 'day, employee_id'),
   (47, 'payroll_runs', 'company_id = $1', 'period'),
   (48, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (49, 'employee_loans', 'company_id = $1', 'loan_no'),
   (50, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (51, 'asset_custodians', 'company_id = $1', 'code'),
   (52, 'fixed_assets', 'company_id = $1', 'code'),
   (53, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (54, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (55, 'asset_movements', 'company_id = $1', 'mov_no'),
   (56, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (57, 'custody_docs', 'company_id = $1', 'doc_no'),
   (58, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (59, 'bank_recons', 'company_id = $1', 'created_at'),
   (60, 'bank_cleared', 'company_id = $1', 'line_id'),
   (61, 'attachments', 'company_id = $1', 'created_at'),
   (62, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
