-- =====================================================================
--  السمو ERP — المرحلة 69: فاتورة الشراء على أكثر من مورد («فواتير الموردين»)
--  invoice_party_splits: حصص موردين ثانيين بفاتورة شراء آجلة (مورد، مبلغ، رقم فاتورة المورد، ملاحظات).
--  المورد الرئيسي (party_id) بياخذ الباقي = المجموع − الحصص. بعد ترحيل الفاتورة للمحاسبة، trigger zi_invoice_party_splits
--  بينزّل الحصص من سطر المورد الرئيسي بالقيد وبيعمل سطر دائن لكل مورد على حسابه. القيد العكسي (إلغاء الفاتورة) بينسخهم.
--  party_open_invoices: المجموع المفتوح للمورد الرئيسي = المجموع − الحصص.
--  الكتابة مباشرة (purchase_invoices edit) والفاتورة مسودة؛ الحماية ab_invoice_split_guard.
-- =====================================================================
create table if not exists public.invoice_party_splits (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.invoices(id) on delete cascade,
  line_no      int not null default 1,
  party_id     uuid not null references public.parties(id) on delete restrict,
  amount       numeric(18,3) not null check (amount > 0),
  supplier_ref text check (supplier_ref is null or length(supplier_ref) <= 60),
  notes        text,
  unique (invoice_id, party_id)
);
create index if not exists invoice_party_splits_inv_idx on public.invoice_party_splits (invoice_id);
create index if not exists invoice_party_splits_party_idx on public.invoice_party_splits (party_id);
grant select, insert, update, delete on public.invoice_party_splits to authenticated;
alter table public.invoice_party_splits enable row level security;
drop policy if exists invoice_party_splits_sel on public.invoice_party_splits;
create policy invoice_party_splits_sel on public.invoice_party_splits for select
  using (exists (select 1 from public.invoices i where i.id = invoice_id and public.can(i.company_id, 'purchase_invoices', 'view') and public.dept_ok(i.company_id, i.department_id)));
drop policy if exists invoice_party_splits_wr on public.invoice_party_splits;
create policy invoice_party_splits_wr on public.invoice_party_splits for all
  using (exists (select 1 from public.invoices i where i.id = invoice_id and i.status = 'draft' and public.can(i.company_id, 'purchase_invoices', 'edit') and public.tenant_writable() and public.dept_ok(i.company_id, i.department_id)))
  with check (exists (select 1 from public.invoices i where i.id = invoice_id and i.status = 'draft' and public.can(i.company_id, 'purchase_invoices', 'edit') and public.tenant_writable() and public.dept_ok(i.company_id, i.department_id)));

create or replace function public.ab_invoice_split_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare i public.invoices;
begin
  if tg_op = 'UPDATE' then new.invoice_id := old.invoice_id; end if;
  select * into i from public.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if i.id is null then return case when tg_op = 'DELETE' then old else new end; end if;   -- حذف الفاتورة المتسلسل
  if not public.is_internal() and i.status <> 'draft' then raise exception 'الفاتورة مرحّلة — حصص الموردين ما بتتعدّل'; end if;
  if tg_op = 'DELETE' then return old; end if;
  if i.inv_type <> 'purchase' or i.payment_type <> 'credit' then raise exception 'حصص الموردين بس لفاتورة شراء آجلة'; end if;
  if not exists (select 1 from public.parties where id = new.party_id and company_id = i.company_id and party_type = 'supplier' and account_id is not null) then
    raise exception 'المورد مش من نفس الشركة أو ما إله حساب'; end if;
  if new.party_id = i.party_id then raise exception 'المورد الرئيسي بياخذ الباقي لحاله — اختار مورد ثاني'; end if;
  new.supplier_ref := nullif(trim(coalesce(new.supplier_ref, '')), ''); new.amount := round(new.amount, 3);
  return new;
end $$;
drop trigger if exists ab_invoice_split_guard on public.invoice_party_splits;
create trigger ab_invoice_split_guard before insert or update or delete on public.invoice_party_splits for each row execute function public.ab_invoice_split_guard();
revoke execute on function public.ab_invoice_split_guard() from public, anon, authenticated;

-- بعد ترحيل الفاتورة: توزيع سطر المورد على الموردين
create or replace function public.zi_invoice_party_splits() returns trigger
language plpgsql security definer set search_path = public as $$
declare s numeric; ln int; mainl public.journal_lines; r record; prev text := current_setting('sumou.internal', true);
begin
  if not (old.status = 'draft' and new.status = 'posted' and new.inv_type = 'purchase' and new.payment_type = 'credit' and new.entry_id is not null) then return null; end if;
  select coalesce(sum(amount), 0) into s from public.invoice_party_splits where invoice_id = new.id;
  if s <= 0 then return null; end if;
  if s >= new.total - 0.0005 then raise exception 'مجموع حصص الموردين الثانيين (%) لازم يكون أقل من مجموع الفاتورة (%)', s, new.total; end if;
  select * into mainl from public.journal_lines where entry_id = new.entry_id and party_id = new.party_id and credit > 0 order by line_no limit 1;
  if mainl.id is null or mainl.credit < s then raise exception 'ما لقيت سطر المورد الرئيسي بقيد الفاتورة'; end if;
  perform set_config('sumou.internal', public.internal_token(), true);
  update public.journal_lines set credit = credit - s where id = mainl.id;
  select coalesce(max(line_no), 0) into ln from public.journal_lines where entry_id = new.entry_id;
  for r in select x.*, p.account_id acc, p.name nm from public.invoice_party_splits x join public.parties p on p.id = x.party_id where x.invoice_id = new.id order by x.line_no, p.code loop
    ln := ln + 1;
    insert into public.journal_lines (entry_id, line_no, account_id, party_id, description, debit, credit)
    values (new.entry_id, ln, r.acc, r.party_id, 'حصة ' || r.nm || ' من ' || coalesce(mainl.description, 'فاتورة شراء') || coalesce(' — فاتورة المورد ' || r.supplier_ref, ''), 0, r.amount);
  end loop;
  if (select abs(sum(debit) - sum(credit)) from public.journal_lines where entry_id = new.entry_id) > 0.0005 then raise exception 'قيد الفاتورة مش متوازن بعد توزيع الموردين'; end if;
  perform set_config('sumou.internal', coalesce(prev, ''), true);
  return null;
end $$;
drop trigger if exists zi_invoice_party_splits on public.invoices;
create trigger zi_invoice_party_splits after update of status on public.invoices for each row execute function public.zi_invoice_party_splits();
revoke execute on function public.zi_invoice_party_splits() from public, anon, authenticated;

create or replace function public.party_open_invoices(p_company uuid, p_party uuid, p_except_entry uuid default null)
returns table (invoice_id uuid, inv_type text, doc_code text, inv_no int, inv_date date, due_date date, total numeric, returned numeric, allocated numeric, remaining numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.can(p_company, 'receipt_vouchers', 'view') or public.can(p_company, 'payment_vouchers', 'view')
          or public.can(p_company, 'sales_invoices', 'view') or public.can(p_company, 'purchase_invoices', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  select i.id, i.inv_type, i.doc_code, i.inv_no, i.inv_date, coalesce(i.due_date, (i.inv_date + coalesce(p.payment_terms_days, 0))::date), i.total - coalesce(sp.amt, 0),
         coalesce(r.amt, 0), coalesce(a.amt, 0), round(i.total - coalesce(sp.amt, 0) - coalesce(r.amt, 0) - coalesce(a.amt, 0), 3)
    from public.invoices i join public.parties p on p.id = i.party_id
    left join lateral (select sum(x.total) amt from public.invoices x where x.original_invoice_id = i.id and x.status = 'posted' and x.payment_type = 'credit') r on true
    left join lateral (select sum(s.amount) amt from public.invoice_party_splits s where s.invoice_id = i.id) sp on true   -- حصص الموردين الثانيين
    left join lateral (select sum(al.amount) amt from public.invoice_allocations al
                        where al.invoice_id = i.id and public.alloc_live(al.entry_id) and al.entry_id is distinct from p_except_entry) a on true
   where i.company_id = p_company and i.party_id = p_party and i.status = 'posted' and i.payment_type = 'credit'
     and i.inv_type in ('sale','purchase') and public.dept_ok(p_company, i.department_id)
   order by i.inv_date, i.inv_no;
end $$;

-- النسخة الاحتياطية: حصص الموردين بعد سطور الفواتير
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
   (12, 'party_doc_types', 'company_id = $1', 'code'),
   (13, 'parties', 'company_id = $1', 'code'),
   (14, 'party_documents', 'company_id = $1', 'party_id, expiry_date'),
   (15, 'sales_visits', 'company_id = $1', 'started_at'),
   (16, 'item_categories', 'company_id = $1', 'code'),
   (17, 'items', 'company_id = $1', 'code'),
   (18, 'item_batches', 'company_id = $1', 'item_id, batch_no'),
   (19, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (20, 'promotions', 'company_id = $1', 'date_from'),
   (21, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (22, 'warehouses', 'company_id = $1', 'code'),
   (23, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (24, 'departments', 'company_id = $1', 'level, code'),
   (25, 'doc_types', 'company_id = $1', 'kind, code'),
   (26, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (27, 'boms', 'company_id = $1', 'code'),
   (28, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (29, 'work_locations', 'company_id = $1', 'name'),
   (30, 'work_shifts', 'company_id = $1', 'code'),
   (31, 'employees', 'company_id = $1', 'code'),
   (32, 'journal_entries', 'company_id = $1', 'created_at'),
   (33, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (34, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (35, 'invoices', 'company_id = $1', 'created_at'),
   (36, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (37, 'invoice_party_splits', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (38, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (39, 'party_notes', 'company_id = $1', 'created_at'),
   (40, 'orders', 'company_id = $1', 'created_at'),
   (41, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (42, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (43, 'cheques', 'company_id = $1', 'created_at'),
   (44, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (45, 'supply_requests', 'company_id = $1', 'req_no'),
   (46, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (47, 'stock_docs', 'company_id = $1', 'created_at'),
   (48, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (49, 'stock_moves', 'company_id = $1', 'created_at'),
   (50, 'batch_moves', 'company_id = $1', 'created_at'),
   (51, 'landed_costs', 'company_id = $1', 'doc_no'),
   (52, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (53, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (54, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (55, 'productions', 'company_id = $1', 'prod_no'),
   (56, 'obligations', 'company_id = $1', 'due_date'),
   (57, 'recurring_entries', 'company_id = $1', 'created_at'),
   (58, 'budgets', 'company_id = $1', 'code'),
   (59, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (60, 'attendance', 'company_id = $1', 'day, employee_id'),
   (61, 'leave_types', 'company_id = $1', 'code'),
   (62, 'leave_requests', 'company_id = $1', 'req_no'),
   (63, 'payroll_runs', 'company_id = $1', 'period'),
   (64, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (65, 'employee_loans', 'company_id = $1', 'loan_no'),
   (66, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (67, 'asset_custodians', 'company_id = $1', 'code'),
   (68, 'fixed_assets', 'company_id = $1', 'code'),
   (69, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (70, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (71, 'asset_movements', 'company_id = $1', 'mov_no'),
   (72, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (73, 'custody_docs', 'company_id = $1', 'doc_no'),
   (74, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (75, 'bank_recons', 'company_id = $1', 'created_at'),
   (76, 'bank_cleared', 'company_id = $1', 'line_id'),
   (77, 'message_log', 'company_id = $1', 'sent_at'),
   (78, 'doc_follow', 'company_id = $1', 'updated_at'),
   (79, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (80, 'attachments', 'company_id = $1', 'created_at'),
   (81, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
