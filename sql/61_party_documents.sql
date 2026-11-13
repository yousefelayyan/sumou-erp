-- =====================================================================
--  السمو ERP — المرحلة 61: وثائق العملاء والموردين بتاريخ انتهاء
--  party_doc_types: نوع الوثيقة (سجل تجاري، رخصة مهن، شهادة ضريبة، هوية المفوّض…) لمين (عميل/مورد/الكل)،
--    إلزامي أو لا، وتصرّف البرنامج إذا ناقصة أو منتهية: none (تنبيه بالتقرير بس) / warn (تنبيه بالفاتورة) / block (منع ترحيل الفاتورة).
--  party_documents: وثائق كل طرف (رقم، تاريخ إصدار وانتهاء، ملاحظات + مرفقات entity = 'party_doc').
--  ab_party_docs_check: ترحيل فاتورة بطرف عنده وثيقة «منع» ناقصة أو منتهية بتاريخ الفاتورة = ممنوع،
--    إلا المدير أو شاشة party_docs_override edit.
-- =====================================================================
create table if not exists public.party_doc_types (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  code        text not null,
  name        text not null,
  applies_to  text not null default 'customer' check (applies_to in ('customer','supplier','both')),
  required    boolean not null default false,
  on_missing  text not null default 'warn' check (on_missing in ('none','warn','block')),
  warn_days   int not null default 30 check (warn_days between 0 and 365),
  is_active   boolean not null default true,
  unique (company_id, code)
);
create table if not exists public.party_documents (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  party_id    uuid not null references public.parties(id) on delete cascade,
  type_id     uuid not null references public.party_doc_types(id) on delete restrict,
  doc_no      text,
  issue_date  date,
  expiry_date date,
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  check (expiry_date is null or issue_date is null or expiry_date >= issue_date)
);
create index if not exists party_documents_party on public.party_documents (party_id);
create index if not exists party_documents_exp on public.party_documents (company_id, expiry_date);

grant select, insert, update, delete on public.party_doc_types, public.party_documents to authenticated;
alter table public.party_doc_types enable row level security;
alter table public.party_documents enable row level security;
drop policy if exists pdt_select on public.party_doc_types;
create policy pdt_select on public.party_doc_types for select to authenticated using (public.has_company(company_id));
drop policy if exists pdt_write on public.party_doc_types;
create policy pdt_write on public.party_doc_types for all to authenticated
  using ((public.can(company_id, 'customers', 'edit') or public.can(company_id, 'suppliers', 'edit')) and public.tenant_writable())
  with check ((public.can(company_id, 'customers', 'edit') or public.can(company_id, 'suppliers', 'edit')) and public.tenant_writable());
drop policy if exists pd_select on public.party_documents;
create policy pd_select on public.party_documents for select to authenticated
  using (exists (select 1 from public.parties p where p.id = party_id and p.company_id = party_documents.company_id and public.can(p.company_id, public.party_screen(p.party_type), 'view')));
drop policy if exists pd_write on public.party_documents;
create policy pd_write on public.party_documents for all to authenticated
  using (public.tenant_writable() and exists (select 1 from public.parties p where p.id = party_id and p.company_id = party_documents.company_id and public.can(p.company_id, public.party_screen(p.party_type), 'edit')))
  with check (public.tenant_writable() and exists (select 1 from public.parties p where p.id = party_id and p.company_id = party_documents.company_id and public.can(p.company_id, public.party_screen(p.party_type), 'edit'))
              and exists (select 1 from public.party_doc_types t where t.id = type_id and t.company_id = party_documents.company_id));

-- مشاكل وثائق طرف بتاريخ: كل نوع إلزامي ناقص، أو آخر وثيقة منه منتهية
create or replace function public.party_doc_issues(p_company uuid, p_party uuid, p_date date default null)
returns table (type_id uuid, type_name text, on_missing text, problem text, expiry_date date)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare pa public.parties; d date := coalesce(p_date, public.local_today());
begin
  select * into pa from public.parties where id = p_party and company_id = p_company;
  if pa.id is null then return; end if;
  if not public.has_company(p_company) then raise exception 'ما عندك صلاحية'; end if;
  return query
  with t as (
    select x.* from public.party_doc_types x
     where x.company_id = p_company and x.is_active and (x.applies_to = 'both' or x.applies_to = pa.party_type)),
  last as (
    select distinct on (pd.type_id) pd.type_id, pd.expiry_date from public.party_documents pd
     where pd.party_id = p_party order by pd.type_id, pd.expiry_date desc nulls first)
  select t.id, t.name, t.on_missing,
         case when l.type_id is null then 'missing' when l.expiry_date < d then 'expired' else 'expiring' end,
         l.expiry_date
    from t left join last l on l.type_id = t.id
   where (l.type_id is null and t.required)
      or (l.expiry_date is not null and l.expiry_date < d + t.warn_days);
end $$;

create or replace function public.ab_party_docs_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare msg text;
begin
  if not (old.status = 'draft' and new.status = 'posted') or new.party_id is null then return new; end if;
  if public.is_admin() or public.can(new.company_id, 'party_docs_override', 'edit') then return new; end if;
  select string_agg(i.type_name || case i.problem when 'missing' then ' (ناقصة)' else ' (منتهية ' || to_char(i.expiry_date, 'DD/MM/YYYY') || ')' end, '، ')
    into msg from public.party_doc_issues(new.company_id, new.party_id, new.inv_date) i
   where i.on_missing = 'block' and i.problem in ('missing','expired');
  if msg is not null then raise exception 'ما بتنرحّل: وثائق الطرف مش مكتملة — %', msg; end if;
  return new;
end $$;
drop trigger if exists ab_party_docs_check on public.invoices;
create trigger ab_party_docs_check before update of status on public.invoices for each row execute function public.ab_party_docs_check();

-- تقرير: الوثائق المنتهية واللي قرّبت تنتهي، والناقصة الإلزامية
create or replace function public.party_docs_report(p_company uuid, p_days int default 30)
returns table (party_id uuid, party_code text, party_name text, party_type text, type_name text, on_missing text, problem text, doc_no text, expiry_date date)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare d date := public.local_today();
begin
  if not (public.can(p_company, 'customers', 'view') or public.can(p_company, 'suppliers', 'view')) then raise exception 'ما عندك صلاحية'; end if;
  return query
  with t as (select x.* from public.party_doc_types x where x.company_id = p_company and x.is_active),
  p as (select y.* from public.parties y where y.company_id = p_company and y.is_active and y.party_type in ('customer','supplier')
          and public.can(p_company, public.party_screen(y.party_type), 'view')),
  last as (
    select distinct on (pd.party_id, pd.type_id) pd.party_id, pd.type_id, pd.doc_no, pd.expiry_date from public.party_documents pd
     where pd.company_id = p_company order by pd.party_id, pd.type_id, pd.expiry_date desc nulls first)
  select p.id, p.code, p.name, p.party_type, t.name, t.on_missing,
         case when l.type_id is null then 'missing' when l.expiry_date < d then 'expired' else 'expiring' end, l.doc_no, l.expiry_date
    from p join t on t.applies_to in ('both', p.party_type)
    left join last l on l.party_id = p.id and l.type_id = t.id
   where (l.type_id is null and t.required) or (l.expiry_date is not null and l.expiry_date < d + greatest(p_days, 0))
   order by (l.expiry_date is null) desc, l.expiry_date, p.code;
end $$;

revoke all on function public.party_doc_issues(uuid, uuid, date), public.party_docs_report(uuid, int) from public, anon;
grant execute on function public.party_doc_issues(uuid, uuid, date), public.party_docs_report(uuid, int) to authenticated;

-- النسخة الاحتياطية: أنواع الوثائق قبل الأطراف، والوثائق بعدهم
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
   (18, 'price_list_items', 'list_id in (select id from public.price_lists where company_id = $1)', 'list_id'),
   (19, 'promotions', 'company_id = $1', 'date_from'),
   (20, 'loyalty_tiers', 'company_id = $1', 'rank'),
   (21, 'warehouses', 'company_id = $1', 'code'),
   (22, 'item_wh_limits', 'company_id = $1', 'item_id'),
   (23, 'departments', 'company_id = $1', 'level, code'),
   (24, 'doc_types', 'company_id = $1', 'kind, code'),
   (25, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (26, 'boms', 'company_id = $1', 'code'),
   (27, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (28, 'journal_entries', 'company_id = $1', 'created_at'),
   (29, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (30, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (31, 'invoices', 'company_id = $1', 'created_at'),
   (32, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (33, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (34, 'orders', 'company_id = $1', 'created_at'),
   (35, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (36, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (37, 'cheques', 'company_id = $1', 'created_at'),
   (38, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (39, 'supply_requests', 'company_id = $1', 'req_no'),
   (40, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (41, 'stock_docs', 'company_id = $1', 'created_at'),
   (42, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (43, 'stock_moves', 'company_id = $1', 'created_at'),
   (44, 'landed_costs', 'company_id = $1', 'doc_no'),
   (45, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (46, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (47, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (48, 'productions', 'company_id = $1', 'prod_no'),
   (49, 'obligations', 'company_id = $1', 'due_date'),
   (50, 'recurring_entries', 'company_id = $1', 'created_at'),
   (51, 'work_locations', 'company_id = $1', 'name'),
   (52, 'work_shifts', 'company_id = $1', 'code'),
   (53, 'employees', 'company_id = $1', 'code'),
   (54, 'attendance', 'company_id = $1', 'day, employee_id'),
   (55, 'leave_types', 'company_id = $1', 'code'),
   (56, 'leave_requests', 'company_id = $1', 'req_no'),
   (57, 'payroll_runs', 'company_id = $1', 'period'),
   (58, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (59, 'employee_loans', 'company_id = $1', 'loan_no'),
   (60, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (61, 'asset_custodians', 'company_id = $1', 'code'),
   (62, 'fixed_assets', 'company_id = $1', 'code'),
   (63, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (64, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (65, 'asset_movements', 'company_id = $1', 'mov_no'),
   (66, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (67, 'custody_docs', 'company_id = $1', 'doc_no'),
   (68, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (69, 'bank_recons', 'company_id = $1', 'created_at'),
   (70, 'bank_cleared', 'company_id = $1', 'line_id'),
   (71, 'message_log', 'company_id = $1', 'sent_at'),
   (72, 'doc_follow', 'company_id = $1', 'updated_at'),
   (73, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (74, 'attachments', 'company_id = $1', 'created_at'),
   (75, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
