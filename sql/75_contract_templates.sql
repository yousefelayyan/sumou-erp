-- =====================================================================
--  السمو ERP — المرحلة 75: قوالب بنود العقود وطباعة العقد
--  contract_templates: نص العقد بكلمات بتتعبّى ([العميل] [رقم العقد] [التاريخ] [البداية] [النهاية] [الدورية] [يوم الفاتورة]
--  [قيمة الفاتورة] [القيمة بالحروف] [القيمة السنوية] [الشركة] [عنوان العقد] [جدول البنود] [ملاحظات]). القراءة بـ contracts view والكتابة بـ contracts edit.
--  contracts.template_id + contracts.terms (نص العقد نفسه، بيتعبّى من القالب وبيتعدّل لكل عقد).
-- =====================================================================
create table if not exists public.contract_templates (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null check (length(code) between 1 and 20),
  name        text not null check (length(name) between 1 and 120),
  body        text not null default '' check (length(body) <= 30000),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (company_id, code)
);
alter table public.contract_templates enable row level security;
grant select, insert, update, delete on public.contract_templates to authenticated;
drop policy if exists ct_tpl_sel on public.contract_templates;
create policy ct_tpl_sel on public.contract_templates for select using (public.can(company_id, 'contracts', 'view'));
drop policy if exists ct_tpl_wr on public.contract_templates;
create policy ct_tpl_wr on public.contract_templates for all using (public.can(company_id, 'contracts', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'contracts', 'edit') and public.tenant_writable());

alter table public.contracts add column if not exists template_id uuid references public.contract_templates(id) on delete set null;
alter table public.contracts add column if not exists terms text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'contracts_terms_len') then
    alter table public.contracts add constraint contracts_terms_len check (terms is null or length(terms) <= 30000);
  end if;
end $$;
create or replace function public.ad_contract_template_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.template_id is not null and not exists (select 1 from public.contract_templates where id = new.template_id and company_id = new.company_id) then
    raise exception 'قالب العقد مش من نفس الشركة';
  end if;
  return new;
end $$;
drop trigger if exists ad_contract_template_check on public.contracts;
create trigger ad_contract_template_check before insert or update of template_id on public.contracts for each row execute function public.ad_contract_template_check();
revoke execute on function public.ad_contract_template_check() from public, anon, authenticated;

-- النسخة الاحتياطية: القوالب قبل العقود
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
   (32, 'contract_templates', 'company_id = $1', 'code'),
   (33, 'contracts', 'company_id = $1', 'contract_no'),
   (34, 'contract_lines', 'contract_id in (select id from public.contracts where company_id = $1)', 'contract_id, line_no'),
   (35, 'journal_entries', 'company_id = $1', 'created_at'),
   (36, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (37, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (38, 'invoices', 'company_id = $1', 'created_at'),
   (39, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (40, 'invoice_party_splits', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (41, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (42, 'party_notes', 'company_id = $1', 'created_at'),
   (43, 'orders', 'company_id = $1', 'created_at'),
   (44, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (45, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (46, 'cheques', 'company_id = $1', 'created_at'),
   (47, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (48, 'supply_requests', 'company_id = $1', 'req_no'),
   (49, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (50, 'stock_docs', 'company_id = $1', 'created_at'),
   (51, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (52, 'stock_moves', 'company_id = $1', 'created_at'),
   (53, 'batch_moves', 'company_id = $1', 'created_at'),
   (54, 'landed_costs', 'company_id = $1', 'doc_no'),
   (55, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (56, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (57, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (58, 'productions', 'company_id = $1', 'prod_no'),
   (59, 'obligations', 'company_id = $1', 'due_date'),
   (60, 'recurring_entries', 'company_id = $1', 'created_at'),
   (61, 'budgets', 'company_id = $1', 'code'),
   (62, 'budget_lines', 'budget_id in (select id from public.budgets where company_id = $1)', 'budget_id'),
   (63, 'attendance', 'company_id = $1', 'day, employee_id'),
   (64, 'leave_types', 'company_id = $1', 'code'),
   (65, 'leave_requests', 'company_id = $1', 'req_no'),
   (66, 'payroll_runs', 'company_id = $1', 'period'),
   (67, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (68, 'employee_loans', 'company_id = $1', 'loan_no'),
   (69, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (70, 'asset_custodians', 'company_id = $1', 'code'),
   (71, 'fixed_assets', 'company_id = $1', 'code'),
   (72, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (73, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (74, 'asset_movements', 'company_id = $1', 'mov_no'),
   (75, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (76, 'custody_docs', 'company_id = $1', 'doc_no'),
   (77, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (78, 'bank_recons', 'company_id = $1', 'created_at'),
   (79, 'bank_cleared', 'company_id = $1', 'line_id'),
   (80, 'message_log', 'company_id = $1', 'sent_at'),
   (81, 'doc_follow', 'company_id = $1', 'updated_at'),
   (82, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (83, 'attachments', 'company_id = $1', 'created_at'),
   (84, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
