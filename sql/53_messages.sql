-- =====================================================================
--  السمو ERP — المرحلة 53: رسائل الواتساب والرسائل القصيرة
--  company_settings.msg_templates: نصوص جاهزة (invoice, statement, payment, reminder, campaign)
--  message_log: سجل كل رسالة انبعتت (من الجهاز عبر واتساب/رسالة نصية) للمتابعة.
-- =====================================================================
alter table public.company_settings add column if not exists msg_templates jsonb not null default '{}'::jsonb;

create table if not exists public.message_log (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  party_id   uuid references public.parties(id) on delete set null,
  phone      text,
  channel    text not null default 'whatsapp' check (channel in ('whatsapp','sms','email')),
  kind       text not null default 'campaign' check (kind in ('invoice','statement','payment','reminder','campaign','other')),
  ref_id     uuid,
  body       text not null check (length(body) <= 2000),
  campaign   text,
  sent_by    uuid default auth.uid(),
  sent_at    timestamptz not null default now()
);
create index if not exists message_log_co on public.message_log (company_id, sent_at desc);
alter table public.message_log enable row level security;
grant select, insert, delete on public.message_log to authenticated;
drop policy if exists ml_select on public.message_log;
create policy ml_select on public.message_log for select to authenticated
  using (public.can(company_id, 'marketing', 'view') or sent_by = auth.uid());
drop policy if exists ml_insert on public.message_log;
create policy ml_insert on public.message_log for insert to authenticated
  with check (public.has_company(company_id) and public.tenant_writable() and sent_by = auth.uid()
              and (party_id is null or exists (select 1 from public.parties p where p.id = party_id and p.company_id = message_log.company_id)));
drop policy if exists ml_delete on public.message_log;
create policy ml_delete on public.message_log for delete to authenticated using (public.can(company_id, 'marketing', 'delete'));

-- النسخة الاحتياطية: سجل الرسائل قبل المرفقات
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
   (61, 'message_log', 'company_id = $1', 'sent_at'),
   (62, 'attachments', 'company_id = $1', 'created_at'),
   (63, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
