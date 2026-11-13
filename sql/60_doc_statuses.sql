-- =====================================================================
--  السمو ERP — المرحلة 60: حالات المتابعة المخصصة على المستندات
--  doc_statuses: حالات بتسمّيها الشركة لكل نوع مستند (مثلاً: بانتظار التوقيع، تم التسليم، مرسلة للمحاسب…) بلون وترتيب.
--  doc_follow: الحالة الحالية لكل مستند + doc_follow_log: سجل التغيير. ما بتلمس المستند نفسه (بتنفع للمرحّل كمان).
--  التغيير بس من set_doc_follow(table, id, status, note) بصلاحية edit أو post على شاشة المستند.
-- =====================================================================
create table if not exists public.doc_statuses (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  kind        text not null check (kind in ('sale','sale_return','purchase','purchase_return','sales_order','purchase_order','receipt','payment','journal','stock')),
  code        text not null,
  name        text not null,
  color       text not null default '#64748b' check (color ~ '^#[0-9a-fA-F]{6}$'),
  sort        int not null default 0,
  is_final    boolean not null default false,
  is_active   boolean not null default true,
  unique (company_id, kind, code)
);
grant select, insert, update, delete on public.doc_statuses to authenticated;
alter table public.doc_statuses enable row level security;
drop policy if exists dst_select on public.doc_statuses;
create policy dst_select on public.doc_statuses for select to authenticated using (public.has_company(company_id));
drop policy if exists dst_write on public.doc_statuses;
create policy dst_write on public.doc_statuses for all to authenticated
  using (public.can(company_id, 'doc_types', 'edit') and public.tenant_writable())
  with check (public.can(company_id, 'doc_types', 'edit') and public.tenant_writable());

create table if not exists public.doc_follow (
  doc_id      uuid primary key,
  company_id  uuid not null references public.companies(id) on delete cascade,
  doc_table   text not null check (doc_table in ('invoices','orders','journal_entries','stock_docs')),
  screen      text not null,
  kind        text not null,
  status_id   uuid references public.doc_statuses(id) on delete set null,
  note        text,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);
create index if not exists doc_follow_status on public.doc_follow (company_id, status_id);
create table if not exists public.doc_follow_log (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete cascade,
  doc_id      uuid not null,
  screen      text not null,
  status_id   uuid references public.doc_statuses(id) on delete set null,
  status_name text,
  note        text,
  set_by      uuid default auth.uid(),
  set_at      timestamptz not null default now()
);
create index if not exists doc_follow_log_doc on public.doc_follow_log (doc_id, set_at desc);
grant select on public.doc_follow, public.doc_follow_log to authenticated;
alter table public.doc_follow enable row level security;
alter table public.doc_follow_log enable row level security;
drop policy if exists df_select on public.doc_follow;
create policy df_select on public.doc_follow for select to authenticated using (public.can(company_id, screen, 'view'));
drop policy if exists dfl_select on public.doc_follow_log;
create policy dfl_select on public.doc_follow_log for select to authenticated using (public.can(company_id, screen, 'view'));

-- نوع المستند وشاشته
create or replace function public.doc_follow_target(p_table text, p_id uuid, out company_id uuid, out kind text, out screen text, out dept uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_table = 'invoices' then
    select i.company_id, i.inv_type, public.invoice_screen(i.inv_type), i.department_id into company_id, kind, screen, dept from public.invoices i where i.id = p_id;
  elsif p_table = 'orders' then
    select o.company_id, o.order_type, case o.order_type when 'sales_order' then 'sales_orders' else 'purchase_orders' end, null into company_id, kind, screen, dept from public.orders o where o.id = p_id;
  elsif p_table = 'journal_entries' then
    select e.company_id, e.entry_type, case e.entry_type when 'receipt' then 'receipt_vouchers' when 'payment' then 'payment_vouchers' else 'journal_entries' end, e.department_id
      into company_id, kind, screen, dept from public.journal_entries e where e.id = p_id;
    if kind not in ('receipt','payment','journal') then kind := null; end if;
  elsif p_table = 'stock_docs' then
    select d.company_id, 'stock', 'inventory', d.department_id into company_id, kind, screen, dept from public.stock_docs d where d.id = p_id;
  end if;
end $$;
revoke all on function public.doc_follow_target(text, uuid) from public, anon, authenticated;

create or replace function public.set_doc_follow(p_table text, p_id uuid, p_status uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t record; st public.doc_statuses;
begin
  select * into t from public.doc_follow_target(p_table, p_id);
  if t.company_id is null or t.kind is null then raise exception 'المستند مش موجود أو ما إله حالات متابعة'; end if;
  if not public.tenant_writable() or not (public.can(t.company_id, t.screen, 'edit') or public.can(t.company_id, t.screen, 'post')) then
    raise exception 'ما عندك صلاحية تغيّر حالة المتابعة';
  end if;
  if t.dept is not null and not public.dept_ok(t.company_id, t.dept) then raise exception 'المستند مش من فرعك'; end if;
  if p_status is not null then
    select * into st from public.doc_statuses where id = p_status and company_id = t.company_id and is_active;
    if st.id is null or st.kind <> t.kind then raise exception 'الحالة مش لهالنوع من المستندات'; end if;
  end if;
  insert into public.doc_follow (doc_id, company_id, doc_table, screen, kind, status_id, note, updated_by, updated_at)
  values (p_id, t.company_id, p_table, t.screen, t.kind, p_status, left(nullif(trim(p_note), ''), 500), auth.uid(), now())
  on conflict (doc_id) do update set status_id = excluded.status_id, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  insert into public.doc_follow_log (company_id, doc_id, screen, status_id, status_name, note)
  values (t.company_id, p_id, t.screen, p_status, coalesce(st.name, 'بدون حالة'), left(nullif(trim(p_note), ''), 500));
end $$;
revoke all on function public.set_doc_follow(text, uuid, uuid, text) from public, anon;
grant execute on function public.set_doc_follow(text, uuid, uuid, text) to authenticated;

-- حذف المستند بيمسح متابعته
create or replace function public.zw_doc_follow_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.doc_follow where doc_id = old.id;
  delete from public.doc_follow_log where doc_id = old.id;
  return old;
end $$;
do $$ declare t text; begin
  foreach t in array array['invoices','orders','journal_entries','stock_docs'] loop
    execute format('drop trigger if exists zw_doc_follow_cleanup on public.%I', t);
    execute format('create trigger zw_doc_follow_cleanup after delete on public.%I for each row execute function public.zw_doc_follow_cleanup()', t);
  end loop;
end $$;

-- النسخة الاحتياطية: الحالات بعد أنواع السندات، والمتابعة بالآخر قبل المرفقات
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
   (23, 'doc_statuses', 'company_id = $1', 'kind, sort, code'),
   (24, 'boms', 'company_id = $1', 'code'),
   (25, 'bom_lines', 'bom_id in (select id from public.boms where company_id = $1)', 'bom_id, line_no'),
   (26, 'journal_entries', 'company_id = $1', 'created_at'),
   (27, 'journal_lines', 'entry_id in (select id from public.journal_entries where company_id = $1)', 'entry_id, line_no'),
   (28, 'loyalty_redemptions', 'company_id = $1', 'created_at'),
   (29, 'invoices', 'company_id = $1', 'created_at'),
   (30, 'invoice_lines', 'invoice_id in (select id from public.invoices where company_id = $1)', 'invoice_id, line_no'),
   (31, 'invoice_allocations', 'company_id = $1', 'created_at'),
   (32, 'orders', 'company_id = $1', 'created_at'),
   (33, 'order_lines', 'order_id in (select id from public.orders where company_id = $1)', 'order_id, line_no'),
   (34, 'service_tickets', 'company_id = $1', 'ticket_no'),
   (35, 'cheques', 'company_id = $1', 'created_at'),
   (36, 'cheque_events', 'cheque_id in (select id from public.cheques where company_id = $1)', 'created_at'),
   (37, 'supply_requests', 'company_id = $1', 'req_no'),
   (38, 'supply_request_lines', 'request_id in (select id from public.supply_requests where company_id = $1)', 'request_id, line_no'),
   (39, 'stock_docs', 'company_id = $1', 'created_at'),
   (40, 'stock_doc_lines', 'doc_id in (select id from public.stock_docs where company_id = $1)', 'doc_id, line_no'),
   (41, 'stock_moves', 'company_id = $1', 'created_at'),
   (42, 'landed_costs', 'company_id = $1', 'doc_no'),
   (43, 'landed_cost_invoices', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (44, 'landed_cost_charges', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id, line_no'),
   (45, 'landed_cost_allocs', 'landed_id in (select id from public.landed_costs where company_id = $1)', 'landed_id'),
   (46, 'productions', 'company_id = $1', 'prod_no'),
   (47, 'obligations', 'company_id = $1', 'due_date'),
   (48, 'recurring_entries', 'company_id = $1', 'created_at'),
   (49, 'work_locations', 'company_id = $1', 'name'),
   (50, 'work_shifts', 'company_id = $1', 'code'),
   (51, 'employees', 'company_id = $1', 'code'),
   (52, 'attendance', 'company_id = $1', 'day, employee_id'),
   (53, 'leave_types', 'company_id = $1', 'code'),
   (54, 'leave_requests', 'company_id = $1', 'req_no'),
   (55, 'payroll_runs', 'company_id = $1', 'period'),
   (56, 'payroll_lines', 'run_id in (select id from public.payroll_runs where company_id = $1)', 'run_id'),
   (57, 'employee_loans', 'company_id = $1', 'loan_no'),
   (58, 'loan_installments', 'loan_id in (select id from public.employee_loans where company_id = $1)', 'loan_id, seq'),
   (59, 'asset_custodians', 'company_id = $1', 'code'),
   (60, 'fixed_assets', 'company_id = $1', 'code'),
   (61, 'depreciation_runs', 'company_id = $1', 'created_at'),
   (62, 'depreciation_lines', 'run_id in (select id from public.depreciation_runs where company_id = $1)', 'run_id'),
   (63, 'asset_movements', 'company_id = $1', 'mov_no'),
   (64, 'asset_movement_lines', 'movement_id in (select id from public.asset_movements where company_id = $1)', 'movement_id, line_no'),
   (65, 'custody_docs', 'company_id = $1', 'doc_no'),
   (66, 'custody_doc_lines', 'doc_id in (select id from public.custody_docs where company_id = $1)', 'doc_id, line_no'),
   (67, 'bank_recons', 'company_id = $1', 'created_at'),
   (68, 'bank_cleared', 'company_id = $1', 'line_id'),
   (69, 'message_log', 'company_id = $1', 'sent_at'),
   (70, 'doc_follow', 'company_id = $1', 'updated_at'),
   (71, 'doc_follow_log', 'company_id = $1', 'set_at'),
   (72, 'attachments', 'company_id = $1', 'created_at'),
   (73, 'fiscal_periods', 'company_id = $1', 'start_date');
$$;
